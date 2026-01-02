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
#import "FBElementCache.h"

#pragma mark - Stream Writer Protocol

@protocol FBStreamWriter <NSObject>
- (void)writeEvent:(NSDictionary *)event;
- (void)close;
@end

#pragma mark - Script Executor

@interface FBScriptExecutor : NSObject

@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *results;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *variables;
@property (nonatomic, strong) XCUIApplication *currentApp;
@property (nonatomic, strong) XCUIApplication *springboard;
@property (nonatomic, weak) id<FBStreamWriter> streamWriter;
@property (nonatomic, assign) BOOL shouldStop;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *foundElements;  // Cache for forEach

- (NSDictionary *)executeSteps:(NSArray<NSDictionary *> *)steps;

@end

@implementation FBScriptExecutor

- (instancetype)init
{
  self = [super init];
  if (self) {
    _results = [NSMutableDictionary dictionary];
    _variables = [NSMutableDictionary dictionary];
    _springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
    _foundElements = [NSMutableArray array];
    _shouldStop = NO;
  }
  return self;
}

- (void)emitEvent:(NSString *)type data:(NSDictionary *)data
{
  if (!self.streamWriter) return;
  
  NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:data];
  event[@"type"] = type;
  event[@"timestamp"] = @([[NSDate date] timeIntervalSince1970] * 1000);
  
  [self.streamWriter writeEvent:event];
}

- (void)log:(NSString *)level message:(NSString *)message
{
  [self emitEvent:@"log" data:@{@"level": level, @"message": message}];
}

- (NSDictionary *)executeSteps:(NSArray<NSDictionary *> *)steps
{
  NSDate *startTime = [NSDate date];
  
  for (NSUInteger i = 0; i < steps.count; i++) {
    if (self.shouldStop) {
      return @{
        @"success": @NO,
        @"results": self.results,
        @"variables": self.variables,
        @"stoppedAt": @(i),
        @"error": @"Execution stopped"
      };
    }
    
    NSDictionary *step = steps[i];
    NSString *action = step[@"action"] ?: @"unknown";
    NSError *error = nil;
    
    [self emitEvent:@"step_start" data:@{@"index": @(i), @"action": action}];
    
    NSDate *stepStart = [NSDate date];
    BOOL success = NO;
    
    @try {
      success = [self executeStep:step error:&error];
    } @catch (NSException *exception) {
      if ([exception.name isEqualToString:@"FBScriptBreak"]) {
        // Break from loop
        return @{
          @"success": @YES,
          @"results": self.results,
          @"variables": self.variables,
          @"stoppedAt": @(i),
          @"error": [NSNull null],
          @"break": @YES
        };
      }
      error = [NSError errorWithDomain:@"FBScriptExecutor" code:999
                              userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Unknown exception"}];
      success = NO;
    }
    
    NSTimeInterval stepDuration = [[NSDate date] timeIntervalSinceDate:stepStart] * 1000;
    
    if (!success) {
      NSNumber *optional = step[@"optional"];
      
      [self emitEvent:@"step_complete" data:@{
        @"index": @(i),
        @"action": action,
        @"success": @NO,
        @"duration_ms": @(stepDuration),
        @"error": error.localizedDescription ?: @"Unknown error"
      }];
      
      if (optional && optional.boolValue) {
        continue;
      }
      
      NSTimeInterval totalDuration = [[NSDate date] timeIntervalSinceDate:startTime] * 1000;
      
      [self emitEvent:@"done" data:@{
        @"success": @NO,
        @"stoppedAt": @(i),
        @"error": error.localizedDescription ?: @"Unknown error",
        @"total_duration_ms": @(totalDuration)
      }];
      
      return @{
        @"success": @NO,
        @"results": self.results,
        @"variables": self.variables,
        @"stoppedAt": @(i),
        @"error": error.localizedDescription ?: @"Unknown error",
        @"failedAction": action
      };
    }
    
    [self emitEvent:@"step_complete" data:@{
      @"index": @(i),
      @"action": action,
      @"success": @YES,
      @"duration_ms": @(stepDuration)
    }];
  }
  
  NSTimeInterval totalDuration = [[NSDate date] timeIntervalSinceDate:startTime] * 1000;
  
  [self emitEvent:@"done" data:@{
    @"success": @YES,
    @"total_duration_ms": @(totalDuration)
  }];
  
  return @{
    @"success": @YES,
    @"results": self.results,
    @"variables": self.variables,
    @"stoppedAt": [NSNull null],
    @"error": [NSNull null]
  };
}

- (NSString *)interpolateString:(NSString *)str
{
  if (!str) return nil;
  
  NSMutableString *result = [str mutableCopy];
  
  // Replace ${varName} with variable values
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\$\\{([^}]+)\\}"
                                                                         options:0
                                                                           error:nil];
  
  NSArray *matches = [regex matchesInString:str options:0 range:NSMakeRange(0, str.length)];
  
  // Process in reverse to maintain correct indices
  for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
    NSRange varNameRange = [match rangeAtIndex:1];
    NSString *varName = [str substringWithRange:varNameRange];
    
    id value = self.variables[varName];
    if (!value) value = self.results[varName];
    
    NSString *replacement = @"";
    if ([value isKindOfClass:[NSString class]]) {
      replacement = value;
    } else if ([value isKindOfClass:[NSNumber class]]) {
      replacement = [value stringValue];
    }
    
    [result replaceCharactersInRange:match.range withString:replacement];
  }
  
  return result;
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
  
  // Element actions - single
  if ([action isEqualToString:@"click"] || [action isEqualToString:@"tap"]) return [self executeClick:step error:error];
  if ([action isEqualToString:@"wait"]) return [self executeWait:step error:error];
  if ([action isEqualToString:@"waitDisappear"]) return [self executeWaitDisappear:step error:error];
  if ([action isEqualToString:@"read"]) return [self executeRead:step error:error];
  if ([action isEqualToString:@"exists"]) return [self executeExists:step error:error];
  if ([action isEqualToString:@"getRect"]) return [self executeGetRect:step error:error];
  
  // Element actions - multiple
  if ([action isEqualToString:@"findElements"]) return [self executeFindElements:step error:error];
  if ([action isEqualToString:@"countElements"]) return [self executeCountElements:step error:error];
  if ([action isEqualToString:@"forEach"]) return [self executeForEach:step error:error];
  if ([action isEqualToString:@"clickNth"]) return [self executeClickNth:step error:error];
  if ([action isEqualToString:@"readNth"]) return [self executeReadNth:step error:error];
  
  // Alert handling
  if ([action isEqualToString:@"handleAlert"]) return [self executeHandleAlert:step error:error];
  if ([action isEqualToString:@"dismissAlert"]) return [self executeDismissAlert:step error:error];
  if ([action isEqualToString:@"acceptAlert"]) return [self executeAcceptAlert:step error:error];
  
  // Picker
  if ([action isEqualToString:@"setPicker"]) return [self executeSetPicker:step error:error];
  
  // Coordinates
  if ([action isEqualToString:@"tapXY"]) return [self executeTapXY:step error:error];
  if ([action isEqualToString:@"swipe"]) return [self executeSwipe:step error:error];
  if ([action isEqualToString:@"longPress"]) return [self executeLongPress:step error:error];
  if ([action isEqualToString:@"doubleTap"]) return [self executeDoubleTap:step error:error];
  if ([action isEqualToString:@"scroll"]) return [self executeScroll:step error:error];
  if ([action isEqualToString:@"pinch"]) return [self executePinch:step error:error];
  
  // Input
  if ([action isEqualToString:@"type"] || [action isEqualToString:@"typeText"]) return [self executeType:step error:error];
  if ([action isEqualToString:@"clear"]) return [self executeClear:step error:error];
  if ([action isEqualToString:@"pasteText"]) return [self executePasteText:step error:error];
  
  // Utility
  if ([action isEqualToString:@"sleep"]) return [self executeSleep:step error:error];
  if ([action isEqualToString:@"screenshot"]) return [self executeScreenshot:step error:error];
  if ([action isEqualToString:@"home"]) return [self executeHome:step error:error];
  if ([action isEqualToString:@"log"]) return [self executeLog:step error:error];
  if ([action isEqualToString:@"assert"]) return [self executeAssert:step error:error];
  
  // Variables
  if ([action isEqualToString:@"setVar"]) return [self executeSetVar:step error:error];
  if ([action isEqualToString:@"getVar"]) return [self executeGetVar:step error:error];
  if ([action isEqualToString:@"math"]) return [self executeMath:step error:error];
  if ([action isEqualToString:@"concat"]) return [self executeConcat:step error:error];
  if ([action isEqualToString:@"parseDate"]) return [self executeParseDate:step error:error];
  if ([action isEqualToString:@"formatDate"]) return [self executeFormatDate:step error:error];
  
  // Control flow
  if ([action isEqualToString:@"if"]) return [self executeIf:step error:error];
  if ([action isEqualToString:@"while"]) return [self executeWhile:step error:error];
  if ([action isEqualToString:@"repeat"]) return [self executeRepeat:step error:error];
  if ([action isEqualToString:@"break"]) return [self executeBreak:step error:error];
  if ([action isEqualToString:@"stop"]) return [self executeStop:step error:error];
  
