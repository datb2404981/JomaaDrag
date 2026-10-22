#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

static _Atomic double fakeTime = 1000.0;
static void recordEvent(CGEventTapLocation location, CGEventRef event);
static CGError ignoreWarp(CGPoint point);
static CGError ignoreAssociation(boolean_t connected);
static CGEventSourceRef privateEventSource(CGEventSourceStateID state);
static int simulatedClock(clockid_t clock, struct timespec *ts);
static CGEventFlags simulatedFlags(CGEventSourceStateID state);
static CGEventFlags heldFlags;

// Every event injection and cursor write is intercepted. No app is launched.
#define CGEventPost recordEvent
#define CGWarpMouseCursorPosition ignoreWarp
#define CGAssociateMouseAndMouseCursorPosition ignoreAssociation
#define CGEventSourceCreate privateEventSource
#define clock_gettime simulatedClock
#define CGEventSourceFlagsState simulatedFlags
#define main jomaaApplicationMain
#include "../src/main.m"
#undef main
#undef clock_gettime
#undef CGEventSourceFlagsState
#undef CGEventSourceCreate
#undef CGAssociateMouseAndMouseCursorPosition
#undef CGWarpMouseCursorPosition
#undef CGEventPost

typedef struct {
    CGEventType type;
    int64_t phase;
    int64_t momentum;
    int64_t key;
    CGEventFlags flags;
    int64_t x, y;
    CGEventTapLocation location;
} RecordedEvent;
static RecordedEvent events[8192];
static size_t eventCount;
static MTDeviceRef fakeDevice = (MTDeviceRef)0x1234;

static void recordEvent(CGEventTapLocation location, CGEventRef event) {
    (void)location;
    int lockResult = pthread_mutex_trylock(&mu);
    if (lockResult == 0) pthread_mutex_unlock(&mu);
    assert(lockResult == EBUSY); // All event output must be serialized.
    assert(eventCount < sizeof(events) / sizeof(events[0]));
    events[eventCount++] = (RecordedEvent){
        CGEventGetType(event),
        CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase),
        CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase),
        CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode),
        CGEventGetFlags(event),
        CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2),
        CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1),
        location
    };
}

static CGError ignoreWarp(CGPoint point) { (void)point; return kCGErrorSuccess; }
static CGError ignoreAssociation(boolean_t connected) { (void)connected; return kCGErrorSuccess; }
static CGEventSourceRef privateEventSource(CGEventSourceStateID state) {
    (void)state;
    return CGEventSourceCreate(kCGEventSourceStatePrivate);
}
static int simulatedClock(clockid_t clock, struct timespec *ts) {
    (void)clock;
    double seconds = atomic_load(&fakeTime) / 1000.0;
    ts->tv_sec = (time_t)seconds;
    ts->tv_nsec = (long)((seconds - ts->tv_sec) * 1e9);
    return 0;
}
static CGEventFlags simulatedFlags(CGEventSourceStateID state) {
    (void)state;
    return heldFlags;
}

static void resetFixture(void) {
    stopDrag("test reset");
    eventCount = 0;
    atomic_store(&fakeTime, 1000.0);
    atomic_store(&stopRequested, 0);
    atomic_store(&eventPipelineReady, 1);
    atomic_store(&engineSuspended, 0);
    atomic_store(&userPaused, 0);
    atomic_store(&sensitivityMultiplier, 1.0);
    atomic_store(&naturalScrollingSetting, 1);
    inertiaEnabled = 1;
    fourFingerGesturesEnabled = 0;
    heldFlags = 0;
    for (int i = 0; i < 4; i++) {
        const CGKeyCode keys[4] = {123, 124, 126, 125};
        workspaceShortcuts[i] = (WorkspaceShortcut){keys[i], kCGEventFlagMaskControl | kCGEventFlagMaskSecondaryFn, 1};
    }
    terminationRequested = 0;
    acceptingTouches = 1;
    connectedDeviceRef = fakeDevice;
}

static void makeTouches(MTTouch *touches, int count, double offset) {
    memset(touches, 0, sizeof(MTTouch) * count);
    for (int i = 0; i < count; i++) {
        touches[i].identifier = i + 1;
        touches[i].state = 4;
        touches[i].normalized.pos.x = 0.2 + i * 0.2 + offset;
        touches[i].normalized.pos.y = 0.5;
    }
}

