/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * Enhanced WDA with Script Execution, Vision Framework, and HTTP Streaming
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
@property (nonatomic, assign) BOOL shouldBreak;
@property (nonatomic, assign) BOOL shouldContinue;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *elementCache;

- (NSDictionary *)executeSteps:(NSArray<NSDictionary *> *)steps;
- (NSString *)substituteVariables:(NSString *)input;

@end

@implementation FBScriptExecutor

- (instancetype)init
{
  self = [super init];
  if (self) {
    _results = [NSMutableDictionary dictionary];
    _variables = [NSMutableDictionary dictionary];
    _springboard = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
    _elementCache = [NSMutableArray array];
    _shouldBreak = NO;
    _shouldContinue = NO;
  }
  return self;
}

- (void)emitEvent:(NSString *)type data:(NSDictionary *)data
{
  if (self.streamWriter) {
    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:data];
    event[@"type"] = type;
    event[@"timestamp"] = @([[NSDate date] timeIntervalSince1970] * 1000);
    [self.streamWriter writeEvent:event];
  }
}

- (void)log:(NSString *)message level:(NSString *)level
{
  [self emitEvent:@"log" data:@{@"message": message, @"level": level}];
}

- (NSDictionary *)executeSteps:(NSArray<NSDictionary *> *)steps
{
  NSDate *startTime = [NSDate date];
  
  [self emitEvent:@"start" data:@{@"totalSteps": @(steps.count)}];
  
  for (NSUInteger i = 0; i < steps.count; i++) {
    if (self.shouldBreak) {
      self.shouldBreak = NO;
      break;
    }
    
    if (self.shouldContinue) {
      self.shouldContinue = NO;
      continue;
    }
    
    NSDictionary *step = steps[i];
    NSString *action = step[@"action"] ?: @"unknown";
    NSString *stepId = step[@"id"] ?: [NSString stringWithFormat:@"step_%lu", (unsigned long)i];
    
    [self emitEvent:@"step" data:@{
      @"index": @(i),
      @"action": action,
      @"status": @"started",
      @"stepId": stepId
    }];
    
    NSError *error = nil;
    NSDate *stepStart = [NSDate date];
    BOOL success = [self executeStep:step error:&error];
    NSTimeInterval stepDuration = [[NSDate date] timeIntervalSinceDate:stepStart];
    
    if (!success) {
      NSNumber *optional = step[@"optional"];
      
      [self emitEvent:@"step" data:@{
        @"index": @(i),
        @"action": action,
        @"status": @"failed",
        @"stepId": stepId,
        @"error": error.localizedDescription ?: @"Unknown error",
        @"duration": @(stepDuration * 1000)
      }];
      
      if (optional && optional.boolValue) {
        [self log:[NSString stringWithFormat:@"Optional step '%@' failed, continuing", action] level:@"warn"];
        continue;
      }
      
      NSTimeInterval totalDuration = [[NSDate date] timeIntervalSinceDate:startTime];
      
      NSDictionary *result = @{
        @"success": @NO,
        @"results": self.results,
        @"variables": self.variables,
        @"stoppedAt": @(i),
        @"error": error.localizedDescription ?: @"Unknown error",
        @"failedAction": action,
        @"failedStepId": stepId,
        @"duration": @(totalDuration * 1000)
      };
      
      [self emitEvent:@"complete" data:result];
      return result;
    }
    
    [self emitEvent:@"step" data:@{
      @"index": @(i),
      @"action": action,
      @"status": @"completed",
      @"stepId": stepId,
      @"duration": @(stepDuration * 1000)
    }];
  }
  
  NSTimeInterval totalDuration = [[NSDate date] timeIntervalSinceDate:startTime];
  
  NSDictionary *result = @{
    @"success": @YES,
    @"results": self.results,
    @"variables": self.variables,
    @"stoppedAt": [NSNull null],
    @"error": [NSNull null],
    @"duration": @(totalDuration * 1000)
  };
  
  [self emitEvent:@"complete" data:result];
  return result;
}

- (NSString *)substituteVariables:(NSString *)input
{
  if (!input || ![input isKindOfClass:[NSString class]]) {
    return input;
  }
  
  NSMutableString *result = [input mutableCopy];
  
  // Replace ${varName} with variable value
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\$\\{([^}]+)\\}"
                                                                         options:0
                                                                           error:nil];
  
  NSArray *matches = [regex matchesInString:input options:0 range:NSMakeRange(0, input.length)];
  
  // Process in reverse to maintain correct ranges
  for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
    NSRange varNameRange = [match rangeAtIndex:1];
    NSString *varName = [input substringWithRange:varNameRange];
    
    id value = self.variables[varName];
    if (!value) {
      value = self.results[varName];
    }
    
    if (value) {
      NSString *stringValue = [value isKindOfClass:[NSString class]] ? value : [value description];
      [result replaceCharactersInRange:match.range withString:stringValue];
    }
  }
  
  return result;
}

- (id)substituteInObject:(id)obj
{
  if ([obj isKindOfClass:[NSString class]]) {
    return [self substituteVariables:obj];
  } else if ([obj isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in obj) {
      result[key] = [self substituteInObject:obj[key]];
    }
    return result;
  } else if ([obj isKindOfClass:[NSArray class]]) {
    NSMutableArray *result = [NSMutableArray array];
    for (id item in obj) {
      [result addObject:[self substituteInObject:item]];
    }
    return result;
  }
  return obj;
}