#if !TARGET_OS_TV
  // Vision/OCR
  if ([action isEqualToString:@"clickText"] || [action isEqualToString:@"tapText"]) return [self executeClickText:step error:error];
  if ([action isEqualToString:@"waitText"]) return [self executeWaitText:step error:error];
  if ([action isEqualToString:@"readRegion"]) return [self executeReadRegion:step error:error];
  if ([action isEqualToString:@"readScreen"]) return [self executeReadScreen:step error:error];
  if ([action isEqualToString:@"clickImage"] || [action isEqualToString:@"tapImage"]) return [self executeClickImage:step error:error];
  if ([action isEqualToString:@"waitImage"]) return [self executeWaitImage:step error:error];
  if ([action isEqualToString:@"findText"]) return [self executeFindText:step error:error];
#endif
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:2
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown action: %@", action]}];
  return NO;
}

#pragma mark - App Lifecycle

- (BOOL)executeLaunch:(NSDictionary *)step error:(NSError **)error
{
  NSString *bundleId = [self interpolateString:step[@"bundleId"]];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 30.0;
  NSArray *args = step[@"arguments"];
  NSDictionary *env = step[@"environment"];
  BOOL wait = step[@"wait"] != nil ? [step[@"wait"] boolValue] : YES;
  
  if (!bundleId) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:3
                             userInfo:@{NSLocalizedDescriptionKey: @"'bundleId' required for launch"}];
    return NO;
  }
  
  [self log:@"debug" message:[NSString stringWithFormat:@"Launching app: %@", bundleId]];
  
  XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
  
  if (args) {
    app.launchArguments = args;
  }
  if (env) {
    app.launchEnvironment = env;
  }
  
  [app launch];
  self.currentApp = app;
  
  if (!wait) {
    return YES;
  }
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    if (app.state == XCUIApplicationStateRunningForeground) {
      [self log:@"debug" message:@"App launched successfully"];
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
  NSString *bundleId = [self interpolateString:step[@"bundleId"]];
  
  if (!bundleId) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:3
                             userInfo:@{NSLocalizedDescriptionKey: @"'bundleId' required for terminate"}];
    return NO;
  }
  
  XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
  [app terminate];
  
  [self log:@"debug" message:[NSString stringWithFormat:@"Terminated app: %@", bundleId]];
  return YES;
}

- (BOOL)executeActivate:(NSDictionary *)step error:(NSError **)error
{
  NSString *bundleId = [self interpolateString:step[@"bundleId"]];
  
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
  
  selector = [self interpolateString:selector];
  NSString *type = selectorType ?: @"accessibilityId";
  
  if ([type isEqualToString:@"accessibilityId"] || [type isEqualToString:@"id"]) {
    // Try common element types first
    XCUIElement *element = app.buttons[selector];
    if (element.exists) return element;
    
    element = app.staticTexts[selector];
    if (element.exists) return element;
    
    element = app.textFields[selector];
    if (element.exists) return element;
    
    element = app.textViews[selector];
    if (element.exists) return element;
    
    element = app.images[selector];
    if (element.exists) return element;
    
    element = app.cells[selector];
    if (element.exists) return element;
    
    element = app.switches[selector];
    if (element.exists) return element;
    
    element = app.sliders[selector];
    if (element.exists) return element;
    
    element = app.otherElements[selector];
    if (element.exists) return element;
    
    // Fallback to generic query
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"identifier == %@ OR label == %@", selector, selector];
    return [[app descendantsMatchingType:XCUIElementTypeAny] elementMatchingPredicate:predicate];
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
  
  if ([type isEqualToString:@"value"]) {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"value == %@", selector];
    return [[app descendantsMatchingType:XCUIElementTypeAny] elementMatchingPredicate:predicate];
  }
  
  if ([type isEqualToString:@"xpath"]) {
    // XPath not natively supported - use classChain instead
    return nil;
  }
  
  return nil;
}

- (NSArray<XCUIElement *> *)findElementsWithSelector:(NSString *)selector
                                        selectorType:(NSString *)selectorType
                                               inApp:(XCUIApplication *)app
                                            maxCount:(NSInteger)maxCount
{
  if (!selector) return @[];
  
  selector = [self interpolateString:selector];
  NSString *type = selectorType ?: @"accessibilityId";
  NSMutableArray<XCUIElement *> *results = [NSMutableArray array];
  
  XCUIElementQuery *query = nil;
  
  if ([type isEqualToString:@"classChain"]) {
    NSArray *elements = [app fb_descendantsMatchingClassChain:selector shouldReturnAfterFirstMatch:NO];
    for (id element in elements) {
      if (maxCount > 0 && results.count >= maxCount) break;
      [results addObject:element];
    }
    return results;
  }
  
  if ([type isEqualToString:@"predicate"]) {
    @try {
      NSPredicate *predicate = [NSPredicate predicateWithFormat:selector];
      query = [[app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:predicate];
    } @catch (NSException *exception) {
      return @[];
    }
  } else if ([type isEqualToString:@"accessibilityId"] || [type isEqualToString:@"id"]) {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"identifier == %@ OR label == %@", selector, selector];
    query = [[app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:predicate];
  } else if ([type isEqualToString:@"label"]) {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"label == %@", selector];
    query = [[app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:predicate];
  } else if ([type isEqualToString:@"labelContains"]) {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"label CONTAINS %@", selector];
    query = [[app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:predicate];
  }
  
  if (query) {
    NSInteger count = query.count;
    NSInteger limit = maxCount > 0 ? MIN(count, maxCount) : count;
    for (NSInteger i = 0; i < limit; i++) {
      XCUIElement *element = [query elementBoundByIndex:i];
      if (element.exists) {
        [results addObject:element];
      }
    }
  }
  
  return results;
}

#pragma mark - Element Actions - Single

- (BOOL)executeClick:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = [self interpolateString:step[@"selector"]];
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
  NSString *selector = [self interpolateString:step[@"selector"]];
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
  NSString *selector = [self interpolateString:step[@"selector"]];
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
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"];
  NSString *attribute = step[@"attribute"] ?: @"label";  // label, value, identifier
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
      NSString *value = nil;
      
      if ([attribute isEqualToString:@"label"]) {
        value = element.label;
      } else if ([attribute isEqualToString:@"value"]) {
        value = [element valueForKey:@"value"];
      } else if ([attribute isEqualToString:@"identifier"]) {
        value = element.identifier;
      } else if ([attribute isEqualToString:@"placeholderValue"]) {
        value = element.placeholderValue;
      }
      
      self.results[key] = value ?: @"";
      
      [self emitEvent:@"result" data:@{@"key": key, @"value": value ?: @""}];
      
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
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"] ?: @"exists";
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 0;  // Default no wait
  
  XCUIApplication *app = [self getTargetApp];
  BOOL found = NO;
  
  if (timeout > 0) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
      XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      if (element && element.exists) {
        found = YES;
        break;
      }
      [NSThread sleepForTimeInterval:0.1];
    }
  } else {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    found = (element && element.exists);
  }
  
  self.results[key] = found ? @"true" : @"false";
  self.variables[key] = @(found);
  
  return YES;
}

- (BOOL)executeGetRect:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"] ?: @"rect";
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for getRect"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (element && element.exists) {
      CGRect frame = element.frame;
      
      NSDictionary *rect = @{
        @"x": @(frame.origin.x),
        @"y": @(frame.origin.y),
        @"width": @(frame.size.width),
        @"height": @(frame.size.height),
        @"centerX": @(frame.origin.x + frame.size.width / 2),
        @"centerY": @(frame.origin.y + frame.size.height / 2)
      };
      
      self.results[key] = [self dictToString:rect];
      self.variables[key] = rect;
      self.variables[[NSString stringWithFormat:@"%@_x", key]] = @(frame.origin.x);
      self.variables[[NSString stringWithFormat:@"%@_y", key]] = @(frame.origin.y);
      self.variables[[NSString stringWithFormat:@"%@_width", key]] = @(frame.size.width);
      self.variables[[NSString stringWithFormat:@"%@_height", key]] = @(frame.size.height);
      self.variables[[NSString stringWithFormat:@"%@_centerX", key]] = @(frame.origin.x + frame.size.width / 2);
      self.variables[[NSString stringWithFormat:@"%@_centerY", key]] = @(frame.origin.y + frame.size.height / 2);
      
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:10
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for getRect", selector]}];
  return NO;
}