static void sendTouches(MTTouch *touches, int count, double milliseconds) {
    atomic_store(&fakeTime, milliseconds);
    touchCallback(fakeDevice, touches, count, 0.0, 0);
}

static void startDrag(MTTouch *touches) {
    makeTouches(touches, 3, 0.0);
    sendTouches(touches, 3, 1000.0);
    makeTouches(touches, 3, 0.001);
    sendTouches(touches, 3, 1010.0);
    assert(atomic_load(&dragging));
    assert(eventCount == 2 && events[0].type == kCGEventLeftMouseDown);
}

static void verifyMouseOrder(void) {
    int down = 0;
    for (size_t i = 0; i < eventCount; i++) {
        if (events[i].type == kCGEventLeftMouseDown) {
            assert(!down);
            down = 1;
        } else if (events[i].type == kCGEventLeftMouseDragged) {
            assert(down);
        } else if (events[i].type == kCGEventLeftMouseUp) {
            assert(down);
            down = 0;
        }
    }
    assert(!down);
}

static void testFingerReplacementAndDropout(void) {
    resetFixture();
    MTTouch touches[3];
    startDrag(touches);
    // A new third finger changes the centroid without moving the other fingers.
    touches[2].identifier = 99;
    touches[2].normalized.pos.x = 0.85;
    sendTouches(touches, 3, 1020.0);
    assert(fabs(dragTargetDx) < 1e-6 && fabs(dragTargetDy) < 1e-6);
    // Keep moving with two recognized fingers: no dropped movement on 3 -> 2.
    touches[0].normalized.pos.x += 0.001;
    touches[1].normalized.pos.x += 0.001;
    sendTouches(touches, 2, 1030.0);
    assert(dragTargetDx > 2.0 && dragTargetDx < 4.0);
    stopDrag("test end");
    verifyMouseOrder();
}

static void testNoFalseDragOnChangedIdentifiers(void) {
    resetFixture();
    MTTouch touches[3];
    makeTouches(touches, 3, 0.0);
    sendTouches(touches, 3, 1000.0);
    for (int i = 0; i < 3; i++) {
        touches[i].identifier += 10;
        touches[i].normalized.pos.x += 0.04;
    }
    sendTouches(touches, 3, 1010.0);
    sendTouches(touches, 3, 1020.0);
    assert(!atomic_load(&dragging) && eventCount == 0);
}

static void testLiftReleasesAndFlushesMovement(void) {
    resetFixture();
    MTTouch touches[3];
    startDrag(touches);
    makeTouches(touches, 3, 0.004);
    sendTouches(touches, 3, 1020.0);
    assert(dragTargetDx > 0.0);
    sendTouches(NULL, 0, 1025.0);
    atomic_store(&fakeTime, 1040.0);
    tick(NULL, NULL);
    assert(atomic_load(&dragging));
    atomic_store(&fakeTime, 1070.0);
    tick(NULL, NULL);
    assert(!atomic_load(&dragging));
    assert(events[eventCount - 1].type == kCGEventLeftMouseUp);
    assert(events[eventCount - 2].type == kCGEventLeftMouseDragged);
    size_t afterRelease = eventCount;
    atomic_store(&fakeTime, 2000.0);
    tick(NULL, NULL);
    assert(afterRelease == eventCount);
    verifyMouseOrder();
}

static void testSingleFingerReleaseWithoutMoreFrames(void) {
    resetFixture();
    MTTouch touches[3];
    startDrag(touches);
    sendTouches(touches, 1, 1020.0);
    atomic_store(&fakeTime, 1070.0);
    tick(NULL, NULL);
    assert(!atomic_load(&dragging));
    verifyMouseOrder();
}