- (BOOL)executeStep:(NSDictionary *)originalStep error:(NSError **)error
{
  // Substitute variables in step
  NSDictionary *step = [self substituteInObject:originalStep];
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
  if ([action isEqualToString:@"isRunning"]) return [self executeIsRunning:step error:error];
  
  // Element actions
  if ([action isEqualToString:@"click"] || [action isEqualToString:@"tap"]) return [self executeClick:step error:error];
  if ([action isEqualToString:@"wait"]) return [self executeWait:step error:error];
  if ([action isEqualToString:@"waitDisappear"]) return [self executeWaitDisappear:step error:error];
  if ([action isEqualToString:@"read"]) return [self executeRead:step error:error];
  if ([action isEqualToString:@"exists"]) return [self executeExists:step error:error];
  if ([action isEqualToString:@"clickIndex"]) return [self executeClickIndex:step error:error];
  if ([action isEqualToString:@"findElements"]) return [self executeFindElements:step error:error];
  if ([action isEqualToString:@"getElementRect"]) return [self executeGetElementRect:step error:error];
  
  // Alert handling
  if ([action isEqualToString:@"handleAlert"]) return [self executeHandleAlert:step error:error];
  if ([action isEqualToString:@"dismissAlert"]) return [self executeDismissAlert:step error:error];
  if ([action isEqualToString:@"acceptAlert"]) return [self executeAcceptAlert:step error:error];
  
  // Picker
  if ([action isEqualToString:@"setPicker"]) return [self executeSetPicker:step error:error];
  if ([action isEqualToString:@"getPicker"]) return [self executeGetPicker:step error:error];
  
  // Coordinates
  if ([action isEqualToString:@"tapXY"]) return [self executeTapXY:step error:error];
  if ([action isEqualToString:@"doubleTapXY"]) return [self executeDoubleTapXY:step error:error];
  if ([action isEqualToString:@"longPressXY"]) return [self executeLongPressXY:step error:error];
  if ([action isEqualToString:@"swipe"]) return [self executeSwipe:step error:error];
  if ([action isEqualToString:@"swipeElement"]) return [self executeSwipeElement:step error:error];
  
  // Input
  if ([action isEqualToString:@"type"] || [action isEqualToString:@"typeText"]) return [self executeType:step error:error];
  if ([action isEqualToString:@"clear"]) return [self executeClear:step error:error];
  if ([action isEqualToString:@"paste"]) return [self executePaste:step error:error];
  
  // Utility
  if ([action isEqualToString:@"sleep"]) return [self executeSleep:step error:error];
  if ([action isEqualToString:@"screenshot"]) return [self executeScreenshot:step error:error];
  if ([action isEqualToString:@"home"]) return [self executeHome:step error:error];
  if ([action isEqualToString:@"lock"]) return [self executeLock:step error:error];
  if ([action isEqualToString:@"unlock"]) return [self executeUnlock:step error:error];
  if ([action isEqualToString:@"log"]) return [self executeLog:step error:error];
  
  // Variables and results
  if ([action isEqualToString:@"set"]) return [self executeSet:step error:error];
  if ([action isEqualToString:@"increment"]) return [self executeIncrement:step error:error];
  if ([action isEqualToString:@"decrement"]) return [self executeDecrement:step error:error];
  if ([action isEqualToString:@"concat"]) return [self executeConcat:step error:error];
  if ([action isEqualToString:@"parseDate"]) return [self executeParseDate:step error:error];
  if ([action isEqualToString:@"formatDate"]) return [self executeFormatDate:step error:error];
  if ([action isEqualToString:@"math"]) return [self executeMath:step error:error];
  
  // Control flow
  if ([action isEqualToString:@"if"]) return [self executeIf:step error:error];
  if ([action isEqualToString:@"while"]) return [self executeWhile:step error:error];
  if ([action isEqualToString:@"repeat"]) return [self executeRepeat:step error:error];
  if ([action isEqualToString:@"forEach"]) return [self executeForEach:step error:error];
  if ([action isEqualToString:@"break"]) { self.shouldBreak = YES; return YES; }
  if ([action isEqualToString:@"continue"]) { self.shouldContinue = YES; return YES; }
  if ([action isEqualToString:@"try"]) return [self executeTry:step error:error];
  if ([action isEqualToString:@"return"]) return [self executeReturn:step error:error];
  
  // Assertions
  if ([action isEqualToString:@"assert"]) return [self executeAssert:step error:error];
  if ([action isEqualToString:@"assertExists"]) return [self executeAssertExists:step error:error];
  if ([action isEqualToString:@"assertNotExists"]) return [self executeAssertNotExists:step error:error];
  if ([action isEqualToString:@"assertText"]) return [self executeAssertText:step error:error];
  
#if !TARGET_OS_TV
  // Vision/OCR
  if ([action isEqualToString:@"clickText"] || [action isEqualToString:@"tapText"]) return [self executeClickText:step error:error];
  if ([action isEqualToString:@"waitText"]) return [self executeWaitText:step error:error];
  if ([action isEqualToString:@"readScreen"]) return [self executeReadScreen:step error:error];
  if ([action isEqualToString:@"readRegion"]) return [self executeReadRegion:step error:error];
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
  NSString *bundleId = step[@"bundleId"];
  if (!bundleId) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:3
                             userInfo:@{NSLocalizedDescriptionKey: @"'bundleId' required for launch"}];
    return NO;
  }
  
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  NSNumber *retries = step[@"retries"] ?: @1;
  NSTimeInterval retryDelay = [step[@"retryDelay"] doubleValue] ?: 2.0;
  
  for (NSInteger attempt = 0; attempt < retries.integerValue; attempt++) {
    if (attempt > 0) {
      [self log:[NSString stringWithFormat:@"Launch attempt %ld of %@", (long)attempt + 1, retries] level:@"info"];
      [NSThread sleepForTimeInterval:retryDelay];
    }
    
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
    [app launch];
    self.currentApp = app;
    
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
      if (app.state == XCUIApplicationStateRunningForeground) {
        // Store app state
        self.variables[@"_appBundleId"] = bundleId;
        self.variables[@"_appState"] = @"foreground";
        return YES;
      }
      [NSThread sleepForTimeInterval:0.1];
    }
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:4
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"App '%@' did not launch within timeout after %@ attempts", bundleId, retries]}];
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
  
  // Wait for termination
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 5.0;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    if (app.state == XCUIApplicationStateNotRunning || app.state == XCUIApplicationStateUnknown) {
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  return YES; // Don't fail if app doesn't terminate cleanly
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
  
  self.variables[@"_appBundleId"] = bundleId;
  return YES;
}