- (NSString *)dictToString:(NSDictionary *)dict
{
  NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

#pragma mark - Element Actions - Multiple

- (BOOL)executeFindElements:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"] ?: @"elements";
  NSInteger maxCount = [step[@"maxCount"] integerValue] ?: 100;
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for findElements"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSArray<XCUIElement *> *elements = nil;
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    elements = [self findElementsWithSelector:selector selectorType:selectorType inApp:app maxCount:maxCount];
    if (elements.count > 0) {
      break;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  // Store element info
  NSMutableArray *elementInfos = [NSMutableArray array];
  self.foundElements = [NSMutableArray array];
  
  for (XCUIElement *element in elements) {
    CGRect frame = element.frame;
    [elementInfos addObject:@{
      @"label": element.label ?: @"",
      @"identifier": element.identifier ?: @"",
      @"x": @(frame.origin.x),
      @"y": @(frame.origin.y),
      @"width": @(frame.size.width),
      @"height": @(frame.size.height),
      @"centerX": @(frame.origin.x + frame.size.width / 2),
      @"centerY": @(frame.origin.y + frame.size.height / 2)
    }];
    [self.foundElements addObject:@{
      @"element": element,
      @"frame": [NSValue valueWithCGRect:frame]
    }];
  }
  
  self.results[key] = [self dictToString:elementInfos];
  self.variables[key] = elementInfos;
  self.variables[[NSString stringWithFormat:@"%@_count", key]] = @(elementInfos.count);
  
  [self log:@"debug" message:[NSString stringWithFormat:@"Found %lu elements for '%@'", (unsigned long)elementInfos.count, selector]];
  
  return YES;
}

- (BOOL)executeCountElements:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"] ?: @"count";
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for countElements"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSArray<XCUIElement *> *elements = [self findElementsWithSelector:selector selectorType:selectorType inApp:app maxCount:0];
  
  self.results[key] = [NSString stringWithFormat:@"%lu", (unsigned long)elements.count];
  self.variables[key] = @(elements.count);
  
  return YES;
}

- (BOOL)executeForEach:(NSDictionary *)step error:(NSError **)error
{
  NSString *elementsKey = step[@"elements"] ?: @"elements";
  NSString *indexVar = step[@"indexVar"] ?: @"i";
  NSString *itemVar = step[@"itemVar"] ?: @"item";
  NSArray *doSteps = step[@"do"];
  NSInteger limit = [step[@"limit"] integerValue] ?: 0;
  
  if (!doSteps || ![doSteps isKindOfClass:[NSArray class]]) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:11
                             userInfo:@{NSLocalizedDescriptionKey: @"'do' steps array required for forEach"}];
    return NO;
  }
  
  NSArray *elements = self.variables[elementsKey];
  if (!elements || ![elements isKindOfClass:[NSArray class]]) {
    [self log:@"warning" message:[NSString stringWithFormat:@"No elements found for key '%@'", elementsKey]];
    return YES;  // Not an error, just no elements
  }
  
  NSInteger count = elements.count;
  if (limit > 0 && limit < count) {
    count = limit;
  }
  
  for (NSInteger i = 0; i < count; i++) {
    self.variables[indexVar] = @(i);
    self.variables[itemVar] = elements[i];
    
    // Also set individual properties
    NSDictionary *item = elements[i];
    if ([item isKindOfClass:[NSDictionary class]]) {
      for (NSString *itemKey in item) {
        self.variables[[NSString stringWithFormat:@"%@_%@", itemVar, itemKey]] = item[itemKey];
      }
    }
    
    @try {
      for (NSDictionary *subStep in doSteps) {
        if (![subStep isKindOfClass:[NSDictionary class]]) continue;
        
        NSError *subError = nil;
        BOOL success = [self executeStep:subStep error:&subError];
        
        if (!success) {
          NSNumber *optional = subStep[@"optional"];
          if (optional && optional.boolValue) {
            continue;
          }
          *error = subError;
          return NO;
        }
      }
    } @catch (NSException *exception) {
      if ([exception.name isEqualToString:@"FBScriptBreak"]) {
        break;
      }
      @throw exception;
    }
  }
  
  return YES;
}

- (BOOL)executeClickNth:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSInteger index = [step[@"index"] integerValue];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for clickNth"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    NSArray<XCUIElement *> *elements = [self findElementsWithSelector:selector selectorType:selectorType inApp:app maxCount:index + 1];
    if (elements.count > index) {
      XCUIElement *element = elements[index];
      if (element.exists && element.isHittable) {
        [element tap];
        return YES;
      }
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:12
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element at index %ld not found for '%@'", (long)index, selector]}];
  return NO;
}

- (BOOL)executeReadNth:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSInteger index = [step[@"index"] integerValue];
  NSString *key = step[@"as"];
  NSString *attribute = step[@"attribute"] ?: @"label";
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!selector || !key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' and 'as' required for readNth"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    NSArray<XCUIElement *> *elements = [self findElementsWithSelector:selector selectorType:selectorType inApp:app maxCount:index + 1];
    if (elements.count > index) {
      XCUIElement *element = elements[index];
      if (element.exists) {
        NSString *value = nil;
        if ([attribute isEqualToString:@"label"]) {
          value = element.label;
        } else if ([attribute isEqualToString:@"value"]) {
          value = [element valueForKey:@"value"];
        } else if ([attribute isEqualToString:@"identifier"]) {
          value = element.identifier;
        }
        
        self.results[key] = value ?: @"";
        return YES;
      }
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:13
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element at index %ld not found for '%@'", (long)index, selector]}];
  return NO;
}

#pragma mark - Alert Handling

- (BOOL)executeHandleAlert:(NSDictionary *)step error:(NSError **)error
{
  NSString *buttonName = [self interpolateString:step[@"button"]];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 3.0;
  
  if (!buttonName) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:14
                             userInfo:@{NSLocalizedDescriptionKey: @"'button' required for handleAlert"}];
    return NO;
  }
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    // Check springboard
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
    
    // Check app
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
  
  NSNumber *optional = step[@"optional"];
  if (optional && optional.boolValue) {
    return YES;
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:15
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Alert button '%@' not found", buttonName]}];
  return NO;
}

- (BOOL)executeDismissAlert:(NSDictionary *)step error:(NSError **)error
{
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 3.0;
  NSArray *dismissButtons = @[@"Cancel", @"No", @"Dismiss", @"Don't Allow", @"Not Now", @"Later", @"Close"];
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElementQuery *alerts = self.springboard.alerts;
    if (alerts.count > 0) {
      XCUIElement *alert = [alerts elementBoundByIndex:0];
      for (NSString *buttonName in dismissButtons) {
        XCUIElement *btn = alert.buttons[buttonName];
        if (btn.exists && btn.isHittable) {
          [btn tap];
          return YES;
        }
      }
    }
    
    XCUIApplication *app = [self getTargetApp];
    if (app) {
      alerts = app.alerts;
      if (alerts.count > 0) {
        XCUIElement *alert = [alerts elementBoundByIndex:0];
        for (NSString *buttonName in dismissButtons) {
          XCUIElement *btn = alert.buttons[buttonName];
          if (btn.exists && btn.isHittable) {
            [btn tap];
            return YES;
          }
        }
      }
    }
    
    [NSThread sleepForTimeInterval:0.1];
  }
  
  return YES;  // No alert to dismiss
}

- (BOOL)executeAcceptAlert:(NSDictionary *)step error:(NSError **)error
{
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 3.0;
  NSArray *acceptButtons = @[@"OK", @"Allow", @"Yes", @"Accept", @"Continue", @"Allow Full Access", @"Allow While Using App"];
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElementQuery *alerts = self.springboard.alerts;
    if (alerts.count > 0) {
      XCUIElement *alert = [alerts elementBoundByIndex:0];
      for (NSString *buttonName in acceptButtons) {
        XCUIElement *btn = alert.buttons[buttonName];
        if (btn.exists && btn.isHittable) {
          [btn tap];
          return YES;
        }
      }
    }
    
    XCUIApplication *app = [self getTargetApp];
    if (app) {
      alerts = app.alerts;
      if (alerts.count > 0) {
        XCUIElement *alert = [alerts elementBoundByIndex:0];
        for (NSString *buttonName in acceptButtons) {
          XCUIElement *btn = alert.buttons[buttonName];
          if (btn.exists && btn.isHittable) {
            [btn tap];
            return YES;
          }
        }
      }
    }
    
    [NSThread sleepForTimeInterval:0.1];
  }
  
  return YES;
}