static void testScrollAndZoomResetWithoutDrag(void) {
    resetFixture();
    mosPhaseState = 1;
    mosTouchContactActive = 1;
    mosTargetBufferX = 20.0;
    mosVelocityPerTickY = 12.0;
    zoomPhaseState = 1;
    zoomTouchContactActive = 1;
    zoomTargetBuffer = 0.1;
    twoFingerMode = 2;
    stopDrag("disconnect during scrolling");
    assert(mosPhaseState == 0 && zoomPhaseState == 0 && twoFingerMode == 0);
    assert(!mosTouchContactActive && !zoomTouchContactActive);
    assert(mosTargetBufferX == 0.0 && mosVelocityPerTickY == 0.0 && zoomTargetBuffer == 0.0);
    assert(eventCount == 2);
    assert(events[0].type == kCGEventScrollWheel && events[0].phase == kCGScrollPhaseCancelled);
    size_t closedCount = eventCount;
    stopDrag("repeat stop");
    tick(NULL, NULL);
    assert(eventCount == closedCount);
}

static void lateUnregister(MTDeviceRef device, MTContactCallback callback) {
    MTTouch touches[3];
    makeTouches(touches, 3, 0.01);
    callback(device, touches, 3, 0, 0); // In-flight callback during disconnect.
}
static int fakeStop(MTDeviceRef device) { (void)device; return 0; }

static void testDetachIgnoresLateFrames(void) {
    resetFixture();
    MTTouch touches[3];
    startDrag(touches);
    MTUnregisterContactFrameCallback = lateUnregister;
    MTDeviceStop = fakeStop;
    detachAndResetTrackpad();
    size_t afterDetach = eventCount;
    sendTouches(touches, 3, 1030.0);
    assert(eventCount == afterDetach && prevCount == 0 && !acceptingTouches);
    verifyMouseOrder();
}

static void testInvalidInputAndPermissionGate(void) {
    resetFixture();
    MTTouch touches[3];
    makeTouches(touches, 3, 0.0);
    atomic_store(&eventPipelineReady, 0);
    sendTouches(touches, 3, 1000.0);
    assert(prevCount == 0 && !atomic_load(&multiTouchActive));
    atomic_store(&eventPipelineReady, 1);
    touches[0].normalized.pos.x = NAN;
    touches[1].normalized.pos.y = INFINITY;
    sendTouches(touches, 3, 1010.0);
    assert(prevCount == 1);
    touchCallback(fakeDevice, NULL, 3, 0, 0);
    touchCallback(fakeDevice, touches, -1, 0, 0);
    assert(eventCount == 0);
    MTDeviceCreateList = NULL;
    checkAndAttachTrackpad(); // Missing private APIs must be handled safely.
}

static void testSleepBlocksInputAndPolling(void) {
    resetFixture();
    MTTouch touches[3];
    startDrag(touches);
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [delegate onWillSleep:nil];
    assert(atomic_load(&engineSuspended) && !acceptingTouches && !atomic_load(&dragging));
    size_t afterSleep = eventCount;
    [delegate onPollTimer];
    sendTouches(touches, 3, 1040.0);
    tick(NULL, NULL);
    assert(eventCount == afterSleep && !acceptingTouches);
    verifyMouseOrder();
}

static void *feedTouchFrames(void *context) {
    (void)context;
    MTTouch touches[3];
    for (int i = 0; i < 1200; i++) {
        makeTouches(touches, 3, (i % 20) * 0.001);
        sendTouches(touches, 3, 1000.0 + i * 10.0);
    }
    return NULL;
}
static void *feedTimerTicks(void *context) {
    (void)context;
    for (int i = 0; i < 2400; i++) tick(NULL, NULL);
    return NULL;
}

static void testConcurrentEventOrdering(void) {
    resetFixture();
    pthread_t input, ticker;
    assert(pthread_create(&input, NULL, feedTouchFrames, NULL) == 0);
    assert(pthread_create(&ticker, NULL, feedTimerTicks, NULL) == 0);
    pthread_join(input, NULL);
    pthread_join(ticker, NULL);
    stopDrag("end concurrent simulation");
    verifyMouseOrder();
}

static void testIdempotentShutdown(void) {
    resetFixture();
    MTTouch touches[3];
    startDrag(touches);
    shutdownEngine();
    size_t afterShutdown = eventCount;
    assert(!hidEventSource && !connectedDeviceRef && !acceptingTouches);
    assert(atomic_load(&stopRequested) && !atomic_load(&eventPipelineReady));
    shutdownEngine();
    sendTouches(touches, 3, 1040.0);
    assert(afterShutdown == eventCount);
    verifyMouseOrder();
}

