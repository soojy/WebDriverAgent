/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBCustomCommands.h"

#import <XCTest/XCUIDevice.h>
#import <XCTest/XCTest.h>
#import <CoreLocation/CoreLocation.h>
#if !TARGET_OS_TV
#import <Photos/Photos.h>
#import <Vision/Vision.h>
#endif

#import "FBConfiguration.h"
#import "FBKeyboard.h"
#import "FBNotificationsHelper.h"
#import "FBMathUtils.h"
#import "FBPasteboard.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBRunLoopSpinner.h"
#import "FBScreen.h"
#import "FBSession.h"
#import "FBXCodeCompatibility.h"
#import "XCUIApplication.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIDevice+FBHelpers.h"
#import "XCUIElement.h"
#import "XCUIElement+FBIsVisible.h"
#import "XCUIElementQuery.h"
#import "FBUnattachedAppLauncher.h"

#pragma mark - Script Executor

@interface FBScriptExecutor : NSObject

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *results;
@property (nonatomic, strong) XCUIApplication *currentApp;
@property (nonatomic, strong) XCUIApplication *springboard;

- (NSDictionary *)executeSteps:(NSArray<NSDictionary *> *)steps;

@end

@implementation FBScriptExecutor

- (instancetype)init
{
  self = [super init];
  if (self) {
    _results = [NSMutableDictionary dictionary];
    _springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
  }
  return self;
}

- (NSDictionary *)executeSteps:(NSArray<NSDictionary *> *)steps
{
  for (NSUInteger i = 0; i < steps.count; i++) {
    NSDictionary *step = steps[i];
    NSError *error = nil;
    
    BOOL success = [self executeStep:step error:&error];
    
    if (!success) {
      NSNumber *optional = step[@"optional"];
      if (optional && optional.boolValue) {
        continue;
      }
      
      return @{
        @"success": @NO,
        @"results": self.results,
        @"stoppedAt": @(i),
        @"error": error.localizedDescription ?: @"Unknown error",
        @"failedAction": step[@"action"] ?: @"unknown"
      };
    }
  }
  
  return @{
    @"success": @YES,
    @"results": self.results,
    @"stoppedAt": [NSNull null],
    @"error": [NSNull null]
  };
}

- (BOOL)executeStep:(NSDictionary *)step error:(NSError **)error
{
  NSString *action = step[@"action"];
  
  if (!action) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:1
                             userInfo:@{NSLocalizedDescriptionKey: @"Missing 'action' in step"}];
    return NO;
  }
  
  // App lifecycle
  if ([action isEqualToString:@"launch"]) return [self executeLaunch:step error:error];
  if ([action isEqualToString:@"terminate"]) return [self executeTerminate:step error:error];
  if ([action isEqualToString:@"activate"]) return [self executeActivate:step error:error];
  
  // Element actions
  if ([action isEqualToString:@"click"]) return [self executeClick:step error:error];
  if ([action isEqualToString:@"tap"]) return [self executeClick:step error:error];  // Alias
  if ([action isEqualToString:@"wait"]) return [self executeWait:step error:error];
  if ([action isEqualToString:@"waitDisappear"]) return [self executeWaitDisappear:step error:error];
  if ([action isEqualToString:@"read"]) return [self executeRead:step error:error];
  if ([action isEqualToString:@"exists"]) return [self executeExists:step error:error];
  
  // Alert handling
  if ([action isEqualToString:@"handleAlert"]) return [self executeHandleAlert:step error:error];
  
  // Picker
  if ([action isEqualToString:@"setPicker"]) return [self executeSetPicker:step error:error];
  
  // Coordinates
  if ([action isEqualToString:@"tapXY"]) return [self executeTapXY:step error:error];
  if ([action isEqualToString:@"swipe"]) return [self executeSwipe:step error:error];
  
  // Input
  if ([action isEqualToString:@"type"]) return [self executeType:step error:error];
  if ([action isEqualToString:@"typeText"]) return [self executeType:step error:error];  // Alias
  if ([action isEqualToString:@"clear"]) return [self executeClear:step error:error];
  
  // Utility
  if ([action isEqualToString:@"sleep"]) return [self executeSleep:step error:error];
  if ([action isEqualToString:@"screenshot"]) return [self executeScreenshot:step error:error];
  if ([action isEqualToString:@"home"]) return [self executeHome:step error:error];
  
#if !TARGET_OS_TV
  // Vision/OCR
  if ([action isEqualToString:@"clickText"]) return [self executeClickText:step error:error];
  if ([action isEqualToString:@"tapText"]) return [self executeClickText:step error:error];  // Alias
  if ([action isEqualToString:@"waitText"]) return [self executeWaitText:step error:error];
  if ([action isEqualToString:@"readRegion"]) return [self executeReadRegion:step error:error];
  if ([action isEqualToString:@"clickImage"]) return [self executeClickImage:step error:error];
  if ([action isEqualToString:@"tapImage"]) return [self executeClickImage:step error:error];  // Alias
#endif
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:2
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown action: %@", action]}];
  return NO;
}

#pragma mark - App Lifecycle

- (BOOL)executeLaunch:(NSDictionary *)step error:(NSError **)error
{
  NSString *bundleId = step[@"bundleId"];
  if (!bundleId) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:3
                             userInfo:@{NSLocalizedDescriptionKey: @"'bundleId' required for launch"}];
    return NO;
  }
  
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
  [app launch];
  self.currentApp = app;
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    if (app.state == XCUIApplicationStateRunningForeground) {
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:4
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"App '%@' did not launch within %.1fs", bundleId, timeout]}];
  return NO;
}

- (BOOL)executeTerminate:(NSDictionary *)step error:(NSError **)error
{
  NSString *bundleId = step[@"bundleId"];
  if (!bundleId) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:3
                             userInfo:@{NSLocalizedDescriptionKey: @"'bundleId' required for terminate"}];
    return NO;
  }
  
  XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
  [app terminate];
  return YES;
}

- (BOOL)executeActivate:(NSDictionary *)step error:(NSError **)error
{
  NSString *bundleId = step[@"bundleId"];
  if (!bundleId) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:3
                             userInfo:@{NSLocalizedDescriptionKey: @"'bundleId' required for activate"}];
    return NO;
  }
  
  XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
  [app activate];
  self.currentApp = app;
  return YES;
}

#pragma mark - Element Finding

- (XCUIApplication *)getTargetApp
{
  if (self.currentApp && self.currentApp.state == XCUIApplicationStateRunningForeground) {
    return self.currentApp;
  }
  return XCUIApplication.fb_activeApplication;
}