#pragma mark - Picker Actions

- (BOOL)executeSetPicker:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *index = step[@"index"];
  NSString *value = [self interpolateString:step[@"value"]];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (index == nil) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:16
                             userInfo:@{NSLocalizedDescriptionKey: @"'index' required for setPicker"}];
    return NO;
  }
  
  if (!value) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:17
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
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:18
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Picker at index %@ not found", index]}];
  return NO;
}

#pragma mark - Coordinate Actions

- (BOOL)executeTapXY:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *xNum = step[@"x"];
  NSNumber *yNum = step[@"y"];
  
  // Support variable interpolation for coordinates
  CGFloat x = 0, y = 0;
  
  if (xNum) {
    x = xNum.doubleValue;
  } else if (step[@"xVar"]) {
    NSNumber *varValue = self.variables[[self interpolateString:step[@"xVar"]]];
    x = varValue.doubleValue;
  }
  
  if (yNum) {
    y = yNum.doubleValue;
  } else if (step[@"yVar"]) {
    NSNumber *varValue = self.variables[[self interpolateString:step[@"yVar"]]];
    y = varValue.doubleValue;
  }
  
  if (x == 0 && y == 0 && !xNum && !yNum) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:19
                             userInfo:@{NSLocalizedDescriptionKey: @"'x' and 'y' (or 'xVar' and 'yVar') required for tapXY"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                           coordinateWithOffset:CGVectorMake(x, y)];
  [coord tap];
  return YES;
}

- (BOOL)executeSwipe:(NSDictionary *)step error:(NSError **)error
{
  CGFloat x = [step[@"x"] doubleValue];
  CGFloat y = [step[@"y"] doubleValue];
  CGFloat toX = [step[@"toX"] doubleValue];
  CGFloat toY = [step[@"toY"] doubleValue];
  NSTimeInterval duration = [step[@"duration"] doubleValue] ?: 0.3;
  
  XCUIApplication *app = [self getTargetApp];
  XCUICoordinate *start = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                           coordinateWithOffset:CGVectorMake(x, y)];
  XCUICoordinate *end = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                         coordinateWithOffset:CGVectorMake(toX, toY)];
  
  [start pressForDuration:duration thenDragToCoordinate:end];
  return YES;
}

- (BOOL)executeLongPress:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval duration = [step[@"duration"] doubleValue] ?: 1.0;
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  // Can use coordinates or selector
  if (step[@"x"] && step[@"y"]) {
    CGFloat x = [step[@"x"] doubleValue];
    CGFloat y = [step[@"y"] doubleValue];
    
    XCUIApplication *app = [self getTargetApp];
    XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                             coordinateWithOffset:CGVectorMake(x, y)];
    [coord pressForDuration:duration];
    return YES;
  }
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:20
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' or 'x'/'y' required for longPress"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (element && element.exists && element.isHittable) {
      [element pressForDuration:duration];
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:21
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for longPress", selector]}];
  return NO;
}

- (BOOL)executeDoubleTap:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (step[@"x"] && step[@"y"]) {
    CGFloat x = [step[@"x"] doubleValue];
    CGFloat y = [step[@"y"] doubleValue];
    
    XCUIApplication *app = [self getTargetApp];
    XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                             coordinateWithOffset:CGVectorMake(x, y)];
    [coord doubleTap];
    return YES;
  }
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:22
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' or 'x'/'y' required for doubleTap"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (element && element.exists && element.isHittable) {
      [element doubleTap];
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:23
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for doubleTap", selector]}];
  return NO;
}

- (BOOL)executeScroll:(NSDictionary *)step error:(NSError **)error
{
  NSString *direction = step[@"direction"] ?: @"down";
  CGFloat distance = [step[@"distance"] doubleValue] ?: 200;
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  
  XCUIApplication *app = [self getTargetApp];
  
  // Get element or use screen center
  CGRect bounds;
  if (selector) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (!element || !element.exists) {
      *error = [NSError errorWithDomain:@"FBScriptExecutor" code:24
                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for scroll", selector]}];
      return NO;
    }
    bounds = element.frame;
  } else {
    bounds = app.frame;
  }
  
  CGFloat centerX = bounds.origin.x + bounds.size.width / 2;
  CGFloat centerY = bounds.origin.y + bounds.size.height / 2;
  
  CGFloat toX = centerX, toY = centerY;
  
  if ([direction isEqualToString:@"down"]) {
    toY = centerY - distance;
  } else if ([direction isEqualToString:@"up"]) {
    toY = centerY + distance;
  } else if ([direction isEqualToString:@"left"]) {
    toX = centerX + distance;
  } else if ([direction isEqualToString:@"right"]) {
    toX = centerX - distance;
  }
  
  XCUICoordinate *start = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                           coordinateWithOffset:CGVectorMake(centerX, centerY)];
  XCUICoordinate *end = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                         coordinateWithOffset:CGVectorMake(toX, toY)];
  
  [start pressForDuration:0.1 thenDragToCoordinate:end];
  return YES;
}

- (BOOL)executePinch:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  CGFloat scale = [step[@"scale"] doubleValue] ?: 1.0;
  CGFloat velocity = [step[@"velocity"] doubleValue] ?: 1.0;
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  XCUIApplication *app = [self getTargetApp];
  XCUIElement *element = nil;
  
  if (selector) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
      element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      if (element && element.exists) break;
      [NSThread sleepForTimeInterval:0.1];
    }
  } else {
    element = app;
  }
  
  if (!element) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:25
                             userInfo:@{NSLocalizedDescriptionKey: @"Element not found for pinch"}];
    return NO;
  }
  
  [element pinchWithScale:scale velocity:velocity];
  return YES;
}

#pragma mark - Input Actions

- (BOOL)executeType:(NSDictionary *)step error:(NSError **)error
{
  NSString *text = [self interpolateString:step[@"value"] ?: step[@"text"]];
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!text) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:26
                             userInfo:@{NSLocalizedDescriptionKey: @"'value' or 'text' required for type action"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  
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
      *error = [NSError errorWithDomain:@"FBScriptExecutor" code:27
                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for typing", selector]}];
      return NO;
    }
  }
  
  [app typeText:text];
  return YES;
}

- (BOOL)executeClear:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = [self interpolateString:step[@"selector"]];
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
      if ([selectAll waitForExistenceWithTimeout:1.0]) {
        [selectAll tap];
        [app typeText:XCUIKeyboardKeyDelete];
      }
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:28
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for clearing", selector]}];
  return NO;
}

- (BOOL)executePasteText:(NSDictionary *)step error:(NSError **)error
{
  NSString *text = [self interpolateString:step[@"text"]];
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!text) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:29
                             userInfo:@{NSLocalizedDescriptionKey: @"'text' required for pasteText"}];
    return NO;
  }
  
  // Set pasteboard
  [[UIPasteboard generalPasteboard] setString:text];
  
  XCUIApplication *app = [self getTargetApp];
  
  if (selector) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
      XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      if (element && element.exists) {
        [element tap];
        [element pressForDuration:1.0];
        
        XCUIElement *paste = app.menuItems[@"Paste"];
        if ([paste waitForExistenceWithTimeout:2.0]) {
          [paste tap];
          return YES;
        }
        break;
      }
      [NSThread sleepForTimeInterval:0.1];
    }
  }
  
  return YES;
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
  BOOL includeInResults = step[@"includeInResults"] != nil ? [step[@"includeInResults"] boolValue] : NO;
  
  XCUIScreenshot *screenshot = XCUIScreen.mainScreen.screenshot;
  NSData *pngData = screenshot.PNGRepresentation;
  NSString *base64 = [pngData base64EncodedStringWithOptions:0];
  
  if (includeInResults) {
    self.results[key] = base64;
  }
  
  [self emitEvent:@"screenshot" data:@{@"key": key, @"size": @(pngData.length)}];
  
  // Store in variables for potential use
  self.variables[key] = base64;
  
  return YES;
}