static void startScroll(MTTouch *touches, int horizontal) {
    makeTouches(touches, 2, 0.0);
    sendTouches(touches, 2, 1000.0);
    for (int frame = 1; frame <= 2; frame++) {
        for (int i = 0; i < 2; i++) {
            if (horizontal) touches[i].normalized.pos.x += 0.008;
            else touches[i].normalized.pos.y += 0.008;
        }
        sendTouches(touches, 2, 1000.0 + frame * 10.0);
    }
    tick(NULL, NULL);
    assert(twoFingerMode == 1 && mosPhaseState == 1);
}

static void launchFling(void) {
    sendTouches(NULL, 0, 1025.0);
    atomic_store(&fakeTime, 1060.0);
    tick(NULL, NULL);
}

static void testMomentumBrakeOnStationaryContact(void) {
    resetFixture();
    MTTouch touches[2];
    startScroll(touches, 0);
    launchFling();
    assert(mosPhaseState == 2);
    size_t beforeBrake = eventCount;
    makeTouches(touches, 1, 0.0);
    sendTouches(touches, 1, 1065.0);
    assert(mosPhaseState == 0 && mosVelocityPerTickY == 0.0);
    assert(eventCount == beforeBrake + 1);
    assert(events[eventCount - 1].momentum == kCGMomentumScrollPhaseEnd);
    atomic_store(&fakeTime, 1070.0);
    tick(NULL, NULL);
    assert(eventCount == beforeBrake + 1);
}

static void testAllUpDoesNotBrakeMomentum(void) {
    resetFixture();
    MTTouch touches[2];
    startScroll(touches, 0);
    launchFling();
    assert(mosPhaseState == 2);
    size_t before = eventCount;
    sendTouches(NULL, 0, 1065.0);
    tick(NULL, NULL);
    assert(mosPhaseState == 2 && eventCount > before);
    assert(events[eventCount - 1].momentum == kCGMomentumScrollPhaseContinue);
    // A report after a lost all-up frame must also brake immediately.
    prevCount = 2;
    sendTouches(touches, 1, 1070.0);
    assert(mosPhaseState == 0);
}

static void testInertiaDisabledStillScrolls(void) {
    resetFixture();
    inertiaEnabled = 0;
    MTTouch touches[2];
    startScroll(touches, 0);
    assert(events[0].phase == kCGScrollPhaseBegan && events[0].y != 0);
    launchFling();
    assert(mosPhaseState == 0 && mosVelocityPerTickY == 0.0);
    for (size_t i = 0; i < eventCount; i++) assert(events[i].momentum == 0);
    assert(events[eventCount - 1].phase == kCGScrollPhaseEnded);
}

static void testRestingFingersDoNotLaunchStaleVelocity(void) {
    resetFixture();
    MTTouch touches[2];
    startScroll(touches, 0);
    for (int frame = 1; frame <= 20; frame++) {
        sendTouches(touches, 2, 1020.0 + frame * 10.0);
        tick(NULL, NULL);
    }
    sendTouches(NULL, 0, 1225.0);
    atomic_store(&fakeTime, 1260.0);
    tick(NULL, NULL);
    assert(mosPhaseState == 0);
    for (size_t i = 0; i < eventCount; i++) assert(events[i].momentum == 0);
}

static void testFourFingerDirectionsAndOneShot(void) {
    const double deltas[4][2] = {{0.06, 0}, {-0.06, 0}, {0, 0.06}, {0, -0.06}};
    const int keys[4] = {123, 124, 126, 125};
    for (int direction = 0; direction < 4; direction++) {
        resetFixture();
        fourFingerGesturesEnabled = 1;
        heldFlags = kCGEventFlagMaskCommand | kCGEventFlagMaskShift | kCGEventFlagMaskAlternate;
        MTTouch touches[4];
        makeTouches(touches, 4, 0);
        sendTouches(touches, 4, 1000.0);
        for (int i = 0; i < 4; i++) {
            touches[i].normalized.pos.x += deltas[direction][0];
            touches[i].normalized.pos.y += deltas[direction][1];
        }
        sendTouches(touches, 4, 1010.0);
        assert(eventCount == 2 && !atomic_load(&dragging));
        assert(events[0].type == kCGEventKeyDown && events[1].type == kCGEventKeyUp);
        assert(events[0].key == keys[direction] && events[1].key == keys[direction]);
        assert(events[0].flags == (kCGEventFlagMaskControl | kCGEventFlagMaskSecondaryFn));
        assert(events[0].location == kCGHIDEventTap && events[1].location == kCGHIDEventTap);
        sendTouches(touches, 4, 1020.0);
        sendTouches(touches, 3, 1030.0);
        for (int i = 0; i < 3; i++) touches[i].normalized.pos.x += 0.002;
        sendTouches(touches, 3, 1040.0);
        assert(eventCount == 2 && !atomic_load(&dragging));
        sendTouches(touches, 1, 1050.0);
        sendTouches(NULL, 0, 1060.0);
        assert(!fourFingerClaimed && !atomic_load(&multiTouchActive));
    }
}