- (XCUIElement *)findElementWithSelector:(NSString *)selector
                            selectorType:(NSString *)selectorType
                                   inApp:(XCUIApplication *)app
{
  if (!selector) return nil;
  
  NSString *type = selectorType ?: @"accessibilityId";
  
  if ([type isEqualToString:@"accessibilityId"] || [type isEqualToString:@"id"]) {
    // Try common element types first for performance
    XCUIElement *element = app.buttons[selector];
    if (element.exists) return element;
    
    element = app.staticTexts[selector];
    if (element.exists) return element;
    
    element = app.textFields[selector];
    if (element.exists) return element;
    
    element = app.images[selector];
    if (element.exists) return element;
    
    element = app.cells[selector];
    if (element.exists) return element;
    
    element = app.switches[selector];
    if (element.exists) return element;
    
    element = app.otherElements[selector];
    if (element.exists) return element;
    
    // Fallback to generic query
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"identifier == %@ OR label == %@", selector, selector];
    XCUIElementQuery *query = [app descendantsMatchingType:XCUIElementTypeAny];
    return [query elementMatchingPredicate:predicate];
  }
  
  if ([type isEqualToString:@"classChain"]) {
    NSArray *elements = [app fb_descendantsMatchingClassChain:selector shouldReturnAfterFirstMatch:YES];
    return elements.firstObject;
  }
  
  if ([type isEqualToString:@"predicate"]) {
    @try {
      NSPredicate *predicate = [NSPredicate predicateWithFormat:selector];
      return [[app descendantsMatchingType:XCUIElementTypeAny] elementMatchingPredicate:predicate];
    } @catch (NSException *exception) {
      return nil;
    }
  }
  
  if ([type isEqualToString:@"label"]) {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"label == %@", selector];
    return [[app descendantsMatchingType:XCUIElementTypeAny] elementMatchingPredicate:predicate];
  }
  
  if ([type isEqualToString:@"labelContains"]) {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"label CONTAINS %@", selector];
    return [[app descendantsMatchingType:XCUIElementTypeAny] elementMatchingPredicate:predicate];
  }
  
  return nil;
}

#pragma mark - Element Actions

- (BOOL)executeClick:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for click"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (element && element.exists && element.isHittable) {
      [element tap];
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:6
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found or not clickable within %.1fs", selector, timeout]}];
  return NO;
}

- (BOOL)executeWait:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for wait"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (element && element.exists) {
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:7
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found within %.1fs", selector, timeout]}];
  return NO;
}

- (BOOL)executeWaitDisappear:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for waitDisappear"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (!element || !element.exists) {
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  // Not an error - element may still be visible
  return YES;
}

- (BOOL)executeRead:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for read"}];
    return NO;
  }
  
  if (!key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:8
                             userInfo:@{NSLocalizedDescriptionKey: @"'as' key required for read action"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (element && element.exists) {
      NSString *value = element.label;
      if (!value || value.length == 0) {
        value = [element valueForKey:@"value"];
      }
      self.results[key] = value ?: @"";
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:9
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for reading within %.1fs", selector, timeout]}];
  return NO;
}

- (BOOL)executeExists:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"] ?: @"exists";
  
  XCUIApplication *app = [self getTargetApp];
  XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
  
  self.results[key] = (element && element.exists) ? @"true" : @"false";
  return YES;
}

#pragma mark - Alert Handling

- (BOOL)executeHandleAlert:(NSDictionary *)step error:(NSError **)error
{
  NSString *buttonName = step[@"button"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 3.0;
  
  if (!buttonName) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:10
                             userInfo:@{NSLocalizedDescriptionKey: @"'button' required for handleAlert"}];
    return NO;
  }
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    // Check springboard for system alerts
    XCUIElement *alertButton = self.springboard.buttons[buttonName];
    if (alertButton.exists && alertButton.isHittable) {
      [alertButton tap];
      [NSThread sleepForTimeInterval:0.3];
      return YES;
    }
    
    // Check springboard alerts
    XCUIElementQuery *alerts = self.springboard.alerts;
    if (alerts.count > 0) {
      XCUIElement *alert = [alerts elementBoundByIndex:0];
      XCUIElement *btn = alert.buttons[buttonName];
      if (btn.exists && btn.isHittable) {
        [btn tap];
        [NSThread sleepForTimeInterval:0.3];
        return YES;
      }
    }
    
    // Check current app for in-app alerts
    XCUIApplication *app = [self getTargetApp];
    if (app) {
      alertButton = app.buttons[buttonName];
      if (alertButton.exists && alertButton.isHittable) {
        [alertButton tap];
        [NSThread sleepForTimeInterval:0.3];
        return YES;
      }
      
      alerts = app.alerts;
      if (alerts.count > 0) {
        XCUIElement *alert = [alerts elementBoundByIndex:0];
        XCUIElement *btn = alert.buttons[buttonName];
        if (btn.exists && btn.isHittable) {
          [btn tap];
          [NSThread sleepForTimeInterval:0.3];
          return YES;
        }
      }
      
      // Check sheets
      XCUIElementQuery *sheets = app.sheets;
      if (sheets.count > 0) {
        XCUIElement *sheet = [sheets elementBoundByIndex:0];
        XCUIElement *btn = sheet.buttons[buttonName];
        if (btn.exists && btn.isHittable) {
          [btn tap];
          [NSThread sleepForTimeInterval:0.3];
          return YES;
        }
      }
    }
    
    [NSThread sleepForTimeInterval:0.1];
  }
  
  // Alert handling is optional by nature - not finding is not always an error
  NSNumber *optional = step[@"optional"];
  if (optional && optional.boolValue) {
    return YES;
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:11
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Alert button '%@' not found within %.1fs", buttonName, timeout]}];
  return NO;
}

#pragma mark - Picker Actions

- (BOOL)executeSetPicker:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *index = step[@"index"];
  NSString *value = step[@"value"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (index == nil) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:12
                             userInfo:@{NSLocalizedDescriptionKey: @"'index' required for setPicker"}];
    return NO;
  }
  
  if (!value) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:13
                             userInfo:@{NSLocalizedDescriptionKey: @"'value' required for setPicker"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElementQuery *pickers = app.pickerWheels;
    if (pickers.count > index.unsignedIntegerValue) {
      XCUIElement *picker = [pickers elementBoundByIndex:index.unsignedIntegerValue];
      if (picker.exists) {
        [picker adjustToPickerWheelValue:value];
        return YES;
      }
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:14
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Picker at index %@ not found within %.1fs", index, timeout]}];
  return NO;
}

#pragma mark - Coordinate Actions

- (BOOL)executeTapXY:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *x = step[@"x"];
  NSNumber *y = step[@"y"];
  
  if (!x || !y) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:15
                             userInfo:@{NSLocalizedDescriptionKey: @"'x' and 'y' required for tapXY"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  XCUICoordinate *coord = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
  XCUICoordinate *target = [coord coordinateWithOffset:CGVectorMake(x.doubleValue, y.doubleValue)];
  [target tap];
  return YES;
}

- (BOOL)executeSwipe:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *x = step[@"x"];
  NSNumber *y = step[@"y"];
  NSNumber *toX = step[@"toX"];
  NSNumber *toY = step[@"toY"];
  NSNumber *duration = step[@"duration"];
  
  if (!x || !y || !toX || !toY) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:16
                             userInfo:@{NSLocalizedDescriptionKey: @"'x', 'y', 'toX', 'toY' required for swipe"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  XCUICoordinate *start = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                           coordinateWithOffset:CGVectorMake(x.doubleValue, y.doubleValue)];
  XCUICoordinate *end = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                         coordinateWithOffset:CGVectorMake(toX.doubleValue, toY.doubleValue)];
  
  NSTimeInterval dur = duration ? duration.doubleValue : 0.3;
  [start pressForDuration:dur thenDragToCoordinate:end];
  return YES;
}

#pragma mark - Input Actions