- (BOOL)executeHome:(NSDictionary *)step error:(NSError **)error
{
  [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
  return YES;
}

- (BOOL)executeLog:(NSDictionary *)step error:(NSError **)error
{
  NSString *level = step[@"level"] ?: @"info";
  NSString *message = [self interpolateString:step[@"message"]];
  
  [self log:level message:message ?: @""];
  return YES;
}

- (BOOL)executeAssert:(NSDictionary *)step error:(NSError **)error
{
  NSString *condition = step[@"condition"];
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"key"];
  NSString *value = [self interpolateString:step[@"value"]];
  NSString *message = [self interpolateString:step[@"message"]] ?: @"Assertion failed";
  
  BOOL passed = NO;
  
  if ([condition isEqualToString:@"exists"]) {
    XCUIApplication *app = [self getTargetApp];
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    passed = (element && element.exists);
  } else if ([condition isEqualToString:@"notExists"]) {
    XCUIApplication *app = [self getTargetApp];
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    passed = (!element || !element.exists);
  } else if ([condition isEqualToString:@"equals"]) {
    NSString *storedValue = self.results[key] ?: [self.variables[key] description];
    passed = [storedValue isEqualToString:value];
  } else if ([condition isEqualToString:@"contains"]) {
    NSString *storedValue = self.results[key] ?: [self.variables[key] description];
    passed = storedValue && [storedValue containsString:value];
  } else if ([condition isEqualToString:@"greaterThan"]) {
    NSNumber *storedValue = self.variables[key];
    passed = storedValue && storedValue.doubleValue > value.doubleValue;
  } else if ([condition isEqualToString:@"lessThan"]) {
    NSNumber *storedValue = self.variables[key];
    passed = storedValue && storedValue.doubleValue < value.doubleValue;
  } else if ([condition isEqualToString:@"true"]) {
    NSNumber *storedValue = self.variables[key];
    passed = storedValue && storedValue.boolValue;
  } else if ([condition isEqualToString:@"false"]) {
    NSNumber *storedValue = self.variables[key];
    passed = storedValue && !storedValue.boolValue;
  }
  
  if (!passed) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:30
                             userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
  }
  
  return YES;
}

#pragma mark - Variable Actions

- (BOOL)executeSetVar:(NSDictionary *)step error:(NSError **)error
{
  NSString *key = step[@"key"];
  id value = step[@"value"];
  
  if (!key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:31
                             userInfo:@{NSLocalizedDescriptionKey: @"'key' required for setVar"}];
    return NO;
  }
  
  if ([value isKindOfClass:[NSString class]]) {
    value = [self interpolateString:value];
  }
  
  self.variables[key] = value;
  
  // Also store string representation in results
  if ([value isKindOfClass:[NSString class]]) {
    self.results[key] = value;
  } else if ([value isKindOfClass:[NSNumber class]]) {
    self.results[key] = [value stringValue];
  }
  
  return YES;
}

- (BOOL)executeGetVar:(NSDictionary *)step error:(NSError **)error
{
  NSString *key = step[@"key"];
  NSString *as = step[@"as"];
  
  if (!key || !as) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:32
                             userInfo:@{NSLocalizedDescriptionKey: @"'key' and 'as' required for getVar"}];
    return NO;
  }
  
  id value = self.variables[key];
  if (!value) {
    value = self.results[key];
  }
  
  self.variables[as] = value;
  if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
    self.results[as] = [value description];
  }
  
  return YES;
}

- (BOOL)executeMath:(NSDictionary *)step error:(NSError **)error
{
  NSString *operation = step[@"operation"];
  NSString *key = step[@"as"];
  
  if (!operation || !key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:33
                             userInfo:@{NSLocalizedDescriptionKey: @"'operation' and 'as' required for math"}];
    return NO;
  }
  
  // Get operands - support both direct values and variable references
  double a = 0, b = 0;
  
  if (step[@"a"]) {
    a = [step[@"a"] doubleValue];
  } else if (step[@"aVar"]) {
    a = [self.variables[[self interpolateString:step[@"aVar"]]] doubleValue];
  }
  
  if (step[@"b"]) {
    b = [step[@"b"] doubleValue];
  } else if (step[@"bVar"]) {
    b = [self.variables[[self interpolateString:step[@"bVar"]]] doubleValue];
  }
  
  double result = 0;
  
  if ([operation isEqualToString:@"add"] || [operation isEqualToString:@"+"]) {
    result = a + b;
  } else if ([operation isEqualToString:@"subtract"] || [operation isEqualToString:@"-"]) {
    result = a - b;
  } else if ([operation isEqualToString:@"multiply"] || [operation isEqualToString:@"*"]) {
    result = a * b;
  } else if ([operation isEqualToString:@"divide"] || [operation isEqualToString:@"/"]) {
    if (b == 0) {
      *error = [NSError errorWithDomain:@"FBScriptExecutor" code:34
                               userInfo:@{NSLocalizedDescriptionKey: @"Division by zero"}];
      return NO;
    }
    result = a / b;
  } else if ([operation isEqualToString:@"mod"] || [operation isEqualToString:@"%"]) {
    result = fmod(a, b);
  } else if ([operation isEqualToString:@"min"]) {
    result = MIN(a, b);
  } else if ([operation isEqualToString:@"max"]) {
    result = MAX(a, b);
  } else if ([operation isEqualToString:@"round"]) {
    result = round(a);
  } else if ([operation isEqualToString:@"floor"]) {
    result = floor(a);
  } else if ([operation isEqualToString:@"ceil"]) {
    result = ceil(a);
  } else if ([operation isEqualToString:@"abs"]) {
    result = fabs(a);
  }
  
  self.variables[key] = @(result);
  self.results[key] = [NSString stringWithFormat:@"%g", result];
  
  return YES;
}

- (BOOL)executeConcat:(NSDictionary *)step error:(NSError **)error
{
  NSArray *values = step[@"values"];
  NSString *separator = step[@"separator"] ?: @"";
  NSString *key = step[@"as"];
  
  if (!values || !key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:35
                             userInfo:@{NSLocalizedDescriptionKey: @"'values' and 'as' required for concat"}];
    return NO;
  }
  
  NSMutableArray *strings = [NSMutableArray array];
  for (id value in values) {
    if ([value isKindOfClass:[NSString class]]) {
      [strings addObject:[self interpolateString:value]];
    } else {
      [strings addObject:[value description]];
    }
  }
  
  NSString *result = [strings componentsJoinedByString:separator];
  self.variables[key] = result;
  self.results[key] = result;
  
  return YES;
}

- (BOOL)executeParseDate:(NSDictionary *)step error:(NSError **)error
{
  NSString *dateString = [self interpolateString:step[@"value"]];
  NSString *format = step[@"format"];
  NSString *key = step[@"as"];
  
  if (!dateString || !key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:36
                             userInfo:@{NSLocalizedDescriptionKey: @"'value' and 'as' required for parseDate"}];
    return NO;
  }
  
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  
  // Try multiple formats
  NSArray *formats = format ? @[format] : @[
    @"M/d/yyyy h:mm a",
    @"MM/dd h:mm a",
    @"h:mm a",
    @"yyyy-MM-dd HH:mm:ss",
    @"yyyy-MM-dd",
    @"MMM dd, yyyy",
    @"MMM d"
  ];
  
  NSDate *date = nil;
  for (NSString *fmt in formats) {
    formatter.dateFormat = fmt;
    date = [formatter dateFromString:dateString];
    if (date) break;
  }
  
  if (date) {
    NSTimeInterval timestamp = [date timeIntervalSince1970];
    self.variables[key] = @(timestamp);
    self.variables[[NSString stringWithFormat:@"%@_year", key]] = @([[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:date]);
    self.variables[[NSString stringWithFormat:@"%@_month", key]] = @([[NSCalendar currentCalendar] component:NSCalendarUnitMonth fromDate:date]);
    self.variables[[NSString stringWithFormat:@"%@_day", key]] = @([[NSCalendar currentCalendar] component:NSCalendarUnitDay fromDate:date]);
    self.variables[[NSString stringWithFormat:@"%@_hour", key]] = @([[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:date]);
    self.variables[[NSString stringWithFormat:@"%@_minute", key]] = @([[NSCalendar currentCalendar] component:NSCalendarUnitMinute fromDate:date]);
    self.results[key] = [NSString stringWithFormat:@"%.0f", timestamp];
  } else {
    self.variables[key] = @(0);
    self.results[key] = @"0";
  }
  
  return YES;
}

- (BOOL)executeFormatDate:(NSDictionary *)step error:(NSError **)error
{
  NSString *format = step[@"format"];
  NSString *key = step[@"as"];
  NSNumber *timestamp = step[@"timestamp"];
  NSString *timestampVar = step[@"timestampVar"];
  
  if (!format || !key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:37
                             userInfo:@{NSLocalizedDescriptionKey: @"'format' and 'as' required for formatDate"}];
    return NO;
  }
  
  NSDate *date;
  if (timestamp) {
    date = [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue];
  } else if (timestampVar) {
    NSNumber *ts = self.variables[[self interpolateString:timestampVar]];
    date = [NSDate dateWithTimeIntervalSince1970:ts.doubleValue];
  } else {
    date = [NSDate date];  // Current date
  }
  
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.dateFormat = format;
  
  NSString *result = [formatter stringFromDate:date];
  self.variables[key] = result;
  self.results[key] = result;
  
  return YES;
}