- (BOOL)executeIsRunning:(NSDictionary *)step error:(NSError **)error
{
  NSString *bundleId = step[@"bundleId"];
  NSString *key = step[@"as"] ?: @"isRunning";
  
  if (!bundleId) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:3
                             userInfo:@{NSLocalizedDescriptionKey: @"'bundleId' required for isRunning"}];
    return NO;
  }
  
  XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
  BOOL running = (app.state == XCUIApplicationStateRunningForeground || 
                  app.state == XCUIApplicationStateRunningBackground ||
                  app.state == XCUIApplicationStateRunningBackgroundSuspended);
  
  self.results[key] = running ? @"true" : @"false";
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
    // Try common element types first
    XCUIElement *element = app.buttons[selector];
    if (element.exists) return element;
    
    element = app.staticTexts[selector];
    if (element.exists) return element;
    
    element = app.textFields[selector];
    if (element.exists) return element;
    
    element = app.secureTextFields[selector];
    if (element.exists) return element;
    
    element = app.textViews[selector];
    if (element.exists) return element;
    
    element = app.images[selector];
    if (element.exists) return element;
    
    element = app.cells[selector];
    if (element.exists) return element;
    
    element = app.switches[selector];
    if (element.exists) return element;
    
    element = app.tables[selector];
    if (element.exists) return element;
    
    element = app.collectionViews[selector];
    if (element.exists) return element;
    
    element = app.otherElements[selector];
    if (element.exists) return element;
    
    // Generic query
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
  
  if ([type isEqualToString:@"valueContains"]) {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"value CONTAINS %@", selector];
    return [[app descendantsMatchingType:XCUIElementTypeAny] elementMatchingPredicate:predicate];
  }
  
  return nil;
}

- (NSArray<XCUIElement *> *)findElementsWithSelector:(NSString *)selector
                                        selectorType:(NSString *)selectorType
                                               inApp:(XCUIApplication *)app
                                               limit:(NSInteger)limit
{
  if (!selector) return @[];
  
  NSString *type = selectorType ?: @"accessibilityId";
  NSMutableArray<XCUIElement *> *results = [NSMutableArray array];
  
  XCUIElementQuery *query = nil;
  
  if ([type isEqualToString:@"classChain"]) {
    NSArray *elements = [app fb_descendantsMatchingClassChain:selector shouldReturnAfterFirstMatch:NO];
    if (limit > 0 && elements.count > limit) {
      return [elements subarrayWithRange:NSMakeRange(0, limit)];
    }
    return elements;
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
  }
  
  if (query) {
    NSUInteger count = query.count;
    NSUInteger maxCount = limit > 0 ? MIN(count, limit) : count;
    for (NSUInteger i = 0; i < maxCount; i++) {
      XCUIElement *element = [query elementBoundByIndex:i];
      if (element.exists) {
        [results addObject:element];
      }
    }
  }
  
  return results;
}

#pragma mark - Element Actions

- (BOOL)executeClick:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  NSNumber *offsetX = step[@"offsetX"];
  NSNumber *offsetY = step[@"offsetY"];
  
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
      if (offsetX || offsetY) {
        CGRect frame = element.frame;
        CGFloat x = frame.origin.x + (offsetX ? offsetX.doubleValue : frame.size.width / 2);
        CGFloat y = frame.origin.y + (offsetY ? offsetY.doubleValue : frame.size.height / 2);
        XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                                 coordinateWithOffset:CGVectorMake(x, y)];
        [coord tap];
      } else {
        [element tap];
      }
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:6
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found or not clickable within %.1fs", selector, timeout]}];
  return NO;
}

- (BOOL)executeClickIndex:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSNumber *index = step[@"index"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  NSNumber *offsetX = step[@"offsetX"];
  NSNumber *offsetY = step[@"offsetY"];
  
  if (!selector || index == nil) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' and 'index' required for clickIndex"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    NSArray<XCUIElement *> *elements = [self findElementsWithSelector:selector 
                                                         selectorType:selectorType 
                                                                inApp:app 
                                                                limit:index.integerValue + 1];
    
    if (elements.count > index.unsignedIntegerValue) {
      XCUIElement *element = elements[index.unsignedIntegerValue];
      if (element.exists && element.isHittable) {
        if (offsetX || offsetY) {
          CGRect frame = element.frame;
          CGFloat x = frame.origin.x + (offsetX ? offsetX.doubleValue : frame.size.width / 2);
          CGFloat y = frame.origin.y + (offsetY ? offsetY.doubleValue : frame.size.height / 2);
          XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                                   coordinateWithOffset:CGVectorMake(x, y)];
          [coord tap];
        } else {
          [element tap];
        }
        return YES;
      }
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:7
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element at index %@ not found for selector '%@'", index, selector]}];
  return NO;
}

- (BOOL)executeFindElements:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"] ?: @"elements";
  NSNumber *limit = step[@"limit"];
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for findElements"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSArray<XCUIElement *> *elements = [self findElementsWithSelector:selector 
                                                       selectorType:selectorType 
                                                              inApp:app 
                                                              limit:limit.integerValue];
  
  // Store element info in cache and results
  [self.elementCache removeAllObjects];
  NSMutableArray *elementData = [NSMutableArray array];
  
  for (NSUInteger i = 0; i < elements.count; i++) {
    XCUIElement *element = elements[i];
    CGRect frame = element.frame;
    
    NSDictionary *info = @{
      @"index": @(i),
      @"x": @(frame.origin.x),
      @"y": @(frame.origin.y),
      @"width": @(frame.size.width),
      @"height": @(frame.size.height),
      @"label": element.label ?: @"",
      @"value": [element valueForKey:@"value"] ?: @"",
      @"isEnabled": @(element.isEnabled),
      @"isHittable": @(element.isHittable)
    };
    
    [self.elementCache addObject:info];
    [elementData addObject:info];
  }
  
  // Store count and data
  self.results[[key stringByAppendingString:@"_count"]] = [NSString stringWithFormat:@"%lu", (unsigned long)elements.count];
  self.variables[key] = elementData;
  
  return YES;
}