- (BOOL)executeType:(NSDictionary *)step error:(NSError **)error
{
  NSString *text = step[@"value"] ?: step[@"text"];
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!text) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:17
                             userInfo:@{NSLocalizedDescriptionKey: @"'value' or 'text' required for type action"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  
  // If selector provided, tap element first
  if (selector) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL found = NO;
    
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
      XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      if (element && element.exists) {
        [element tap];
        found = YES;
        break;
      }
      [NSThread sleepForTimeInterval:0.1];
    }
    
    if (!found) {
      *error = [NSError errorWithDomain:@"FBScriptExecutor" code:18
                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for typing", selector]}];
      return NO;
    }
  }
  
  [app typeText:text];
  return YES;
}

- (BOOL)executeClear:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for clear"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (element && element.exists) {
      [element tap];
      [element pressForDuration:1.0];
      
      XCUIElement *selectAll = app.menuItems[@"Select All"];
      if (selectAll.waitForExistenceWithTimeout:1.0]) {
        [selectAll tap];
        [app typeText:XCUIKeyboardKeyDelete];
      }
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:19
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for clearing", selector]}];
  return NO;
}

#pragma mark - Utility Actions

- (BOOL)executeSleep:(NSDictionary *)step error:(NSError **)error
{
  NSTimeInterval duration = [step[@"timeout"] doubleValue] ?: [step[@"duration"] doubleValue] ?: 1.0;
  [NSThread sleepForTimeInterval:duration];
  return YES;
}

- (BOOL)executeScreenshot:(NSDictionary *)step error:(NSError **)error
{
  NSString *key = step[@"as"] ?: @"screenshot";
  
  XCUIScreenshot *screenshot = XCUIScreen.mainScreen.screenshot;
  NSData *pngData = screenshot.PNGRepresentation;
  NSString *base64 = [pngData base64EncodedStringWithOptions:0];
  
  self.results[key] = base64;
  return YES;
}

- (BOOL)executeHome:(NSDictionary *)step error:(NSError **)error
{
  [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
  return YES;
}

#pragma mark - Vision/OCR Actions

#if !TARGET_OS_TV

- (UIImage *)captureScreenshot
{
  XCUIScreenshot *screenshot = XCUIScreen.mainScreen.screenshot;
  return screenshot.image;
}

- (BOOL)executeClickText:(NSDictionary *)step error:(NSError **)error
{
  NSString *searchText = step[@"text"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!searchText) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:20
                             userInfo:@{NSLocalizedDescriptionKey: @"'text' required for clickText"}];
    return NO;
  }
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    UIImage *screenshot = [self captureScreenshot];
    CGPoint point = [self findTextInImage:screenshot text:searchText];
    
    if (!CGPointEqualToPoint(point, CGPointZero)) {
      XCUIApplication *app = [self getTargetApp];
      XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                               coordinateWithOffset:CGVectorMake(point.x, point.y)];
      [coord tap];
      return YES;
    }
    
    [NSThread sleepForTimeInterval:0.2];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:21
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Text '%@' not found on screen within %.1fs", searchText, timeout]}];
  return NO;
}

- (BOOL)executeWaitText:(NSDictionary *)step error:(NSError **)error
{
  NSString *searchText = step[@"text"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!searchText) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:20
                             userInfo:@{NSLocalizedDescriptionKey: @"'text' required for waitText"}];
    return NO;
  }
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    UIImage *screenshot = [self captureScreenshot];
    CGPoint point = [self findTextInImage:screenshot text:searchText];
    
    if (!CGPointEqualToPoint(point, CGPointZero)) {
      return YES;
    }
    
    [NSThread sleepForTimeInterval:0.2];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:22
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Text '%@' not found on screen within %.1fs", searchText, timeout]}];
  return NO;
}

- (CGPoint)findTextInImage:(UIImage *)image text:(NSString *)searchText
{
  __block CGPoint foundPoint = CGPointZero;
  
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  
  VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
    if (error) {
      dispatch_semaphore_signal(semaphore);
      return;
    }
    
    NSArray<VNRecognizedTextObservation *> *observations = request.results;
    CGFloat imageHeight = image.size.height;
    CGFloat imageWidth = image.size.width;
    
    for (VNRecognizedTextObservation *observation in observations) {
      NSArray<VNRecognizedText *> *candidates = [observation topCandidates:1];
      if (candidates.count == 0) continue;
      
      NSString *text = candidates.firstObject.string;
      
      if ([text localizedCaseInsensitiveContainsString:searchText]) {
        CGRect boundingBox = observation.boundingBox;
        CGFloat centerX = (boundingBox.origin.x + boundingBox.size.width / 2) * imageWidth;
        CGFloat centerY = (1 - boundingBox.origin.y - boundingBox.size.height / 2) * imageHeight;
        foundPoint = CGPointMake(centerX, centerY);
        break;
      }
    }
    
    dispatch_semaphore_signal(semaphore);
  }];
  
  request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
  request.usesLanguageCorrection = YES;
  
  CGImageRef cgImage = image.CGImage;
  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
  
  NSError *performError = nil;
  [handler performRequests:@[request] error:&performError];
  
  dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
  
  return foundPoint;
}

- (BOOL)executeReadRegion:(NSDictionary *)step error:(NSError **)error
{
  NSString *key = step[@"as"] ?: @"regionText";
  
  UIImage *screenshot = [self captureScreenshot];
  UIImage *targetImage = screenshot;
  
  // Crop if region specified
  NSNumber *regionX = step[@"regionX"];
  NSNumber *regionY = step[@"regionY"];
  NSNumber *regionWidth = step[@"regionWidth"];
  NSNumber *regionHeight = step[@"regionHeight"];
  
  if (regionX && regionY && regionWidth && regionHeight) {
    CGRect cropRect = CGRectMake(
      regionX.doubleValue,
      regionY.doubleValue,
      regionWidth.doubleValue,
      regionHeight.doubleValue
    );
    CGImageRef croppedCGImage = CGImageCreateWithImageInRect(screenshot.CGImage, cropRect);
    if (croppedCGImage) {
      targetImage = [UIImage imageWithCGImage:croppedCGImage];
      CGImageRelease(croppedCGImage);
    }
  }
  
  NSString *recognizedText = [self recognizeTextInImage:targetImage];
  self.results[key] = recognizedText ?: @"";
  return YES;
}

- (NSString *)recognizeTextInImage:(UIImage *)image
{
  __block NSMutableString *result = [NSMutableString string];
  
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  
  VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
    if (error) {
      dispatch_semaphore_signal(semaphore);
      return;
    }
    
    NSArray<VNRecognizedTextObservation *> *observations = request.results;
    
    for (VNRecognizedTextObservation *observation in observations) {
      NSArray<VNRecognizedText *> *candidates = [observation topCandidates:1];
      if (candidates.count > 0) {
        [result appendString:candidates.firstObject.string];
        [result appendString:@" "];
      }
    }
    
    dispatch_semaphore_signal(semaphore);
  }];
  
  request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
  request.usesLanguageCorrection = YES;
  
  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
  
  NSError *performError = nil;
  [handler performRequests:@[request] error:&performError];
  
  dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
  
  return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (BOOL)executeClickImage:(NSDictionary *)step error:(NSError **)error
{
  NSString *imageBase64 = step[@"imageBase64"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  CGFloat confidence = [step[@"confidence"] doubleValue] ?: 0.8;
  
  if (!imageBase64) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:23
                             userInfo:@{NSLocalizedDescriptionKey: @"'imageBase64' required for clickImage"}];
    return NO;
  }
  
  NSData *templateData = [[NSData alloc] initWithBase64EncodedString:imageBase64 options:0];
  UIImage *templateImage = [UIImage imageWithData:templateData];
  
  if (!templateImage) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:24
                             userInfo:@{NSLocalizedDescriptionKey: @"Cannot decode template image from base64"}];
    return NO;
  }
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    UIImage *screenshot = [self captureScreenshot];
    CGPoint point = [self findTemplateInImage:screenshot template:templateImage confidence:confidence];
    
    if (!CGPointEqualToPoint(point, CGPointZero)) {
      XCUIApplication *app = [self getTargetApp];
      XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                               coordinateWithOffset:CGVectorMake(point.x, point.y)];
      [coord tap];
      return YES;
    }
    
    [NSThread sleepForTimeInterval:0.2];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:25
                           userInfo:@{NSLocalizedDescriptionKey: @"Template image not found on screen"}];
  return NO;
}