#pragma mark - Control Flow

- (BOOL)executeIf:(NSDictionary *)step error:(NSError **)error
{
  NSString *condition = step[@"condition"];
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSString *text = [self interpolateString:step[@"text"]];
  NSString *key = step[@"key"];
  NSString *value = [self interpolateString:step[@"value"]];
  NSArray *thenSteps = step[@"then"];
  NSArray *elseSteps = step[@"else"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 2.0;
  
  if (!condition) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:38
                             userInfo:@{NSLocalizedDescriptionKey: @"'condition' required for if action"}];
    return NO;
  }
  
  BOOL conditionMet = NO;
  XCUIApplication *app = [self getTargetApp];
  
  if ([condition isEqualToString:@"exists"]) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    conditionMet = (element && element.exists);
    
  } else if ([condition isEqualToString:@"notExists"]) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    conditionMet = (!element || !element.exists);
    
  } else if ([condition isEqualToString:@"visible"]) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    conditionMet = (element && element.exists && element.isHittable);
    
  } else if ([condition isEqualToString:@"waitExists"]) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
      XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      if (element && element.exists) {
        conditionMet = YES;
        break;
      }
      [NSThread sleepForTimeInterval:0.1];
    }
    
#if !TARGET_OS_TV
  } else if ([condition isEqualToString:@"textVisible"]) {
    UIImage *screenshot = [self captureScreenshot];
    CGPoint point = [self findTextInImage:screenshot text:text];
    conditionMet = !CGPointEqualToPoint(point, CGPointZero);
    
  } else if ([condition isEqualToString:@"textNotVisible"]) {
    UIImage *screenshot = [self captureScreenshot];
    CGPoint point = [self findTextInImage:screenshot text:text];
    conditionMet = CGPointEqualToPoint(point, CGPointZero);
#endif
    
  } else if ([condition isEqualToString:@"equals"]) {
    NSString *storedValue = self.results[key] ?: [self.variables[key] description];
    conditionMet = [storedValue isEqualToString:value];
    
  } else if ([condition isEqualToString:@"notEquals"]) {
    NSString *storedValue = self.results[key] ?: [self.variables[key] description];
    conditionMet = ![storedValue isEqualToString:value];
    
  } else if ([condition isEqualToString:@"contains"]) {
    NSString *storedValue = self.results[key] ?: [self.variables[key] description];
    conditionMet = storedValue && [storedValue containsString:value];
    
  } else if ([condition isEqualToString:@"greaterThan"]) {
    NSNumber *storedValue = self.variables[key];
    conditionMet = storedValue && storedValue.doubleValue > value.doubleValue;
    
  } else if ([condition isEqualToString:@"lessThan"]) {
    NSNumber *storedValue = self.variables[key];
    conditionMet = storedValue && storedValue.doubleValue < value.doubleValue;
    
  } else if ([condition isEqualToString:@"true"]) {
    id storedValue = self.variables[key];
    if ([storedValue isKindOfClass:[NSNumber class]]) {
      conditionMet = [storedValue boolValue];
    } else if ([storedValue isKindOfClass:[NSString class]]) {
      conditionMet = [storedValue isEqualToString:@"true"];
    }
    
  } else if ([condition isEqualToString:@"false"]) {
    id storedValue = self.variables[key];
    if ([storedValue isKindOfClass:[NSNumber class]]) {
      conditionMet = ![storedValue boolValue];
    } else if ([storedValue isKindOfClass:[NSString class]]) {
      conditionMet = [storedValue isEqualToString:@"false"];
    }
    
  } else {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:39
                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown condition: %@", condition]}];
    return NO;
  }
  
  NSArray *stepsToExecute = conditionMet ? thenSteps : elseSteps;
  
  if (stepsToExecute && [stepsToExecute isKindOfClass:[NSArray class]] && stepsToExecute.count > 0) {
    for (NSDictionary *subStep in stepsToExecute) {
      if (![subStep isKindOfClass:[NSDictionary class]]) continue;
      
      NSError *subError = nil;
      BOOL success = [self executeStep:subStep error:&subError];
      
      if (!success) {
        NSNumber *optional = subStep[@"optional"];
        if (optional && optional.boolValue) {
          continue;
        }
        *error = subError;
        return NO;
      }
    }
  }
  
  return YES;
}

- (BOOL)executeWhile:(NSDictionary *)step error:(NSError **)error
{
  NSString *condition = step[@"condition"];
  NSString *selector = [self interpolateString:step[@"selector"]];
  NSString *selectorType = step[@"selectorType"];
  NSArray *doSteps = step[@"do"];
  NSInteger maxIterations = [step[@"maxIterations"] integerValue] ?: 100;
  NSTimeInterval interval = [step[@"interval"] doubleValue] ?: 0.5;
  
  if (!condition) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:40
                             userInfo:@{NSLocalizedDescriptionKey: @"'condition' required for while action"}];
    return NO;
  }
  
  if (!doSteps || ![doSteps isKindOfClass:[NSArray class]]) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:41
                             userInfo:@{NSLocalizedDescriptionKey: @"'do' steps array required for while action"}];
    return NO;
  }
  
  NSInteger iterations = 0;
  
  while (iterations < maxIterations) {
    iterations++;
    self.variables[@"_iteration"] = @(iterations - 1);
    
    BOOL conditionMet = NO;
    XCUIApplication *app = [self getTargetApp];
    
    if ([condition isEqualToString:@"exists"]) {
      XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      conditionMet = (element && element.exists);
    } else if ([condition isEqualToString:@"notExists"]) {
      XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      conditionMet = (!element || !element.exists);
    } else if ([condition isEqualToString:@"visible"]) {
      XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      conditionMet = (element && element.exists && element.isHittable);
    } else if ([condition isEqualToString:@"true"]) {
      NSString *key = step[@"key"];
      id storedValue = self.variables[key];
      if ([storedValue isKindOfClass:[NSNumber class]]) {
        conditionMet = [storedValue boolValue];
      }
    }
    
    if (!conditionMet) {
      break;
    }
    
    @try {
      for (NSDictionary *subStep in doSteps) {
        if (![subStep isKindOfClass:[NSDictionary class]]) continue;
        
        NSError *subError = nil;
        BOOL success = [self executeStep:subStep error:&subError];
        
        if (!success) {
          NSNumber *optional = subStep[@"optional"];
          if (optional && optional.boolValue) {
            continue;
          }
          *error = subError;
          return NO;
        }
      }
    } @catch (NSException *exception) {
      if ([exception.name isEqualToString:@"FBScriptBreak"]) {
        break;
      }
      @throw exception;
    }
    
    [NSThread sleepForTimeInterval:interval];
  }
  
  return YES;
}

- (BOOL)executeRepeat:(NSDictionary *)step error:(NSError **)error
{
  NSInteger times = [step[@"times"] integerValue];
  NSArray *doSteps = step[@"do"];
  
  if (times < 1) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:42
                             userInfo:@{NSLocalizedDescriptionKey: @"'times' must be at least 1 for repeat"}];
    return NO;
  }
  
  if (!doSteps || ![doSteps isKindOfClass:[NSArray class]]) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:43
                             userInfo:@{NSLocalizedDescriptionKey: @"'do' steps array required for repeat action"}];
    return NO;
  }
  
  for (NSInteger i = 0; i < times; i++) {
    self.variables[@"_iteration"] = @(i);
    
    @try {
      for (NSDictionary *subStep in doSteps) {
        if (![subStep isKindOfClass:[NSDictionary class]]) continue;
        
        NSError *subError = nil;
        BOOL success = [self executeStep:subStep error:&subError];
        
        if (!success) {
          NSNumber *optional = subStep[@"optional"];
          if (optional && optional.boolValue) {
            continue;
          }
          *error = subError;
          return NO;
        }
      }
    } @catch (NSException *exception) {
      if ([exception.name isEqualToString:@"FBScriptBreak"]) {
        break;
      }
      @throw exception;
    }
  }
  
  return YES;
}

- (BOOL)executeBreak:(NSDictionary *)step error:(NSError **)error
{
  @throw [NSException exceptionWithName:@"FBScriptBreak" reason:@"break" userInfo:nil];
}