- (BOOL)executeGetElementRect:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"] ?: @"rect";
  NSNumber *index = step[@"index"] ?: @0;
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 5.0;
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for getElementRect"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    NSArray<XCUIElement *> *elements = [self findElementsWithSelector:selector 
                                                         selectorType:selectorType 
                                                                inApp:app 
                                                                limit:index.integerValue + 1];
    
    if (elements.count > index.unsignedIntegerValue) {
      XCUIElement *element = elements[index.unsignedIntegerValue];
      if (element.exists) {
        CGRect frame = element.frame;
        self.results[[key stringByAppendingString:@"_x"]] = [NSString stringWithFormat:@"%.0f", frame.origin.x];
        self.results[[key stringByAppendingString:@"_y"]] = [NSString stringWithFormat:@"%.0f", frame.origin.y];
        self.results[[key stringByAppendingString:@"_width"]] = [NSString stringWithFormat:@"%.0f", frame.size.width];
        self.results[[key stringByAppendingString:@"_height"]] = [NSString stringWithFormat:@"%.0f", frame.size.height];
        self.results[[key stringByAppendingString:@"_centerX"]] = [NSString stringWithFormat:@"%.0f", CGRectGetMidX(frame)];
        self.results[[key stringByAppendingString:@"_centerY"]] = [NSString stringWithFormat:@"%.0f", CGRectGetMidY(frame)];
        return YES;
      }
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:8
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' at index %@ not found", selector, index]}];
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
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:9
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
  
  // Timeout is not an error for waitDisappear - element may still be visible
  return YES;
}

- (BOOL)executeRead:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"];
  NSString *attribute = step[@"attribute"] ?: @"label";  // label, value, or identifier
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (!selector) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:5
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' required for read"}];
    return NO;
  }
  
  if (!key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:10
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
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:11
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for reading within %.1fs", selector, timeout]}];
  return NO;
}

- (BOOL)executeExists:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *key = step[@"as"] ?: @"exists";
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 0;  // Default: no wait
  
  XCUIApplication *app = [self getTargetApp];
  
  if (timeout > 0) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
      XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      if (element && element.exists) {
        self.results[key] = @"true";
        return YES;
      }
      [NSThread sleepForTimeInterval:0.1];
    }
    self.results[key] = @"false";
  } else {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    self.results[key] = (element && element.exists) ? @"true" : @"false";
  }
  
  return YES;
}

#pragma mark - Alert Handling

- (BOOL)executeHandleAlert:(NSDictionary *)step error:(NSError **)error
{
  NSString *buttonName = step[@"button"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 3.0;
  NSNumber *retries = step[@"retries"] ?: @1;
  
  if (!buttonName) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:12
                             userInfo:@{NSLocalizedDescriptionKey: @"'button' required for handleAlert"}];
    return NO;
  }
  
  for (NSInteger attempt = 0; attempt < retries.integerValue; attempt++) {
    if (attempt > 0) {
      [NSThread sleepForTimeInterval:0.5];
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
      
      // Check current app
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
  }
  
  NSNumber *optional = step[@"optional"];
  if (optional && optional.boolValue) {
    return YES;
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:13
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Alert button '%@' not found", buttonName]}];
  return NO;
}

- (BOOL)executeDismissAlert:(NSDictionary *)step error:(NSError **)error
{
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 2.0;
  NSArray *dismissButtons = @[@"Cancel", @"No", @"Don't Allow", @"Not Now", @"Later", @"Dismiss"];
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    // Check springboard
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
    
    // Check current app
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
  
  return YES;  // Don't fail if no alert found
}

- (BOOL)executeAcceptAlert:(NSDictionary *)step error:(NSError **)error
{
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 2.0;
  NSArray *acceptButtons = @[@"OK", @"Allow", @"Yes", @"Accept", @"Continue", @"Open", @"Allow Full Access", @"Allow While Using App"];
  
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    // Check springboard
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
    
    // Check current app
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
  NSString *value = step[@"value"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  
  if (index == nil) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:14
                             userInfo:@{NSLocalizedDescriptionKey: @"'index' required for setPicker"}];
    return NO;
  }
  
  if (!value) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:15
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
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:16
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Picker at index %@ not found", index]}];
  return NO;
}

- (BOOL)executeGetPicker:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *index = step[@"index"];
  NSString *key = step[@"as"] ?: @"pickerValue";
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 5.0;
  
  if (index == nil) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:14
                             userInfo:@{NSLocalizedDescriptionKey: @"'index' required for getPicker"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElementQuery *pickers = app.pickerWheels;
    if (pickers.count > index.unsignedIntegerValue) {
      XCUIElement *picker = [pickers elementBoundByIndex:index.unsignedIntegerValue];
      if (picker.exists) {
        self.results[key] = [picker valueForKey:@"value"] ?: @"";
        return YES;
      }
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:16
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Picker at index %@ not found", index]}];
  return NO;
}

#pragma mark - Coordinate Actions

- (BOOL)executeTapXY:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *x = step[@"x"];
  NSNumber *y = step[@"y"];
  
  if (!x || !y) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:17
                             userInfo:@{NSLocalizedDescriptionKey: @"'x' and 'y' required for tapXY"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                           coordinateWithOffset:CGVectorMake(x.doubleValue, y.doubleValue)];
  [coord tap];
  return YES;
}

- (BOOL)executeDoubleTapXY:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *x = step[@"x"];
  NSNumber *y = step[@"y"];
  
  if (!x || !y) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:17
                             userInfo:@{NSLocalizedDescriptionKey: @"'x' and 'y' required for doubleTapXY"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                           coordinateWithOffset:CGVectorMake(x.doubleValue, y.doubleValue)];
  [coord doubleTap];
  return YES;
}

- (BOOL)executeLongPressXY:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *x = step[@"x"];
  NSNumber *y = step[@"y"];
  NSTimeInterval duration = [step[@"duration"] doubleValue] ?: 1.0;
  
  if (!x || !y) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:17
                             userInfo:@{NSLocalizedDescriptionKey: @"'x' and 'y' required for longPressXY"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                           coordinateWithOffset:CGVectorMake(x.doubleValue, y.doubleValue)];
  [coord pressForDuration:duration];
  return YES;
}

- (BOOL)executeSwipe:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *x = step[@"x"];
  NSNumber *y = step[@"y"];
  NSNumber *toX = step[@"toX"];
  NSNumber *toY = step[@"toY"];
  NSTimeInterval duration = [step[@"duration"] doubleValue] ?: 0.3;
  
  if (!x || !y || !toX || !toY) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:18
                             userInfo:@{NSLocalizedDescriptionKey: @"'x', 'y', 'toX', 'toY' required for swipe"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  XCUICoordinate *start = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                           coordinateWithOffset:CGVectorMake(x.doubleValue, y.doubleValue)];
  XCUICoordinate *end = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                         coordinateWithOffset:CGVectorMake(toX.doubleValue, toY.doubleValue)];
  
  [start pressForDuration:duration thenDragToCoordinate:end];
  return YES;
}