- (CGPoint)findTemplateInImage:(UIImage *)screenshot template:(UIImage *)templateImage confidence:(CGFloat)minConfidence
{
  CGImageRef screenshotCG = screenshot.CGImage;
  CGImageRef templateCG = templateImage.CGImage;
  
  size_t screenshotWidth = CGImageGetWidth(screenshotCG);
  size_t screenshotHeight = CGImageGetHeight(screenshotCG);
  size_t templateWidth = CGImageGetWidth(templateCG);
  size_t templateHeight = CGImageGetHeight(templateCG);
  
  if (templateWidth > screenshotWidth || templateHeight > screenshotHeight) {
    return CGPointZero;
  }
  
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  
  size_t bytesPerPixel = 4;
  size_t screenshotBytesPerRow = bytesPerPixel * screenshotWidth;
  size_t templateBytesPerRow = bytesPerPixel * templateWidth;
  
  unsigned char *screenshotData = (unsigned char *)calloc(screenshotHeight * screenshotBytesPerRow, 1);
  unsigned char *templateData = (unsigned char *)calloc(templateHeight * templateBytesPerRow, 1);
  
  CGContextRef screenshotContext = CGBitmapContextCreate(screenshotData, screenshotWidth, screenshotHeight,
                                                          8, screenshotBytesPerRow, colorSpace,
                                                          kCGImageAlphaPremultipliedLast);
  CGContextRef templateContext = CGBitmapContextCreate(templateData, templateWidth, templateHeight,
                                                        8, templateBytesPerRow, colorSpace,
                                                        kCGImageAlphaPremultipliedLast);
  
  CGContextDrawImage(screenshotContext, CGRectMake(0, 0, screenshotWidth, screenshotHeight), screenshotCG);
  CGContextDrawImage(templateContext, CGRectMake(0, 0, templateWidth, templateHeight), templateCG);
  
  CGPoint bestMatch = CGPointZero;
  CGFloat bestScore = 0;
  
  size_t stepSize = 4;
  
  for (size_t y = 0; y <= screenshotHeight - templateHeight; y += stepSize) {
    for (size_t x = 0; x <= screenshotWidth - templateWidth; x += stepSize) {
      CGFloat score = [self compareRegionAtX:x y:y
                              screenshotData:screenshotData
                             screenshotWidth:screenshotWidth
                                templateData:templateData
                               templateWidth:templateWidth
                              templateHeight:templateHeight];
      
      if (score > bestScore) {
        bestScore = score;
        bestMatch = CGPointMake(x + templateWidth / 2.0, y + templateHeight / 2.0);
      }
    }
  }
  
  CGContextRelease(screenshotContext);
  CGContextRelease(templateContext);
  CGColorSpaceRelease(colorSpace);
  free(screenshotData);
  free(templateData);
  
  if (bestScore >= minConfidence) {
    return bestMatch;
  }
  
  return CGPointZero;
}

- (CGFloat)compareRegionAtX:(size_t)offsetX y:(size_t)offsetY
             screenshotData:(unsigned char *)screenshot
            screenshotWidth:(size_t)screenshotWidth
               templateData:(unsigned char *)templateData
              templateWidth:(size_t)templateWidth
             templateHeight:(size_t)templateHeight
{
  size_t bytesPerPixel = 4;
  size_t screenshotBytesPerRow = bytesPerPixel * screenshotWidth;
  size_t templateBytesPerRow = bytesPerPixel * templateWidth;
  
  CGFloat totalScore = 0;
  size_t sampleCount = 0;
  size_t sampleStep = 4;
  
  for (size_t ty = 0; ty < templateHeight; ty += sampleStep) {
    for (size_t tx = 0; tx < templateWidth; tx += sampleStep) {
      size_t sx = offsetX + tx;
      size_t sy = offsetY + ty;
      
      size_t screenshotIndex = sy * screenshotBytesPerRow + sx * bytesPerPixel;
      size_t templateIndex = ty * templateBytesPerRow + tx * bytesPerPixel;
      
      int sr = screenshot[screenshotIndex];
      int sg = screenshot[screenshotIndex + 1];
      int sb = screenshot[screenshotIndex + 2];
      
      int tr = templateData[templateIndex];
      int tg = templateData[templateIndex + 1];
      int tb = templateData[templateIndex + 2];
      
      CGFloat diff = (abs(sr - tr) + abs(sg - tg) + abs(sb - tb)) / (3.0 * 255.0);
      totalScore += (1.0 - diff);
      sampleCount++;
    }
  }
  
  return sampleCount > 0 ? totalScore / sampleCount : 0;
}

#endif // !TARGET_OS_TV

@end

#pragma mark - FBCustomCommands Implementation

@implementation FBCustomCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute POST:@"/timeouts"] respondWithTarget:self action:@selector(handleTimeouts:)],
    [[FBRoute POST:@"/wda/homescreen"].withoutSession respondWithTarget:self action:@selector(handleHomescreenCommand:)],
    [[FBRoute POST:@"/wda/deactivateApp"] respondWithTarget:self action:@selector(handleDeactivateAppCommand:)],
    [[FBRoute POST:@"/wda/keyboard/dismiss"] respondWithTarget:self action:@selector(handleDismissKeyboardCommand:)],
    [[FBRoute POST:@"/wda/lock"].withoutSession respondWithTarget:self action:@selector(handleLock:)],
    [[FBRoute POST:@"/wda/lock"] respondWithTarget:self action:@selector(handleLock:)],
    [[FBRoute POST:@"/wda/unlock"].withoutSession respondWithTarget:self action:@selector(handleUnlock:)],
    [[FBRoute POST:@"/wda/unlock"] respondWithTarget:self action:@selector(handleUnlock:)],
    [[FBRoute GET:@"/wda/locked"].withoutSession respondWithTarget:self action:@selector(handleIsLocked:)],
    [[FBRoute GET:@"/wda/locked"] respondWithTarget:self action:@selector(handleIsLocked:)],
    [[FBRoute GET:@"/wda/screen"] respondWithTarget:self action:@selector(handleGetScreen:)],
    [[FBRoute GET:@"/wda/screen"].withoutSession respondWithTarget:self action:@selector(handleGetScreen:)],
    [[FBRoute GET:@"/wda/activeAppInfo"] respondWithTarget:self action:@selector(handleActiveAppInfo:)],
    [[FBRoute GET:@"/wda/activeAppInfo"].withoutSession respondWithTarget:self action:@selector(handleActiveAppInfo:)],