- (BOOL)executeStop:(NSDictionary *)step error:(NSError **)error
{
  self.shouldStop = YES;
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
  NSString *searchText = [self interpolateString:step[@"text"]];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!searchText) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:44
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
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:45
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Text '%@' not found on screen", searchText]}];
  return NO;
}

- (BOOL)executeWaitText:(NSDictionary *)step error:(NSError **)error
{
  NSString *searchText = [self interpolateString:step[@"text"]];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!searchText) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:44
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
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:46
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Text '%@' not found within timeout", searchText]}];
  return NO;
}

- (BOOL)executeFindText:(NSDictionary *)step error:(NSError **)error
{
  NSString *searchText = [self interpolateString:step[@"text"]];
  NSString *key = step[@"as"] ?: @"textLocation";
  
  if (!searchText) {
        *error = [NSError errorWithDomain:@"FBScriptExecutor" code:44
                             userInfo:@{NSLocalizedDescriptionKey: @"'text' required for findText"}];
    return NO;
  }
  
  UIImage *screenshot = [self captureScreenshot];
  CGPoint point = [self findTextInImage:screenshot text:searchText];
  
  if (!CGPointEqualToPoint(point, CGPointZero)) {
    self.variables[key] = @{@"x": @(point.x), @"y": @(point.y), @"found": @YES};
    self.variables[[NSString stringWithFormat:@"%@_x", key]] = @(point.x);
    self.variables[[NSString stringWithFormat:@"%@_y", key]] = @(point.y);
    self.variables[[NSString stringWithFormat:@"%@_found", key]] = @YES;
    self.results[key] = [NSString stringWithFormat:@"%.0f,%.0f", point.x, point.y];
  } else {
    self.variables[key] = @{@"x": @0, @"y": @0, @"found": @NO};
    self.variables[[NSString stringWithFormat:@"%@_found", key]] = @NO;
    self.results[key] = @"not_found";
  }
  
  return YES;
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
  self.variables[key] = recognizedText ?: @"";
  
  [self emitEvent:@"result" data:@{@"key": key, @"value": recognizedText ?: @""}];
  
  return YES;
}

- (BOOL)executeReadScreen:(NSDictionary *)step error:(NSError **)error
{
  NSString *key = step[@"as"] ?: @"screenText";
  
  UIImage *screenshot = [self captureScreenshot];
  NSString *recognizedText = [self recognizeTextInImage:screenshot];
  
  self.results[key] = recognizedText ?: @"";
  self.variables[key] = recognizedText ?: @"";
  
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
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:47
                             userInfo:@{NSLocalizedDescriptionKey: @"'imageBase64' required for clickImage"}];
    return NO;
  }
  
  NSData *templateData = [[NSData alloc] initWithBase64EncodedString:imageBase64 options:0];
  UIImage *templateImage = [UIImage imageWithData:templateData];
  
  if (!templateImage) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:48
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
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:49
                           userInfo:@{NSLocalizedDescriptionKey: @"Template image not found on screen"}];
  return NO;
}

- (BOOL)executeWaitImage:(NSDictionary *)step error:(NSError **)error
{
  NSString *imageBase64 = step[@"imageBase64"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  CGFloat confidence = [step[@"confidence"] doubleValue] ?: 0.8;
  NSString *key = step[@"as"];
  
  if (!imageBase64) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:47
                             userInfo:@{NSLocalizedDescriptionKey: @"'imageBase64' required for waitImage"}];
    return NO;
  }
  
  NSData *templateData = [[NSData alloc] initWithBase64EncodedString:imageBase64 options:0];
  UIImage *templateImage = [UIImage imageWithData:templateData];
  
  if (!templateImage) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:48
                             userInfo:@{NSLocalizedDescriptionKey: @"Cannot decode template image from base64"}];
    return NO;
  }
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    UIImage *screenshot = [self captureScreenshot];
    CGPoint point = [self findTemplateInImage:screenshot template:templateImage confidence:confidence];
    
    if (!CGPointEqualToPoint(point, CGPointZero)) {
      if (key) {
        self.variables[key] = @{@"x": @(point.x), @"y": @(point.y)};
        self.variables[[NSString stringWithFormat:@"%@_x", key]] = @(point.x);
        self.variables[[NSString stringWithFormat:@"%@_y", key]] = @(point.y);
      }
      return YES;
    }
    
    [NSThread sleepForTimeInterval:0.2];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:50
                           userInfo:@{NSLocalizedDescriptionKey: @"Template image not found within timeout"}];
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

#pragma mark - HTTP Streaming Writer

@interface FBHTTPStreamWriter : NSObject <FBStreamWriter>

@property (nonatomic, strong) NSOutputStream *outputStream;
@property (nonatomic, assign) BOOL isClosed;

- (instancetype)initWithOutputStream:(NSOutputStream *)stream;

@end

@implementation FBHTTPStreamWriter

- (instancetype)initWithOutputStream:(NSOutputStream *)stream
{
  self = [super init];
  if (self) {
    _outputStream = stream;
    _isClosed = NO;
  }
  return self;
}

- (void)writeEvent:(NSDictionary *)event
{
  if (self.isClosed) return;
  
  NSError *error = nil;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:event options:0 error:&error];
  if (error || !jsonData) return;
  
  // Format as Server-Sent Events
  NSMutableData *sseData = [NSMutableData data];
  [sseData appendData:[@"data: " dataUsingEncoding:NSUTF8StringEncoding]];
  [sseData appendData:jsonData];
  [sseData appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
  
  [self.outputStream write:sseData.bytes maxLength:sseData.length];
}

- (void)close
{
  self.isClosed = YES;
}

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
    // Script execution endpoints
    [[FBRoute POST:@"/wda/script"] respondWithTarget:self action:@selector(handleScript:)],
    [[FBRoute POST:@"/wda/script"].withoutSession respondWithTarget:self action:@selector(handleScript:)],
    [[FBRoute POST:@"/wda/script/stream"] respondWithTarget:self action:@selector(handleScriptStream:)],
    [[FBRoute POST:@"/wda/script/stream"].withoutSession respondWithTarget:self action:@selector(handleScriptStream:)],
#endif
    [[FBRoute OPTIONS:@"/*"].withoutSession respondWithTarget:self action:@selector(handlePingCommand:)],
  ];
}

#pragma mark - Script Execution

+ (id<FBResponsePayload>)handleScript:(FBRouteRequest *)request
{
  NSArray *stepsArray = request.arguments[@"steps"];
  NSDictionary *initialVars = request.arguments[@"variables"];
  
  if (!stepsArray || ![stepsArray isKindOfClass:[NSArray class]]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'steps' array is required"
                                                                       traceback:nil]);
  }
  
  if (stepsArray.count == 0) {
    return FBResponseWithObject(@{
      @"success": @YES,
      @"results": @{},
      @"variables": @{},
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
  
  // Set initial variables if provided
  if (initialVars && [initialVars isKindOfClass:[NSDictionary class]]) {
    [executor.variables addEntriesFromDictionary:initialVars];
  }
  
  NSDictionary *result = [executor executeSteps:stepsArray];
  
  return FBResponseWithObject(result);
}

+ (id<FBResponsePayload>)handleScriptStream:(FBRouteRequest *)request
{
  // Note: This is a simplified streaming implementation
  // In practice, WDA's HTTP server may need modifications to support true SSE
  // For now, we'll return regular response but with streaming-like behavior
  
  NSArray *stepsArray = request.arguments[@"steps"];
  NSDictionary *initialVars = request.arguments[@"variables"];
  
  if (!stepsArray || ![stepsArray isKindOfClass:[NSArray class]]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'steps' array is required"
                                                                       traceback:nil]);
  }
  
  FBScriptExecutor *executor = [[FBScriptExecutor alloc] init];
  
  if (initialVars && [initialVars isKindOfClass:[NSDictionary class]]) {
    [executor.variables addEntriesFromDictionary:initialVars];
  }
  
  // For streaming, we'd need to set up the stream writer here
  // This requires modification to FBRoute/FBRouteRequest to support streaming responses
  
  NSDictionary *result = [executor executeSteps:stepsArray];
  
  return FBResponseWithObject(result);
}

#pragma mark - Original Commands (unchanged from your original file)