- (BOOL)executeSwipeElement:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *direction = step[@"direction"];  // up, down, left, right
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 5.0;
  
  if (!selector || !direction) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:19
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' and 'direction' required for swipeElement"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (element && element.exists) {
      if ([direction isEqualToString:@"up"]) {
        [element swipeUp];
      } else if ([direction isEqualToString:@"down"]) {
        [element swipeDown];
      } else if ([direction isEqualToString:@"left"]) {
        [element swipeLeft];
      } else if ([direction isEqualToString:@"right"]) {
        [element swipeRight];
      }
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:20
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for swipe", selector]}];
  return NO;
}

#pragma mark - Input Actions

- (BOOL)executeType:(NSDictionary *)step error:(NSError **)error
{
  NSString *text = step[@"value"] ?: step[@"text"];
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 10.0;
  BOOL clearFirst = [step[@"clear"] boolValue];
  
  if (!text) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:21
                             userInfo:@{NSLocalizedDescriptionKey: @"'value' or 'text' required for type action"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  
  if (selector) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
      XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      if (element && element.exists) {
        [element tap];
        
        if (clearFirst) {
          // Select all and delete
          [element pressForDuration:1.0];
          XCUIElement *selectAll = app.menuItems[@"Select All"];
          if ([selectAll waitForExistenceWithTimeout:1.0]) {
            [selectAll tap];
            [app typeText:XCUIKeyboardKeyDelete];
          }
        }
        
        break;
      }
      [NSThread sleepForTimeInterval:0.1];
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
      if ([selectAll waitForExistenceWithTimeout:1.0]) {
        [selectAll tap];
        [app typeText:XCUIKeyboardKeyDelete];
      }
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:22
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Element '%@' not found for clearing", selector]}];
  return NO;
}

- (BOOL)executePaste:(NSDictionary *)step error:(NSError **)error
{
  NSString *text = step[@"value"] ?: step[@"text"];
  
  if (!text) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:21
                             userInfo:@{NSLocalizedDescriptionKey: @"'value' or 'text' required for paste"}];
    return NO;
  }
  
  UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
  pasteboard.string = text;
  
  // Tap paste if available
  XCUIApplication *app = [self getTargetApp];
  XCUIElement *pasteMenu = app.menuItems[@"Paste"];
  if ([pasteMenu waitForExistenceWithTimeout:1.0]) {
    [pasteMenu tap];
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
  BOOL full = [step[@"full"] boolValue];  // Full quality or compressed
  
  XCUIScreenshot *screenshot = XCUIScreen.mainScreen.screenshot;
  NSData *imageData;
  
  if (full) {
    imageData = screenshot.PNGRepresentation;
  } else {
    // Compressed JPEG for faster transfer
    UIImage *image = screenshot.image;
    imageData = UIImageJPEGRepresentation(image, 0.7);
  }
  
  NSString *base64 = [imageData base64EncodedStringWithOptions:0];
  self.results[key] = base64;
  
  return YES;
}

- (BOOL)executeHome:(NSDictionary *)step error:(NSError **)error
{
  [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
  return YES;
}

- (BOOL)executeLock:(NSDictionary *)step error:(NSError **)error
{
  NSError *lockError = nil;
  if (![[XCUIDevice sharedDevice] fb_lockScreen:&lockError]) {
    *error = lockError;
    return NO;
  }
  return YES;
}

- (BOOL)executeUnlock:(NSDictionary *)step error:(NSError **)error
{
  NSError *unlockError = nil;
  if (![[XCUIDevice sharedDevice] fb_unlockScreen:&unlockError]) {
    *error = unlockError;
    return NO;
  }
  return YES;
}

- (BOOL)executeLog:(NSDictionary *)step error:(NSError **)error
{
  NSString *message = step[@"message"] ?: @"";
  NSString *level = step[@"level"] ?: @"info";
  
  [self log:message level:level];
  return YES;
}

#pragma mark - Variables and Results

- (BOOL)executeSet:(NSDictionary *)step error:(NSError **)error
{
  NSString *key = step[@"key"];
  id value = step[@"value"];
  NSString *target = step[@"target"] ?: @"variables";  // "variables" or "results"
  
  if (!key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:23
                             userInfo:@{NSLocalizedDescriptionKey: @"'key' required for set"}];
    return NO;
  }
  
  NSString *stringValue = [value isKindOfClass:[NSString class]] ? value : [value description];
  
  if ([target isEqualToString:@"results"]) {
    self.results[key] = stringValue;
  } else {
    self.variables[key] = value;  // Keep original type for variables
  }
  
  return YES;
}

- (BOOL)executeIncrement:(NSDictionary *)step error:(NSError **)error
{
  NSString *key = step[@"key"];
  NSNumber *by = step[@"by"] ?: @1;
  
  if (!key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:23
                             userInfo:@{NSLocalizedDescriptionKey: @"'key' required for increment"}];
    return NO;
  }
  
  id current = self.variables[key] ?: self.results[key] ?: @0;
  NSInteger value = [current integerValue] + by.integerValue;
  
  self.variables[key] = @(value);
  self.results[key] = [NSString stringWithFormat:@"%ld", (long)value];
  
  return YES;
}

- (BOOL)executeDecrement:(NSDictionary *)step error:(NSError **)error
{
  NSString *key = step[@"key"];
  NSNumber *by = step[@"by"] ?: @1;
  
  if (!key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:23
                             userInfo:@{NSLocalizedDescriptionKey: @"'key' required for decrement"}];
    return NO;
  }
  
  id current = self.variables[key] ?: self.results[key] ?: @0;
  NSInteger value = [current integerValue] - by.integerValue;
  
  self.variables[key] = @(value);
  self.results[key] = [NSString stringWithFormat:@"%ld", (long)value];
  
  return YES;
}