#if !TARGET_OS_TV
    [[FBRoute POST:@"/wda/setPasteboard"] respondWithTarget:self action:@selector(handleSetPasteboard:)],
    [[FBRoute POST:@"/wda/setPasteboard"].withoutSession respondWithTarget:self action:@selector(handleSetPasteboard:)],
    [[FBRoute POST:@"/wda/getPasteboard"] respondWithTarget:self action:@selector(handleGetPasteboard:)],
    [[FBRoute POST:@"/wda/getPasteboard"].withoutSession respondWithTarget:self action:@selector(handleGetPasteboard:)],
    [[FBRoute GET:@"/wda/batteryInfo"] respondWithTarget:self action:@selector(handleGetBatteryInfo:)],
#endif
    [[FBRoute POST:@"/wda/pressButton"] respondWithTarget:self action:@selector(handlePressButtonCommand:)],
    [[FBRoute POST:@"/wda/performAccessibilityAudit"] respondWithTarget:self action:@selector(handlePerformAccessibilityAudit:)],
    [[FBRoute POST:@"/wda/performIoHidEvent"] respondWithTarget:self action:@selector(handlePeformIOHIDEvent:)],
    [[FBRoute POST:@"/wda/expectNotification"] respondWithTarget:self action:@selector(handleExpectNotification:)],
    [[FBRoute POST:@"/wda/siri/activate"] respondWithTarget:self action:@selector(handleActivateSiri:)],
    [[FBRoute POST:@"/wda/apps/launchUnattached"].withoutSession respondWithTarget:self action:@selector(handleLaunchUnattachedApp:)],
    [[FBRoute GET:@"/wda/device/info"] respondWithTarget:self action:@selector(handleGetDeviceInfo:)],
    [[FBRoute POST:@"/wda/resetAppAuth"] respondWithTarget:self action:@selector(handleResetAppAuth:)],
    [[FBRoute GET:@"/wda/device/info"].withoutSession respondWithTarget:self action:@selector(handleGetDeviceInfo:)],
    [[FBRoute POST:@"/wda/device/appearance"].withoutSession respondWithTarget:self action:@selector(handleSetDeviceAppearance:)],
    [[FBRoute GET:@"/wda/device/location"] respondWithTarget:self action:@selector(handleGetLocation:)],
    [[FBRoute GET:@"/wda/device/location"].withoutSession respondWithTarget:self action:@selector(handleGetLocation:)],
#if !TARGET_OS_TV
#if __clang_major__ >= 15
    [[FBRoute POST:@"/wda/element/:uuid/keyboardInput"] respondWithTarget:self action:@selector(handleKeyboardInput:)],
#endif
    [[FBRoute POST:@"/wda/media/import"] respondWithTarget:self action:@selector(handleMediaImport:)],
    [[FBRoute POST:@"/wda/media/import"].withoutSession respondWithTarget:self action:@selector(handleMediaImport:)],
    [[FBRoute POST:@"/wda/media/pop"] respondWithTarget:self action:@selector(handleMediaPop:)],
    [[FBRoute POST:@"/wda/media/pop"].withoutSession respondWithTarget:self action:@selector(handleMediaPop:)],
    [[FBRoute GET:@"/wda/simulatedLocation"] respondWithTarget:self action:@selector(handleGetSimulatedLocation:)],
    [[FBRoute GET:@"/wda/simulatedLocation"].withoutSession respondWithTarget:self action:@selector(handleGetSimulatedLocation:)],
    [[FBRoute POST:@"/wda/simulatedLocation"] respondWithTarget:self action:@selector(handleSetSimulatedLocation:)],
    [[FBRoute POST:@"/wda/simulatedLocation"].withoutSession respondWithTarget:self action:@selector(handleSetSimulatedLocation:)],
    [[FBRoute DELETE:@"/wda/simulatedLocation"] respondWithTarget:self action:@selector(handleClearSimulatedLocation:)],
    [[FBRoute DELETE:@"/wda/simulatedLocation"].withoutSession respondWithTarget:self action:@selector(handleClearSimulatedLocation:)],
    // Script execution endpoint
    [[FBRoute POST:@"/wda/script"] respondWithTarget:self action:@selector(handleScript:)],
    [[FBRoute POST:@"/wda/script"].withoutSession respondWithTarget:self action:@selector(handleScript:)],
#endif
    [[FBRoute OPTIONS:@"/*"].withoutSession respondWithTarget:self action:@selector(handlePingCommand:)],
  ];
}

#pragma mark - Script Execution

+ (id<FBResponsePayload>)handleScript:(FBRouteRequest *)request
{
  NSArray *stepsArray = request.arguments[@"steps"];
  
  if (!stepsArray || ![stepsArray isKindOfClass:[NSArray class]]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'steps' array is required"
                                                                       traceback:nil]);
  }
  
  if (stepsArray.count == 0) {
    return FBResponseWithObject(@{
      @"success": @YES,
      @"results": @{},
      @"stoppedAt": [NSNull null],
      @"error": [NSNull null]
    });
  }
  
  for (id step in stepsArray) {
    if (![step isKindOfClass:[NSDictionary class]]) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Each step must be a dictionary"
                                                                         traceback:nil]);
    }
  }
  
  FBScriptExecutor *executor = [[FBScriptExecutor alloc] init];
  NSDictionary *result = [executor executeSteps:stepsArray];
  
  return FBResponseWithObject(result);
}

#pragma mark - Original Commands