static void testFourFingerRejectsJitterAndReplacement(void) {
    resetFixture();
    fourFingerGesturesEnabled = 1;
    MTTouch touches[4];
    makeTouches(touches, 4, 0);
    sendTouches(touches, 4, 1000.0);
    for (int i = 0; i < 4; i++) touches[i].normalized.pos.x += 0.002;
    sendTouches(touches, 4, 1010.0);
    touches[3].identifier = 90;
    touches[3].normalized.pos.x += 0.08;
    sendTouches(touches, 4, 1020.0);
    assert(eventCount == 0 && fabs(fourFingerDx) < 0.005);
    for (int i = 0; i < 4; i++) {
        touches[i].normalized.pos.x += 0.06;
        touches[i].normalized.pos.y += 0.06;
    }
    sendTouches(touches, 4, 1030.0);
    assert(eventCount == 0 && !atomic_load(&dragging));
    // Missing lift must eventually clear the recognizer.
    atomic_store(&fakeTime, 1500.0);
    tick(NULL, NULL);
    assert(!fourFingerClaimed && prevCount == 0);
}

static void testFourFingerPreservesDragAndDefault(void) {
    resetFixture();
    MTTouch touches[4];
    makeTouches(touches, 4, 0);
    sendTouches(touches, 4, 1000.0);
    makeTouches(touches, 4, 0.002);
    sendTouches(touches, 4, 1010.0);
    assert(atomic_load(&dragging) && !fourFingerClaimed);
    stopDrag("default four fingers still drag");
    verifyMouseOrder();
    resetFixture();
    fourFingerGesturesEnabled = 1;
    makeTouches(touches, 3, 0);
    sendTouches(touches, 3, 1000.0);
    makeTouches(touches, 3, 0.001);
    sendTouches(touches, 3, 1070.0);
    assert(atomic_load(&dragging));
    makeTouches(touches, 4, 0.001);
    sendTouches(touches, 4, 1080.0);
    assert(atomic_load(&dragging) && !fourFingerClaimed);
    stopDrag("fourth finger must not steal existing drag");
    verifyMouseOrder();
}

static void testPauseClosesGesturesAndPassesPhysicalInput(void) {
    resetFixture();
    MTTouch touches[3];
    startDrag(touches);
    setUserPaused(1);
    assert(!atomic_load(&dragging) && !acceptingTouches && atomic_load(&userPaused));
    verifyMouseOrder();
    size_t afterPause = eventCount;
    sendTouches(touches, 3, 1030.0);
    tick(NULL, NULL);
    assert(eventCount == afterPause);
    CGEventRef physical = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 2, 10, 0, 0);
    CGEventSetIntegerValueField(physical, kCGScrollWheelEventIsContinuous, 1);
    atomic_store(&multiTouchActive, 1);
    atomic_store(&lastMultiTouchT, nowMs());
    assert(mouseEventTap(NULL, kCGEventScrollWheel, physical, NULL) == physical);
    CFRelease(physical);
    setUserPaused(0);
    assert(!atomic_load(&userPaused) && !acceptingTouches);
    // Resume requires a fresh attachment, rather than stale touch history.
    acceptingTouches = 1;
    connectedDeviceRef = fakeDevice;
    sendTouches(touches, 3, 1040.0);
    assert(!atomic_load(&dragging));
    touches[0].normalized.pos.x += 0.002;
    touches[1].normalized.pos.x += 0.002;
    touches[2].normalized.pos.x += 0.002;
    sendTouches(touches, 3, 1050.0);
    assert(atomic_load(&dragging));
    stopDrag("resume complete");
    verifyMouseOrder();
}