+ (id<FBResponsePayload>)handleHomescreenCommand:(FBRouteRequest *)request
{
  NSError *error;
  if (![[XCUIDevice sharedDevice] fb_goToHomescreenWithError:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description traceback:nil]);
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
  : FBResponseWithStatus([FBCommandStatus invalidElementStateErrorWithMessage:error.description traceback:nil]);
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
  if (app == nil) return @{};
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
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"The 'resource' argument must be set" traceback:nil]);
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
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Notification name required" traceback:nil]);
  }
  NSNumber *timeout = request.arguments[@"timeout"] ?: @60;
  NSString *type = request.arguments[@"type"] ?: @"plain";

  XCTWaiterResult result;
  if ([type isEqualToString:@"plain"]) {
    result = [FBNotificationsHelper waitForNotificationWithName:name timeout:timeout.doubleValue];
  } else if ([type isEqualToString:@"darwin"]) {
    result = [FBNotificationsHelper waitForDarwinNotificationWithName:name timeout:timeout.doubleValue];
  } else {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Type must be 'plain' or 'darwin'" traceback:nil]);
  }
  if (result != XCTWaiterResultCompleted) {
    return FBResponseWithStatus([FBCommandStatus timeoutErrorWithMessage:@"Notification not received" traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleSetDeviceAppearance:(FBRouteRequest *)request
{
  NSString *name = [request.arguments[@"name"] lowercaseString];
  if (nil == name || !([name isEqualToString:@"light"] || [name isEqualToString:@"dark"])) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Appearance must be 'light' or 'dark'" traceback:nil]);
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

  if (nil == userInterfaceStyle) return @"unsupported";
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
  if (timeZoneAbb == nil) return [localTimeZone name];
  NSString *timeZoneId = [[NSTimeZone timeZoneWithAbbreviation:timeZoneAbb] name];
  return timeZoneId ?: [localTimeZone name];
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
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Both latitude and longitude required" traceback:nil]);
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
    return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"typeKey API requires Xcode15+" traceback:nil]);
  }

  if (![keys isKindOfClass:NSArray.class]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'keys' must be an array" traceback:nil]);
  }
  
  for (id item in (NSArray *)keys) {
    if ([item isKindOfClass:NSString.class]) {
      NSString *keyValue = [FBKeyboard keyValueForName:item] ?: item;
      [destination typeKey:keyValue modifierFlags:XCUIKeyModifierNone];
    } else if ([item isKindOfClass:NSDictionary.class]) {
      id key = [(NSDictionary *)item objectForKey:@"key"];
      if (![key isKindOfClass:NSString.class]) {
        return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'key' must be a string" traceback:nil]);
      }
      id modifiers = [(NSDictionary *)item objectForKey:@"modifierFlags"];
      NSUInteger modifierFlags = XCUIKeyModifierNone;
      if ([modifiers isKindOfClass:NSNumber.class]) {
        modifierFlags = [(NSNumber *)modifiers unsignedIntValue];
      }
      NSString *keyValue = [FBKeyboard keyValueForName:item] ?: key;
      [destination typeKey:keyValue modifierFlags:modifierFlags];
    } else {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Items must be strings or dicts" traceback:nil]);
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
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'dataBase64' required" traceback:nil]);
  }
  
  NSData *imageData = [[NSData alloc] initWithBase64EncodedString:dataBase64 options:0];
  if (nil == imageData) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Cannot decode base64" traceback:nil]);
  }
  
  UIImage *image = [UIImage imageWithData:imageData];
  if (nil == image) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Cannot create image" traceback:nil]);
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
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Photo library not authorized" traceback:nil]);
  }
  
  [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
    PHAssetCreationRequest *creationRequest = [PHAssetCreationRequest creationRequestForAssetFromImage:image];
    if (creationTimestampMs != nil) {
      creationRequest.creationDate = [NSDate dateWithTimeIntervalSince1970:(creationTimestampMs.doubleValue / 1000.0)];
    }
    assetLocalIdentifier = creationRequest.placeholderForCreatedAsset.localIdentifier;
  } error:&blockError];
  
  if (blockError != nil) return FBResponseWithUnknownError(blockError);
  
  if (useAlbum) {
    PHFetchOptions *fetchOptions = [[PHFetchOptions alloc] init];
    fetchOptions.predicate = [NSPredicate predicateWithFormat:@"title = %@", albumName];
    PHFetchResult<PHAssetCollection *> *collections = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                               subtype:PHAssetCollectionSubtypeAny
                                                                                               options:fetchOptions];
    __block PHAssetCollection *album = collections.firstObject;
    
    if (nil == album) {
      [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
        [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:albumName];
      } error:&blockError];
      if (blockError != nil) return FBResponseWithUnknownError(blockError);
      
      collections = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                             subtype:PHAssetCollectionSubtypeAny
                                                             options:fetchOptions];
      album = collections.firstObject;
    }
    
    if (nil == album) {
      return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Failed to find/create album" traceback:nil]);
    }
    
    PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithLocalIdentifiers:@[assetLocalIdentifier] options:nil];
    PHAsset *asset = assets.firstObject;
    
    if (nil != asset) {
      [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
        PHAssetCollectionChangeRequest *albumChangeRequest = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
        [albumChangeRequest addAssets:@[asset]];
      } error:&blockError];
      if (blockError != nil) return FBResponseWithUnknownError(blockError);
    }
  }
  
  return FBResponseWithOK();
}

+ (BOOL)handleDeleteConfirmationDialogWithTimeout:(NSTimeInterval)timeout
{
  XCUIApplication *springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
  NSArray<NSString *> *deleteButtons = @[@"Delete", @"Delete Photo", @"Delete Photos", @"Delete Items",
                                          @"Удалить", @"Supprimer", @"Löschen", @"Eliminar", @"删除", @"刪除", @"削除", @"삭제"];
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    for (NSString *label in deleteButtons) {
      XCUIElement *btn = springboard.buttons[label];
      if (btn.exists && btn.isHittable) {
        [btn tap];
        return YES;
      }
    }
    
    XCUIElementQuery *alerts = springboard.alerts;
    if (alerts.count > 0) {
      XCUIElement *alert = [alerts elementBoundByIndex:0];
      for (NSUInteger i = 0; i < alert.buttons.count; i++) {
        XCUIElement *btn = [alert.buttons elementBoundByIndex:i];
        NSString *label = [btn.label lowercaseString];
        if ([label containsString:@"delete"] || [label containsString:@"remove"]) {
          if (btn.exists && btn.isHittable) {
            [btn tap];
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
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'count' must be >= 1" traceback:nil]);
  }
  
  PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
  if (status != PHAuthorizationStatusAuthorized) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Photo library not authorized" traceback:nil]);
  }
  
  PHFetchResult<PHAsset *> *assets = nil;
  PHAssetCollection *album = nil;
  
  if (deleteFromLibrary) {
    PHFetchOptions *opts = [[PHFetchOptions alloc] init];
    opts.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:YES]];
    assets = [PHAsset fetchAssetsWithOptions:opts];
  } else {
    PHFetchOptions *fetchOptions = [[PHFetchOptions alloc] init];
    fetchOptions.predicate = [NSPredicate predicateWithFormat:@"title = %@", albumName];
    PHFetchResult<PHAssetCollection *> *collections = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                                               subtype:PHAssetCollectionSubtypeAny
                                                                                               options:fetchOptions];
    album = collections.firstObject;
    if (nil == album) return FBResponseWithOK();
    
    PHFetchOptions *opts = [[PHFetchOptions alloc] init];
    opts.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:YES]];
    assets = [PHAsset fetchAssetsInAssetCollection:album options:opts];
  }
  
  NSInteger actualCount = MIN(count.integerValue, (NSInteger)assets.count);
  if (actualCount == 0) return FBResponseWithOK();
  
  NSMutableArray<PHAsset *> *assetsToProcess = [NSMutableArray arrayWithCapacity:actualCount];
  for (NSInteger i = 0; i < actualCount; i++) {
    [assetsToProcess addObject:[assets objectAtIndex:i]];
  }
  
  __block NSError *blockError = nil;
  
  if (deleteFromLibrary) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL completed = NO;
    
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
      [PHAssetChangeRequest deleteAssets:assetsToProcess];
    } completionHandler:^(BOOL success, NSError *error) {
      if (!success && error) blockError = error;
      completed = YES;
      dispatch_semaphore_signal(semaphore);
    }];
    
    [NSThread sleepForTimeInterval:0.5];
    [self handleDeleteConfirmationDialogWithTimeout:5.0];
    
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    
    if (!completed) {
      return FBResponseWithStatus([FBCommandStatus timeoutErrorWithMessage:@"Delete operation timed out" traceback:nil]);
    }
  } else {
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
      PHAssetCollectionChangeRequest *albumChangeRequest = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
      [albumChangeRequest removeAssets:assetsToProcess];
    } error:&blockError];
  }
  
  if (blockError != nil) return FBResponseWithUnknownError(blockError);
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