- (BOOL)executeConcat:(NSDictionary *)step error:(NSError **)error
{
  NSString *key = step[@"key"];
  NSArray *values = step[@"values"];
  NSString *separator = step[@"separator"] ?: @"";
  
  if (!key || !values) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:23
                             userInfo:@{NSLocalizedDescriptionKey: @"'key' and 'values' required for concat"}];
    return NO;
  }
  
  NSMutableArray *stringValues = [NSMutableArray array];
  for (id value in values) {
    NSString *str = [value isKindOfClass:[NSString class]] ? value : [value description];
    str = [self substituteVariables:str];
    [stringValues addObject:str];
  }
  
  NSString *result = [stringValues componentsJoinedByString:separator];
  self.variables[key] = result;
  self.results[key] = result;
  
  return YES;
}

- (BOOL)executeParseDate:(NSDictionary *)step error:(NSError **)error
{
  NSString *input = step[@"input"];
  NSString *key = step[@"as"];
  NSArray *formats = step[@"formats"];
  
  if (!input || !key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:24
                             userInfo:@{NSLocalizedDescriptionKey: @"'input' and 'as' required for parseDate"}];
    return NO;
  }
  
  input = [self substituteVariables:input];
  
  if (!formats) {
    formats = @[
      @"M/d/yyyy h:mm a",
      @"MM/dd h:mm a",
      @"h:mm a",
      @"yyyy-MM-dd HH:mm:ss",
      @"yyyy-MM-dd'T'HH:mm:ssZ"
    ];
  }
  
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  
  NSDate *date = nil;
  for (NSString *format in formats) {
    formatter.dateFormat = format;
    date = [formatter dateFromString:input];
    if (date) break;
  }
  
  if (date) {
    self.variables[key] = date;
    self.results[[key stringByAppendingString:@"_timestamp"]] = [NSString stringWithFormat:@"%.0f", [date timeIntervalSince1970] * 1000];
    
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
    self.results[[key stringByAppendingString:@"_year"]] = [NSString stringWithFormat:@"%ld", (long)components.year];
    self.results[[key stringByAppendingString:@"_month"]] = [NSString stringWithFormat:@"%ld", (long)components.month];
    self.results[[key stringByAppendingString:@"_day"]] = [NSString stringWithFormat:@"%ld", (long)components.day];
    self.results[[key stringByAppendingString:@"_hour"]] = [NSString stringWithFormat:@"%ld", (long)components.hour];
    self.results[[key stringByAppendingString:@"_minute"]] = [NSString stringWithFormat:@"%ld", (long)components.minute];
    
    return YES;
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:25
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not parse date: %@", input]}];
  return NO;
}

- (BOOL)executeFormatDate:(NSDictionary *)step error:(NSError **)error
{
  NSString *format = step[@"format"];
  NSString *key = step[@"as"];
  NSNumber *timestamp = step[@"timestamp"];
  NSString *dateKey = step[@"dateKey"];
  
  if (!format || !key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:24
                             userInfo:@{NSLocalizedDescriptionKey: @"'format' and 'as' required for formatDate"}];
    return NO;
  }
  
  NSDate *date = nil;
  
  if (timestamp) {
    date = [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue / 1000.0];
  } else if (dateKey) {
    date = self.variables[dateKey];
  } else {
    date = [NSDate date];  // Current date
  }
  
  if (!date) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:26
                             userInfo:@{NSLocalizedDescriptionKey: @"No valid date found for formatDate"}];
    return NO;
  }
  
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.dateFormat = format;
  
  NSString *result = [formatter stringFromDate:date];
  self.results[key] = result;
  self.variables[key] = result;
  
  return YES;
}

- (BOOL)executeMath:(NSDictionary *)step error:(NSError **)error
{
  NSString *operation = step[@"operation"];  // add, subtract, multiply, divide, mod
  NSNumber *a = step[@"a"];
  NSNumber *b = step[@"b"];
  NSString *key = step[@"as"];
  
  if (!operation || !a || !b || !key) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:27
                             userInfo:@{NSLocalizedDescriptionKey: @"'operation', 'a', 'b', and 'as' required for math"}];
    return NO;
  }
  
  double result = 0;
  
  if ([operation isEqualToString:@"add"]) {
    result = a.doubleValue + b.doubleValue;
  } else if ([operation isEqualToString:@"subtract"]) {
    result = a.doubleValue - b.doubleValue;
  } else if ([operation isEqualToString:@"multiply"]) {
    result = a.doubleValue * b.doubleValue;
  } else if ([operation isEqualToString:@"divide"]) {
    if (b.doubleValue == 0) {
      *error = [NSError errorWithDomain:@"FBScriptExecutor" code:28
                               userInfo:@{NSLocalizedDescriptionKey: @"Division by zero"}];
      return NO;
    }
    result = a.doubleValue / b.doubleValue;
  } else if ([operation isEqualToString:@"mod"]) {
    result = fmod(a.doubleValue, b.doubleValue);
  }
  
  self.variables[key] = @(result);
  self.results[key] = [NSString stringWithFormat:@"%g", result];
  
  return YES;
}

#pragma mark - Control Flow

- (BOOL)evaluateCondition:(NSDictionary *)step
{
  NSString *condition = step[@"condition"];
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *text = step[@"text"];
  NSString *key = step[@"key"];
  NSString *value = step[@"value"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 2.0;
  
  XCUIApplication *app = [self getTargetApp];
  
  if ([condition isEqualToString:@"exists"]) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    return (element && element.exists);
    
  } else if ([condition isEqualToString:@"notExists"]) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    return (!element || !element.exists);
    
  } else if ([condition isEqualToString:@"visible"]) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    return (element && element.exists && element.isHittable);
    
  } else if ([condition isEqualToString:@"waitExists"]) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
      XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
      if (element && element.exists) return YES;
      [NSThread sleepForTimeInterval:0.1];
    }
    return NO;
    
  } else if ([condition isEqualToString:@"resultEquals"]) {
    NSString *storedValue = self.results[key];
    return [storedValue isEqualToString:value];
    
  } else if ([condition isEqualToString:@"resultNotEquals"]) {
    NSString *storedValue = self.results[key];
    return ![storedValue isEqualToString:value];
    
  } else if ([condition isEqualToString:@"resultContains"]) {
    NSString *storedValue = self.results[key];
    return storedValue && [storedValue containsString:value];
    
  } else if ([condition isEqualToString:@"resultGreaterThan"]) {
    NSNumber *storedValue = @([self.results[key] doubleValue]);
    NSNumber *compareValue = @([value doubleValue]);
    return [storedValue compare:compareValue] == NSOrderedDescending;
    
  } else if ([condition isEqualToString:@"resultLessThan"]) {
    NSNumber *storedValue = @([self.results[key] doubleValue]);
    NSNumber *compareValue = @([value doubleValue]);
    return [storedValue compare:compareValue] == NSOrderedAscending;
    
  } else if ([condition isEqualToString:@"true"]) {
    return YES;
    
  } else if ([condition isEqualToString:@"false"]) {
    return NO;
  }
  