+ (id<FBResponsePayload>)handleHomescreenCommand:(FBRouteRequest *)request
{
  NSError *error;
  if (![[XCUIDevice sharedDevice] fb_goToHomescreenWithError:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleDeactivateAppCommand:(FBRouteRequest *)request
{
  NSNumber *requestedDuration = request.arguments[@"duration"];
  NSTimeInterval duration = (requestedDuration ? requestedDuration.doubleValue : 3.);
  NSError *error;
  if (![request.session.activeApplication fb_deactivateWithDuration:duration error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleTimeouts:(FBRouteRequest *)request
{
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleDismissKeyboardCommand:(FBRouteRequest *)request
{
  NSError *error;
  BOOL isDismissed = [request.session.activeApplication fb_dismissKeyboardWithKeyNames:request.arguments[@"keyNames"]
                                                                                 error:&error];
  return isDismissed
  ? FBResponseWithOK()
  : FBResponseWithStatus([FBCommandStatus invalidElementStateErrorWithMessage:error.description
                                                                    traceback:nil]);
}

+ (id<FBResponsePayload>)handlePingCommand:(FBRouteRequest *)request
{
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleGetScreen:(FBRouteRequest *)request
{
  XCUIApplication *app = XCUIApplication.fb_systemApplication;
  XCUIElement *mainStatusBar = app.statusBars.allElementsBoundByIndex.firstObject;
  CGSize statusBarSize = (nil == mainStatusBar) ? CGSizeZero : mainStatusBar.frame.size;

#if TARGET_OS_TV
  CGSize screenSize = app.frame.size;
#else
  CGSize screenSize = FBAdjustDimensionsForApplication(app.wdFrame.size, app.interfaceOrientation);
#endif

  return FBResponseWithObject(@{
    @"screenSize": @{@"width": @(screenSize.width), @"height": @(screenSize.height)},
    @"statusBarSize": @{@"width": @(statusBarSize.width), @"height": @(statusBarSize.height)},
    @"scale": @([FBScreen scale]),
  });
}

+ (id<FBResponsePayload>)handleLock:(FBRouteRequest *)request
{
  NSError *error;
  if (![[XCUIDevice sharedDevice] fb_lockScreen:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleIsLocked:(FBRouteRequest *)request
{
  BOOL isLocked = [XCUIDevice sharedDevice].fb_isScreenLocked;
  return FBResponseWithObject(isLocked ? @YES : @NO);
}

+ (id<FBResponsePayload>)handleUnlock:(FBRouteRequest *)request
{
  NSError *error;
  if (![[XCUIDevice sharedDevice] fb_unlockScreen:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleActiveAppInfo:(FBRouteRequest *)request
{
  XCUIApplication *app = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  return FBResponseWithObject(@{
    @"pid": @(app.processID),
    @"bundleId": app.bundleID,
    @"name": app.identifier,
    @"processArguments": [self processArguments:app],
  });
}

+ (NSDictionary *)processArguments:(XCUIApplication *)app
{
  if (app == nil) {
    return @{};
  }
  return @{
    @"args": app.launchArguments,
    @"env": app.launchEnvironment
  };
}

#if !TARGET_OS_TV
+ (id<FBResponsePayload>)handleSetPasteboard:(FBRouteRequest *)request
{
  NSString *contentType = request.arguments[@"contentType"] ?: @"plaintext";
  NSData *content = [[NSData alloc] initWithBase64EncodedString:(NSString *)request.arguments[@"content"]
                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
  if (nil == content) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Cannot decode the pasteboard content from base64" traceback:nil]);
  }
  NSError *error;
  if (![FBPasteboard setData:content forType:contentType error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleGetPasteboard:(FBRouteRequest *)request
{
  NSString *contentType = request.arguments[@"contentType"] ?: @"plaintext";
  NSError *error;
  id result = [FBPasteboard dataForType:contentType error:&error];
  if (nil == result) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithObject([result base64EncodedStringWithOptions:0]);
}

+ (id<FBResponsePayload>)handleGetBatteryInfo:(FBRouteRequest *)request
{
  if (![[UIDevice currentDevice] isBatteryMonitoringEnabled]) {
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
  }
  return FBResponseWithObject(@{
    @"level": @([UIDevice currentDevice].batteryLevel),
    @"state": @([UIDevice currentDevice].batteryState)
  });
}
#endif

+ (id<FBResponsePayload>)handlePressButtonCommand:(FBRouteRequest *)request
{
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_pressButton:(id)request.arguments[@"name"]
                                   forDuration:(NSNumber *)request.arguments[@"duration"]
                                         error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleActivateSiri:(FBRouteRequest *)request
{
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_activateSiriVoiceRecognitionWithText:(id)request.arguments[@"text"] error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handlePeformIOHIDEvent:(FBRouteRequest *)request
{
  NSNumber *page = request.arguments[@"page"];
  NSNumber *usage = request.arguments[@"usage"];
  NSNumber *duration = request.arguments[@"duration"];
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_performIOHIDEventWithPage:page.unsignedIntValue
                                                       usage:usage.unsignedIntValue
                                                    duration:duration.doubleValue
                                                       error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleLaunchUnattachedApp:(FBRouteRequest *)request
{
  NSString *bundle = (NSString *)request.arguments[@"bundleId"];
  if ([FBUnattachedAppLauncher launchAppWithBundleId:bundle]) {
    return FBResponseWithOK();
  }
  return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"LSApplicationWorkspace failed to launch app" traceback:nil]);
}

+ (id<FBResponsePayload>)handleResetAppAuth:(FBRouteRequest *)request
{
  NSNumber *resource = request.arguments[@"resource"];
  if (nil == resource) {
    NSString *errMsg = @"The 'resource' argument must be set to a valid resource identifier";
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:errMsg traceback:nil]);
  }
  [request.session.activeApplication resetAuthorizationStatusForResource:(XCUIProtectedResource)resource.longLongValue];
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleGetLocation:(FBRouteRequest *)request
{
#if TARGET_OS_TV
  return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"unsupported" traceback:nil]);
#else
  CLLocationManager *locationManager = [[CLLocationManager alloc] init];
  [locationManager setDistanceFilter:kCLHeadingFilterNone];
  [locationManager setDesiredAccuracy:kCLLocationAccuracyBest];
  [locationManager setPausesLocationUpdatesAutomatically:NO];
  [locationManager startUpdatingLocation];

  CLAuthorizationStatus authStatus;
  if ([locationManager respondsToSelector:@selector(authorizationStatus)]) {
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[[locationManager class]
                                                                            instanceMethodSignatureForSelector:@selector(authorizationStatus)]];
    [invocation setSelector:@selector(authorizationStatus)];
    [invocation setTarget:locationManager];
    [invocation invoke];
    [invocation getReturnValue:&authStatus];
  } else {
    authStatus = [CLLocationManager authorizationStatus];
  }

  return FBResponseWithObject(@{
    @"authorizationStatus": @(authStatus),
    @"latitude": @(locationManager.location.coordinate.latitude),
    @"longitude": @(locationManager.location.coordinate.longitude),
    @"altitude": @(locationManager.location.altitude),
  });
#endif
}

+ (id<FBResponsePayload>)handleExpectNotification:(FBRouteRequest *)request
{
  NSString *name = request.arguments[@"name"];
  if (nil == name) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Notification name argument must be provided" traceback:nil]);
  }
  NSNumber *timeout = request.arguments[@"timeout"] ?: @60;
  NSString *type = request.arguments[@"type"] ?: @"plain";

  XCTWaiterResult result;
  if ([type isEqualToString:@"plain"]) {
    result = [FBNotificationsHelper waitForNotificationWithName:name timeout:timeout.doubleValue];
  } else if ([type isEqualToString:@"darwin"]) {
    result = [FBNotificationsHelper waitForDarwinNotificationWithName:name timeout:timeout.doubleValue];
  } else {
    NSString *message = [NSString stringWithFormat:@"Notification type could only be 'plain' or 'darwin'. Got '%@' instead", type];
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message traceback:nil]);
  }
  if (result != XCTWaiterResultCompleted) {
    NSString *message = [NSString stringWithFormat:@"Did not receive any expected %@ notifications within %@s", name, timeout];
    return FBResponseWithStatus([FBCommandStatus timeoutErrorWithMessage:message traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleSetDeviceAppearance:(FBRouteRequest *)request
{
  NSString *name = [request.arguments[@"name"] lowercaseString];
  if (nil == name || !([name isEqualToString:@"light"] || [name isEqualToString:@"dark"])) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"The appearance name must be either 'light' or 'dark'" traceback:nil]);
  }

  FBUIInterfaceAppearance appearance = [name isEqualToString:@"light"]
    ? FBUIInterfaceAppearanceLight
    : FBUIInterfaceAppearanceDark;
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_setAppearance:appearance error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleGetDeviceInfo:(FBRouteRequest *)request
{
  NSString *currentLocale = [[NSLocale autoupdatingCurrentLocale] localeIdentifier];

  NSMutableDictionary *deviceInfo = [NSMutableDictionary dictionaryWithDictionary:@{
    @"currentLocale": currentLocale,
    @"timeZone": self.timeZone,
    @"name": UIDevice.currentDevice.name,
    @"model": UIDevice.currentDevice.model,
    @"uuid": [UIDevice.currentDevice.identifierForVendor UUIDString] ?: @"unknown",
    @"userInterfaceIdiom": @(UIDevice.currentDevice.userInterfaceIdiom),
    @"userInterfaceStyle": self.userInterfaceStyle,
#if TARGET_OS_SIMULATOR
    @"isSimulator": @(YES),
#else
    @"isSimulator": @(NO),
#endif
  }];

  deviceInfo[@"thermalState"] = @(NSProcessInfo.processInfo.thermalState);
  return FBResponseWithObject(deviceInfo);
}

+ (NSString *)userInterfaceStyle
{
  if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"15.0")) {
    NSNumber *appearance = [XCUIDevice.sharedDevice fb_getAppearance];
    if (appearance != nil) {
      return [self getAppearanceName:appearance];
    }
  }

  static id userInterfaceStyle = nil;
  static dispatch_once_t styleOnceToken;
  dispatch_once(&styleOnceToken, ^{
    if ([UITraitCollection respondsToSelector:NSSelectorFromString(@"currentTraitCollection")]) {
      id currentTraitCollection = [UITraitCollection performSelector:NSSelectorFromString(@"currentTraitCollection")];
      if (nil != currentTraitCollection) {
        userInterfaceStyle = [currentTraitCollection valueForKey:@"userInterfaceStyle"];
      }
    }
  });

  if (nil == userInterfaceStyle) {
    return @"unsupported";
  }
  return [self getAppearanceName:userInterfaceStyle];
}

+ (NSString *)getAppearanceName:(NSNumber *)appearance
{
  switch ([appearance longLongValue]) {
    case FBUIInterfaceAppearanceUnspecified: return @"automatic";
    case FBUIInterfaceAppearanceLight: return @"light";
    case FBUIInterfaceAppearanceDark: return @"dark";
    default: return @"unknown";
  }
}

+ (NSString *)timeZone
{
  NSTimeZone *localTimeZone = [NSTimeZone localTimeZone];
  NSString *timeZoneAbb = [localTimeZone abbreviation];
  if (timeZoneAbb == nil) {
    return [localTimeZone name];
  }
  NSString *timeZoneId = [[NSTimeZone timeZoneWithAbbreviation:timeZoneAbb] name];
  if (timeZoneId != nil) {
    return timeZoneId;
  }
  return [localTimeZone name];
}

#if !TARGET_OS_TV
+ (id<FBResponsePayload>)handleGetSimulatedLocation:(FBRouteRequest *)request
{
  NSError *error;
  CLLocation *location = [XCUIDevice.sharedDevice fb_getSimulatedLocation:&error];
  if (nil != error) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description traceback:nil]);
  }
  return FBResponseWithObject(@{
    @"latitude": location ? @(location.coordinate.latitude) : NSNull.null,
    @"longitude": location ? @(location.coordinate.longitude) : NSNull.null,
    @"altitude": location ? @(location.altitude) : NSNull.null,
  });
}

+ (id<FBResponsePayload>)handleSetSimulatedLocation:(FBRouteRequest *)request
{
  NSNumber *longitude = request.arguments[@"longitude"];
  NSNumber *latitude = request.arguments[@"latitude"];

  if (nil == longitude || nil == latitude) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Both latitude and longitude must be provided" traceback:nil]);
  }
  NSError *error;
  CLLocation *location = [[CLLocation alloc] initWithLatitude:latitude.doubleValue longitude:longitude.doubleValue];
  if (![XCUIDevice.sharedDevice fb_setSimulatedLocation:location error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleClearSimulatedLocation:(FBRouteRequest *)request
{
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_clearSimulatedLocation:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description traceback:nil]);
  }
  return FBResponseWithOK();
}

#if __clang_major__ >= 15
+ (id<FBResponsePayload>)handleKeyboardInput:(FBRouteRequest *)request
{
  FBElementCache *elementCache = request.session.elementCache;
  BOOL hasElement = ![request.parameters[@"uuid"] isEqual:@"0"];
  XCUIElement *destination = hasElement
    ? [elementCache elementForUUID:(NSString *)request.parameters[@"uuid"] checkStaleness:YES]
    : request.session.activeApplication;
  id keys = request.arguments[@"keys"];

  if (![destination respondsToSelector:@selector(typeKey:modifierFlags:)]) {
    return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"typeKey API is only supported since Xcode15 and iPadOS 17" traceback:nil]);
  }

  if (![keys isKindOfClass:NSArray.class]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"The 'keys' argument must be an array" traceback:nil]);
  }
  for (id item in (NSArray *)keys) {
    if ([item isKindOfClass:NSString.class]) {
      NSString *keyValue = [FBKeyboard keyValueForName:item] ?: item;
      [destination typeKey:keyValue modifierFlags:XCUIKeyModifierNone];
    } else if ([item isKindOfClass:NSDictionary.class]) {
      id key = [(NSDictionary *)item objectForKey:@"key"];
      if (![key isKindOfClass:NSString.class]) {
        return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"All dictionaries must have 'key' of type string" traceback:nil]);
      }
      id modifiers = [(NSDictionary *)item objectForKey:@"modifierFlags"];
      NSUInteger modifierFlags = XCUIKeyModifierNone;
      if ([modifiers isKindOfClass:NSNumber.class]) {
        modifierFlags = [(NSNumber *)modifiers unsignedIntValue];
      }
      NSString *keyValue = [FBKeyboard keyValueForName:item] ?: key;
      [destination typeKey:keyValue modifierFlags:modifierFlags];
    } else {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"All items must be dictionaries or strings" traceback:nil]);
    }
  }
  return FBResponseWithOK();
}
#endif