static void testExistingScrollZoomAndMousePassthrough(void) {
    resetFixture();
    heldFlags = kCGEventFlagMaskAlternate;
    MTTouch touches[2];
    startScroll(touches, 1);
    assert(mosDashMomentum && events[0].x != 0 && events[0].y == 0);
    stopDrag("close browser swipe");
    assert(!mosHorizontalSwipeActive);
    resetFixture();
    makeTouches(touches, 2, 0);
    sendTouches(touches, 2, 1000.0);
    touches[0].normalized.pos.x -= 0.008;
    touches[1].normalized.pos.x += 0.008;
    sendTouches(touches, 2, 1010.0);
    tick(NULL, NULL);
    assert(twoFingerMode == 2 && zoomPhaseState == 1 && events[0].type == (CGEventType)29);
    CGEventRef mouseWheel = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitLine, 1, 1, 0, 0);
    assert(CGEventGetIntegerValueField(mouseWheel, kCGScrollWheelEventIsContinuous) == 0);
    assert(mouseEventTap(NULL, kCGEventScrollWheel, mouseWheel, NULL) == mouseWheel);
    CFRelease(mouseWheel);
    stopDrag("close pinch");
    assert(zoomPhaseState == 0);
}

static void testStaggeredFourFingerLandingDoesNotStartDrag(void) {
    resetFixture();
    fourFingerGesturesEnabled = 1;
    MTTouch touches[4];
    makeTouches(touches, 3, 0);
    sendTouches(touches, 3, 1000.0);
    makeTouches(touches, 3, 0.002);
    sendTouches(touches, 3, 1010.0);
    assert(!atomic_load(&dragging) && eventCount == 0);
    makeTouches(touches, 4, 0.002);
    sendTouches(touches, 4, 1020.0);
    makeTouches(touches, 4, 0.062);
    sendTouches(touches, 4, 1030.0);
    assert(fourFingerFired && !atomic_load(&dragging));
    assert(eventCount == 2 && events[0].type == kCGEventKeyDown);
    sendTouches(NULL, 0, 1040.0);
    assert(!dragArmed && !fourFingerClaimed);
}

static void testConfiguredWorkspaceShortcuts(void) {
    resetFixture();
    // These include the Fn flag present in the user's actual macOS mappings.
    NSDictionary *settings = @{
        @"32": @{@"enabled": @YES, @"value": @{@"parameters": @[@65535, @126, @8650752]}},
        @"79": @{@"enabled": @NO, @"value": @{@"parameters": @[@65535, @123, @8650752]}},
        @"81": @{@"enabled": @YES, @"value": @{@"parameters": @[@65535, @20, @1179648]}}
    };
    WorkspaceShortcut up = parseWorkspaceShortcut(settings, @"32", 126);
    assert(up.enabled && up.key == 126 && up.flags == 8650752);
    WorkspaceShortcut left = parseWorkspaceShortcut(settings, @"79", 123);
    assert(!left.enabled);
    WorkspaceShortcut right = parseWorkspaceShortcut(settings, @"81", 124);
    assert(right.enabled && right.key == 20 && right.flags == 1179648);
    WorkspaceShortcut defaults = parseWorkspaceShortcut(settings, @"33", 125);
    assert(defaults.enabled && defaults.key == 125 && defaults.flags == 8650752);
    pthread_mutex_lock(&mu);
    workspaceShortcuts[0] = left;
    workspaceShortcuts[1] = right;
    assert(!emitWorkspaceShortcut(0) && eventCount == 0);
    assert(emitWorkspaceShortcut(1) && eventCount == 2);
    pthread_mutex_unlock(&mu);
    assert(events[0].key == 20 && events[1].key == 20);
    assert(events[0].flags == 1179648 && events[1].flags == 1179648);
    NSDictionary *malformed[] = {
        @{@"32": @"invalid"},
        @{@"32": @{@"value": @"invalid"}},
        @{@"32": @{@"value": @{@"parameters": @[@1, @2]}}},
        @{@"32": @{@"value": @{@"parameters": @[@65535, @65535, @0]}}}
    };
    for (int i = 0; i < 4; i++) assert(!parseWorkspaceShortcut(malformed[i], @"32", 126).enabled);
}