#if !TARGET_OS_TV
  if ([condition isEqualToString:@"textVisible"]) {
    UIImage *screenshot = [self captureScreenshot];
    CGPoint point = [self findTextInImage:screenshot text:text];
    return !CGPointEqualToPoint(point, CGPointZero);
    
  } else if ([condition isEqualToString:@"textNotVisible"]) {
    UIImage *screenshot = [self captureScreenshot];
    CGPoint point = [self findTextInImage:screenshot text:text];
    return CGPointEqualToPoint(point, CGPointZero);
  }
#endif
  
  return NO;
}

- (BOOL)executeIf:(NSDictionary *)step error:(NSError **)error
{
  NSArray *thenSteps = step[@"then"];
  NSArray *elseSteps = step[@"else"];
  
  BOOL conditionMet = [self evaluateCondition:step];
  
  NSArray *stepsToExecute = conditionMet ? thenSteps : elseSteps;
  
  if (stepsToExecute && [stepsToExecute isKindOfClass:[NSArray class]] && stepsToExecute.count > 0) {
    for (NSDictionary *subStep in stepsToExecute) {
      if (![subStep isKindOfClass:[NSDictionary class]]) continue;
      if (self.shouldBreak || self.shouldContinue) break;
      
      NSError *subError = nil;
      BOOL success = [self executeStep:subStep error:&subError];
      
      if (!success) {
        NSNumber *optional = subStep[@"optional"];
        if (optional && optional.boolValue) continue;
        *error = subError;
        return NO;
      }
    }
  }
  
  return YES;
}

- (BOOL)executeWhile:(NSDictionary *)step error:(NSError **)error
{
  NSArray *doSteps = step[@"do"];
  NSNumber *maxIterations = step[@"maxIterations"] ?: @100;
  NSTimeInterval interval = [step[@"interval"] doubleValue] ?: 0.1;
  
  if (!doSteps || ![doSteps isKindOfClass:[NSArray class]]) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:29
                             userInfo:@{NSLocalizedDescriptionKey: @"'do' steps array required for while action"}];
    return NO;
  }
  
  NSInteger iterations = 0;
  
  while (iterations < maxIterations.integerValue) {
    if (!self.evaluateCondition:step]) break;
    if (self.shouldBreak) {
      self.shouldBreak = NO;
      break;
    }
    
    iterations++;
    self.variables[@"_iteration"] = @(iterations);
    
    for (NSDictionary *subStep in doSteps) {
      if (![subStep isKindOfClass:[NSDictionary class]]) continue;
      if (self.shouldBreak) break;
      if (self.shouldContinue) {
        self.shouldContinue = NO;
        break;
      }
      
      NSError *subError = nil;
      BOOL success = [self executeStep:subStep error:&subError];
      
      if (!success) {
        NSNumber *optional = subStep[@"optional"];
        if (optional && optional.boolValue) continue;
        *error = subError;
        return NO;
      }
    }
    
    [NSThread sleepForTimeInterval:interval];
  }
  
  return YES;
}

- (BOOL)executeRepeat:(NSDictionary *)step error:(NSError **)error
{
  NSNumber *times = step[@"times"];
  NSArray *doSteps = step[@"do"];
  
  if (!times) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:30
                             userInfo:@{NSLocalizedDescriptionKey: @"'times' required for repeat action"}];
    return NO;
  }
  
  if (!doSteps || ![doSteps isKindOfClass:[NSArray class]]) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:29
                             userInfo:@{NSLocalizedDescriptionKey: @"'do' steps array required for repeat action"}];
    return NO;
  }
  
  for (NSInteger i = 0; i < times.integerValue; i++) {
    if (self.shouldBreak) {
      self.shouldBreak = NO;
      break;
    }
    
    self.variables[@"_index"] = @(i);
    self.variables[@"_iteration"] = @(i + 1);
    
    for (NSDictionary *subStep in doSteps) {
      if (![subStep isKindOfClass:[NSDictionary class]]) continue;
      if (self.shouldBreak) break;
      if (self.shouldContinue) {
        self.shouldContinue = NO;
        break;
      }
      
      NSError *subError = nil;
      BOOL success = [self executeStep:subStep error:&subError];
      
      if (!success) {
        NSNumber *optional = subStep[@"optional"];
        if (optional && optional.boolValue) continue;
        *error = subError;
        return NO;
      }
    }
  }
  
  return YES;
}

- (BOOL)executeForEach:(NSDictionary *)step error:(NSError **)error
{
  NSString *itemsKey = step[@"items"];
  NSString *itemVar = step[@"as"] ?: @"item";
  NSString *indexVar = step[@"indexAs"] ?: @"index";
  NSArray *doSteps = step[@"do"];
  
  if (!itemsKey || !doSteps) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:31
                             userInfo:@{NSLocalizedDescriptionKey: @"'items' and 'do' required for forEach"}];
    return NO;
  }
  
  id items = self.variables[itemsKey];
  if (![items isKindOfClass:[NSArray class]]) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:32
                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Variable '%@' is not an array", itemsKey]}];
    return NO;
  }
  
  NSArray *itemsArray = (NSArray *)items;
  
  for (NSInteger i = 0; i < itemsArray.count; i++) {
    if (self.shouldBreak) {
      self.shouldBreak = NO;
      break;
    }
    
    id item = itemsArray[i];
    self.variables[itemVar] = item;
    self.variables[indexVar] = @(i);
    
    // If item is a dictionary, spread its values as variables
    if ([item isKindOfClass:[NSDictionary class]]) {
      NSDictionary *itemDict = (NSDictionary *)item;
      for (NSString *key in itemDict) {
        self.variables[[NSString stringWithFormat:@"%@_%@", itemVar, key]] = itemDict[key];
      }
    }
    
    for (NSDictionary *subStep in doSteps) {
      if (![subStep isKindOfClass:[NSDictionary class]]) continue;
      if (self.shouldBreak) break;
      if (self.shouldContinue) {
        self.shouldContinue = NO;
        break;
      }
      
      NSError *subError = nil;
      BOOL success = [self executeStep:subStep error:&subError];
      
      if (!success) {
        NSNumber *optional = subStep[@"optional"];
        if (optional && optional.boolValue) continue;
        *error = subError;
        return NO;
      }
    }
  }
  
  return YES;
}