+ (id<FBResponsePayload>)handleMediaImport:(FBRouteRequest *)request
{
  NSString *albumName = request.arguments[@"album"];
  NSString *dataBase64 = request.arguments[@"dataBase64"];
  NSNumber *creationTimestampMs = request.arguments[@"creationTimestampMs"];
  
  BOOL useAlbum = (albumName != nil && albumName.length > 0);
  
  if (nil == dataBase64) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'dataBase64' argument is required" traceback:nil]);
  }
  
  NSData *imageData = [[NSData alloc] initWithBase64EncodedString:dataBase64 options:0];
  if (nil == imageData) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Cannot decode base64 image data" traceback:nil]);
  }
  
  UIImage *image = [UIImage imageWithData:imageData];
  if (nil == image) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Cannot create image from provided data" traceback:nil]);
  }
  
  __block NSError *blockError = nil;
  __block NSString *assetLocalIdentifier = nil;
  
  PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
  if (status == PHAuthorizationStatusNotDetermined) {
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus newStatus) {
      dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    status = [PHPhotoLibrary authorizationStatus];
  }
  
  if (status != PHAuthorizationStatusAuthorized) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Photo library access not authorized" traceback:nil]);
  }
  
  [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
    PHAssetCreationRequest *creationRequest = [PHAssetCreationRequest creationRequestForAssetFromImage:image];
    if (creationTimestampMs != nil) {
      NSDate *creationDate = [NSDate dateWithTimeIntervalSince1970:(creationTimestampMs.doubleValue / 1000.0)];
      creationRequest.creationDate = creationDate;
    }
    assetLocalIdentifier = creationRequest.placeholderForCreatedAsset.localIdentifier;
  } error:&blockError];
  
  if (blockError != nil) {
    return FBResponseWithUnknownError(blockError);
  }
  
  if (useAlbum) {
    __block PHAssetCollection *album = nil;
    PHFetchOptions *fetchOptions = [[PHFetchOptions alloc] init];
    fetchOptions.predicate = [NSPredicate predicateWithFormat:@"title = %@", albumName];
    PHFetchResult<PHAssetCollection *> *collections = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                               subtype:PHAssetCollectionSubtypeAny
                                                                                               options:fetchOptions];
    album = collections.firstObject;
    
    if (nil == album) {
      [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
        [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:albumName];
      } error:&blockError];
      
      if (blockError != nil) {
        return FBResponseWithUnknownError(blockError);
      }
      
      collections = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                             subtype:PHAssetCollectionSubtypeAny
                                                             options:fetchOptions];
      album = collections.firstObject;
    }
    
    if (nil == album) {
      return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Failed to create or find album" traceback:nil]);
    }
    
    PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithLocalIdentifiers:@[assetLocalIdentifier] options:nil];
    PHAsset *asset = assets.firstObject;
    
    if (nil == asset) {
      return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Failed to fetch created asset" traceback:nil]);
    }
    
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
      PHAssetCollectionChangeRequest *albumChangeRequest = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
      [albumChangeRequest addAssets:@[asset]];
    } error:&blockError];
    
    if (blockError != nil) {
      return FBResponseWithUnknownError(blockError);
    }
  }
  
  return FBResponseWithOK();
}

