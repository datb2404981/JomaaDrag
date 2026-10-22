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

// Every event injection and cursor write is intercepted. No app is launched.
#define CGEventPost recordEvent
#define CGWarpMouseCursorPosition ignoreWarp
#define CGAssociateMouseAndMouseCursorPosition ignoreAssociation
#define CGEventSourceCreate privateEventSource
#define clock_gettime simulatedClock
#define main jomaaApplicationMain
#include "../src/main.m"
#undef main
#undef clock_gettime
#undef CGEventSourceCreate
#undef CGAssociateMouseAndMouseCursorPosition
#undef CGWarpMouseCursorPosition
#undef CGEventPost

typedef struct {
    CGEventType type;
    int64_t phase;
    int64_t momentum;
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
        CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase)
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

static void resetFixture(void) {
    stopDrag("test reset");
    eventCount = 0;
    atomic_store(&fakeTime, 1000.0);
    atomic_store(&stopRequested, 0);
    atomic_store(&eventPipelineReady, 1);
    atomic_store(&engineSuspended, 0);
    atomic_store(&sensitivityMultiplier, 1.0);
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
        testIdempotentShutdown();
        puts("PASS: 10 gesture/lifecycle regression scenarios (no system input injected)");
    }
    return 0;
}