- (BOOL)executeTry:(NSDictionary *)step error:(NSError **)error
{
  NSArray *trySteps = step[@"try"] ?: step[@"do"];
  NSArray *catchSteps = step[@"catch"];
  NSArray *finallySteps = step[@"finally"];
  
  if (!trySteps) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:33
                             userInfo:@{NSLocalizedDescriptionKey: @"'try' or 'do' required for try action"}];
    return NO;
  }
  
  BOOL trySucceeded = YES;
  NSError *tryError = nil;
  
  // Execute try block
  for (NSDictionary *subStep in trySteps) {
    if (![subStep isKindOfClass:[NSDictionary class]]) continue;
    
    NSError *subError = nil;
    BOOL success = [self executeStep:subStep error:&subError];
    
    if (!success) {
      trySucceeded = NO;
      tryError = subError;
      self.variables[@"_error"] = subError.localizedDescription;
      break;
    }
  }
  
  // Execute catch block if try failed
  if (!trySucceeded && catchSteps && [catchSteps isKindOfClass:[NSArray class]]) {
    for (NSDictionary *subStep in catchSteps) {
      if (![subStep isKindOfClass:[NSDictionary class]]) continue;
      
      NSError *subError = nil;
      [self executeStep:subStep error:&subError];
      // Ignore errors in catch block
    }
  }
  
  // Execute finally block always
  if (finallySteps && [finallySteps isKindOfClass:[NSArray class]]) {
    for (NSDictionary *subStep in finallySteps) {
      if (![subStep isKindOfClass:[NSDictionary class]]) continue;
      
      NSError *subError = nil;
      [self executeStep:subStep error:&subError];
      // Ignore errors in finally block
    }
  }
  
  // Try/catch doesn't propagate errors by default
  NSNumber *propagateError = step[@"propagateError"];
  if (propagateError && propagateError.boolValue && !trySucceeded) {
    *error = tryError;
    return NO;
  }
  
  return YES;
}

- (BOOL)executeReturn:(NSDictionary *)step error:(NSError **)error
{
  // Set return value if provided
  id value = step[@"value"];
  if (value) {
    self.results[@"_returnValue"] = [value isKindOfClass:[NSString class]] ? value : [value description];
  }
  
  // Set break flag to exit current execution
  self.shouldBreak = YES;
  return YES;
}

#pragma mark - Assertions

- (BOOL)executeAssert:(NSDictionary *)step error:(NSError **)error
{
  NSString *message = step[@"message"] ?: @"Assertion failed";
  
  BOOL conditionMet = [self evaluateCondition:step];
  
  if (!conditionMet) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:34
                             userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
  }
  
  return YES;
}

- (BOOL)executeAssertExists:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *message = step[@"message"] ?: [NSString stringWithFormat:@"Element '%@' does not exist", selector];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 5.0;
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (element && element.exists) {
      return YES;
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:35
                           userInfo:@{NSLocalizedDescriptionKey: message}];
  return NO;
}

- (BOOL)executeAssertNotExists:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *message = step[@"message"] ?: [NSString stringWithFormat:@"Element '%@' exists but should not", selector];
  
  XCUIApplication *app = [self getTargetApp];
  XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
  
  if (element && element.exists) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:36
                             userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
  }
  
  return YES;
}

- (BOOL)executeAssertText:(NSDictionary *)step error:(NSError **)error
{
  NSString *selector = step[@"selector"];
  NSString *selectorType = step[@"selectorType"];
  NSString *expected = step[@"expected"];
  NSString *contains = step[@"contains"];
  NSString *message = step[@"message"];
  NSTimeInterval timeout = [step[@"timeout"] doubleValue] ?: 5.0;
  
  if (!selector || (!expected && !contains)) {
    *error = [NSError errorWithDomain:@"FBScriptExecutor" code:37
                             userInfo:@{NSLocalizedDescriptionKey: @"'selector' and ('expected' or 'contains') required for assertText"}];
    return NO;
  }
  
  XCUIApplication *app = [self getTargetApp];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    XCUIElement *element = [self findElementWithSelector:selector selectorType:selectorType inApp:app];
    if (element && element.exists) {
      NSString *actualText = element.label ?: [element valueForKey:@"value"] ?: @"";
      
      if (expected && [actualText isEqualToString:expected]) {
        return YES;
      }
      
      if (contains && [actualText containsString:contains]) {
        return YES;
      }
    }
    [NSThread sleepForTimeInterval:0.1];
  }
  
  if (!message) {
    if (expected) {
      message = [NSString stringWithFormat:@"Element text does not equal '%@'", expected];
    } else {
      message = [NSString stringWithFormat:@"Element text does not contain '%@'", contains];
    }
  }
  
  *error = [NSError errorWithDomain:@"FBScriptExecutor" code:38
                           userInfo:@{NSLocalizedDescriptionKey: message}];
  return NO;
}

#pragma mark - Vision/OCR Actions

#if !TARGET_OS_TV

- (UIImage *)captureScreenshot
{
  XCUIScreenshot *screenshot = XCUIScreen.mainScreen.screenshot;
  return screenshot.image;
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
  
  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
  
  NSError *performError = nil;
  [handler performRequests:@[request] error:&performError];
  
  dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
  
  return foundPoint;
}

- (NSArray<NSDictionary *> *)findAllTextInImage:(UIImage *)image
{
  __block NSMutableArray *results = [NSMutableArray array];
  
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  
  VNRecognizeTextRequest *request 