+ (BOOL)handleDeleteConfirmationDialogWithTimeout:(NSTimeInterval)timeout
{
  XCUIApplication *springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
  
  NSArray<NSString *> *deleteButtonLabels = @[
    @"Delete", @"Delete Photo", @"Delete Photos", @"Delete Items", @"Delete Item",
    @"Delete Video", @"Delete Videos",
    @"Удалить", @"Supprimer", @"Löschen", @"Eliminar", @"删除", @"刪除", @"削除", @"삭제"
  ];
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    for (NSString *label in deleteButtonLabels) {
      XCUIElement *deleteButton = springboard.buttons[label];
      if (deleteButton.exists && deleteButton.isHittable) {
        [deleteButton tap];
        return YES;
      }
    }
    
    XCUIElementQuery *alerts = springboard.alerts;
    if (alerts.count > 0) {
      XCUIElement *alert = [alerts elementBoundByIndex:0];
      XCUIElementQuery *alertButtons = alert.buttons;
      
      for (NSUInteger i = 0; i < alertButtons.count; i++) {
        XCUIElement *button = [alertButtons elementBoundByIndex:i];
        NSString *buttonLabel = button.label;
        
        if (buttonLabel == nil) continue;
        
        NSString *lowerLabel = [buttonLabel lowercaseString];
        if ([lowerLabel containsString:@"delete"] || [lowerLabel containsString:@"remove"]) {
          if (button.exists && button.isHittable) {
            [button tap];
            return YES;
          }
        }
      }
    }
    
    [NSThread sleepForTimeInterval:0.1];
  }
  
  return NO;
}

+ (id<FBResponsePayload>)handleMediaPop:(FBRouteRequest *)request
{
  NSString *albumName = request.arguments[@"album"];
  NSNumber *count = request.arguments[@"count"] ?: @1;
  
  BOOL deleteFromLibrary = (albumName == nil || albumName.length == 0);
  
  if (count.integerValue < 1) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'count' must be at least 1" traceback:nil]);
  }
  
  PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
  if (status != PHAuthorizationStatusAuthorized) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Photo library access not authorized" traceback:nil]);
  }
  
  PHFetchResult<PHAsset *> *assets = nil;
  PHAssetCollection *album = nil;
  
  if (deleteFromLibrary) {
    PHFetchOptions *assetFetchOptions = [[PHFetchOptions alloc] init];
    assetFetchOptions.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:YES]];
    assets = [PHAsset fetchAssetsWithOptions:assetFetchOptions];
  } else {
    PHFetchOptions *fetchOptions = [[PHFetchOptions alloc] init];
    fetchOptions.predicate = [NSPredicate predicateWithFormat:@"title = %@", albumName];
    PHFetchResult<PHAssetCollection *> *collections = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                               subtype:PHAssetCollectionSubtypeAny
                                                                                               options:fetchOptions];
    album = collections.firstObject;
    
    if (nil == album) {
      return FBResponseWithOK();
    }
    
    PHFetchOptions *assetFetchOptions = [[PHFetchOptions alloc] init];
    assetFetchOptions.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:YES]];
    assets = [PHAsset fetchAssetsInAssetCollection:album options:assetFetchOptions];
  }
  
  NSInteger actualCount = MIN(count.integerValue, (NSInteger)assets.count);
  if (actualCount == 0) {
    return FBResponseWithOK();
  }
  
  NSMutableArray<PHAsset *> *assetsToProcess = [NSMutableArray arrayWithCapacity:actualCount];
  for (NSInteger i = 0; i < actualCount; i++) {
    [assetsToProcess addObject:[assets objectAtIndex:i]];
  }
  
  __block NSError *blockError = nil;
  
  if (deleteFromLibrary) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL operationCompleted = NO;
    
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
      [PHAssetChangeRequest deleteAssets:assetsToProcess];
    } completionHandler:^(BOOL success, NSError *error) {
      if (!success && error != nil) {
        blockError = error;
      }
      operationCompleted = YES;
      dispatch_semaphore_signal(semaphore);
    }];
    
    [NSThread sleepForTimeInterval:0.5];
    [self handleDeleteConfirmationDialogWithTimeout:5.0];
    
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC);
    dispatch_semaphore_wait(semaphore, timeout);
    
    if (!operationCompleted) {
      return FBResponseWithStatus([FBCommandStatus timeoutErrorWithMessage:@"Delete operation timed out" traceback:nil]);
    }
  } else {
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
      PHAssetCollectionChangeRequest *albumChangeRequest = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
      [albumChangeRequest removeAssets:assetsToProcess];
    } error:&blockError];
  }
  
  if (blockError != nil) {
    return FBResponseWithUnknownError(blockError);
  }
  
  return FBResponseWithOK();
}
#endif

+ (id<FBResponsePayload>)handlePerformAccessibilityAudit:(FBRouteRequest *)request
{
  NSError *error;
  NSArray *requestedTypes = request.arguments[@"auditTypes"];
  NSMutableSet *typesSet = [NSMutableSet set];
  if (nil == requestedTypes || 0 == [requestedTypes count]) {
    [typesSet addObject:@"XCUIAccessibilityAuditTypeAll"];
  } else {
    [typesSet addObjectsFromArray:requestedTypes];
  }
  NSArray *result = [request.session.activeApplication fb_performAccessibilityAuditWithAuditTypesSet:typesSet.copy error:&error];
  if (nil == result) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description traceback:nil]);
  }
  return FBResponseWithObject(result);
}

@end