static void testFourFingerBriefDropout(void) {
    resetFixture();
    fourFingerGesturesEnabled = 1;
    MTTouch touches[4];
    makeTouches(touches, 4, 0);
    sendTouches(touches, 4, 1000.0);
    // Observed hardware pattern: four contacts appear briefly, then one
    // reports state 7 while the other three keep moving.
    for (int i=0;i<3;i++) touches[i].normalized.pos.x += 0.03;
    touches[3].state=7;
    sendTouches(touches, 4, 1030.0);
    assert(fourFingerClaimed && !fourFingerFired && eventCount == 0);
    for (int i=0;i<3;i++) touches[i].normalized.pos.x += 0.03;
    sendTouches(touches, 4, 1060.0);
    assert(fourFingerFired && !atomic_load(&dragging));
    assert(eventCount == 2 && events[0].key == 123);
    sendTouches(touches, 3, 1090.0);
    assert(eventCount == 2);
    sendTouches(NULL, 0, 1100.0);
    assert(!fourFingerClaimed);
}

static void testFourFingerDropoutExpiry(void) {
    resetFixture();
    fourFingerGesturesEnabled=1;
    MTTouch touches[4];
    makeTouches(touches,4,0);
    sendTouches(touches,4,1000.0);
    makeTouches(touches,3,0.06);
    sendTouches(touches,3,1200.0);
    assert(eventCount == 0 && fourFingerClaimed && !fourFingerFired);
    makeTouches(touches,3,0.12);
    sendTouches(touches,3,1230.0);
    assert(eventCount == 0 && !atomic_load(&dragging));
    sendTouches(NULL,0,1240.0);
}

static void testFourthContactWithInvalidCoordinate(void) {
    resetFixture();
    fourFingerGesturesEnabled=1;
    MTTouch touches[4];
    makeTouches(touches,4,0);
    touches[3].normalized.pos.x=NAN;
    sendTouches(touches,4,1000.0);
    assert(fourFingerClaimed && prevCount == 3);
    for (int i=0;i<3;i++) touches[i].normalized.pos.x += 0.06;
    sendTouches(touches,4,1030.0);
    assert(eventCount == 2 && events[0].key == 123);
    sendTouches(NULL,0,1040.0);
    resetFixture();
    fourFingerGesturesEnabled=1;
    makeTouches(touches,3,0);
    touches[2].normalized.pos.x=NAN;
    sendTouches(touches,3,1000.0);
    for (int i=0;i<2;i++) touches[i].normalized.pos.x += 0.06;
    sendTouches(touches,3,1030.0);
    assert(!fourFingerClaimed);
    for (size_t i=0;i<eventCount;i++) assert(events[i].type != kCGEventKeyDown);
}

int main(void) {
    @autoreleasepool {
        testFingerReplacementAndDropout();
        testNoFalseDragOnChangedIdentifiers();
        testLiftReleasesAndFlushesMovement();
        testSingleFingerReleaseWithoutMoreFrames();
        testScrollAndZoomResetWithoutDrag();
        testDetachIgnoresLateFrames();
        testInvalidInputAndPermissionGate();
        testSleepBlocksInputAndPolling();
        testConcurrentEventOrdering();
        testMomentumBrakeOnStationaryContact();
        testAllUpDoesNotBrakeMomentum();
        testInertiaDisabledStillScrolls();
        testRestingFingersDoNotLaunchStaleVelocity();
        testFourFingerDirectionsAndOneShot();
        testFourFingerRejectsJitterAndReplacement();
        testFourFingerPreservesDragAndDefault();
        testPauseClosesGesturesAndPassesPhysicalInput();
        testExistingScrollZoomAndMousePassthrough();
        testStaggeredFourFingerLandingDoesNotStartDrag();
        testConfiguredWorkspaceShortcuts();
        testFourFingerBriefDropout();
        testFourFingerDropoutExpiry();
        testFourthContactWithInvalidCoordinate();
        testIdempotentShutdown();
        puts("PASS: 24 gesture/lifecycle regression scenarios (no system input injected)");
    }
    return 0;
}
