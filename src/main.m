#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <math.h>
#import <pthread.h>
#import <signal.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stdint.h>
#import <unistd.h>
#import <time.h>

// Private MultitouchSupport.framework API
typedef void *MTDeviceRef;
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int fingerId;
    int handId;
    MTVector normalized;
    float size;
    int zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;
    int zero2[2];
    float unknown;
} MTTouch;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

static CFArrayRef (*MTDeviceCreateList)(void);
static void (*MTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*MTUnregisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static int (*MTDeviceStart)(MTDeviceRef, int);
static int (*MTDeviceStop)(MTDeviceRef);
static int (*MTDeviceGetDeviceID)(MTDeviceRef, uint64_t *);
static int (*MTDeviceIsBuiltIn)(MTDeviceRef);
static int (*MTDeviceIsAvailable)(MTDeviceRef);
static int (*MTDeviceIsRunning)(MTDeviceRef);

#define BUILTIN_ID 144115188075855923ULL
#define MAGIC 0x4A4D44LL // 'JMD'
#define MOS_PASS_MAGIC 0x4D4F53534D4F4F54LL // Passthrough cho Mos.app để không nuốt sự kiện vuốt Trackpad

// ĐÃ NÂNG TỐC ĐỘ KÉO 3 NGÓN TỪ 1400 LÊN 2350 (Nhanh, nhẹ và thoát tay hơn hẳn)
static const double SPEED_FACTOR = 2350.0;

// Hệ số độ nhạy động
static _Atomic double sensitivityMultiplier = 1.0;

// Trạng thái Multi-Touch: Khóa chuyển động con trỏ & cuộn thô phần cứng Jomaa
static _Atomic int multiTouchActive = 0;
static _Atomic double lastMultiTouchT = 0.0;
static _Atomic double lastAnyJomaaTouchT = 0.0;
static _Atomic int naturalScrollingSetting = 1;

// Nguồn phát sự kiện HID thống nhất giúp WindowServer khóa dính cửa sổ 100%
static CGEventSourceRef hidEventSource = NULL;
static int64_t dragEventNumber = 100;

static int readNaturalScrolling(void) {
    CFPreferencesAppSynchronize(CFSTR(".GlobalPreferences"));
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR("com.apple.swipescrolldirection"), CFSTR(".GlobalPreferences"));
    int nat = 1;
    if (val && CFGetTypeID(val) == CFBooleanGetTypeID()) {
        nat = CFBooleanGetValue((CFBooleanRef)val) ? 1 : 0;
    }
    if (val) CFRelease(val);
    return nat;
}

// Trạng thái đồng bộ
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int dragging = 0;
static _Atomic int stopRequested = 0;
static _Atomic int eventPipelineReady = 0;
static _Atomic int engineSuspended = 0;
static volatile sig_atomic_t terminationRequested = 0;
// Protected by mu. Close this gate before unregistering/stopping a device.
static int acceptingTouches = 0;

static double lastTouchT = 0.0;
static double lastDragContactT = 0.0;
static double singleFingerSinceT = 0.0;
static double singleFingerStartX = 0.0;
static double singleFingerStartY = 0.0;
static int latestPresent = 0;

// Vị trí con trỏ & Bộ đệm Nội suy Kéo 3 ngón 120Hz
static double curX = 0.0, curY = 0.0;
static double dragTargetDx = 0.0, dragTargetDy = 0.0;

#define MAX_TOUCHES 8
typedef struct {
    int identifier;
    double x, y;
    float size;
    float majorAxis;
    float minorAxis;
    int valid;
} TouchPos;
static TouchPos prevTouches[MAX_TOUCHES];
static int prevCount = 0;

// ============================================================================
// PER-FINGER ID TRACKING & MOS 120Hz 2D SCROLL + 120Hz PINCH-TO-ZOOM ENGINE
// ============================================================================
static double lastScrollFrameT = 0.0;
static double lastTwoFingerT = 0.0;

static double mosTargetBufferX = 0.0;
static double mosTargetBufferY = 0.0;
static double mosVelocityPerTickX = 0.0;
static double mosVelocityPerTickY = 0.0;
static double mosPeakVelPerTickX = 0.0;
static double mosPeakVelPerTickY = 0.0;
static double mosPeakVelTime = 0.0;
static double subpixelRemX = 0.0;
static double subpixelRemY = 0.0;
static double scrollIntentX = 0.0;
static double scrollIntentY = 0.0;
static int mosTouchContactActive = 0;
static int mosPhaseState = 0;
static int mosHorizontalSwipeActive = 0;
static int mosDashMomentum = 0; // Cờ tăng tốc quán tính khi giữ phím Option (⌥) kiểu Mos

// Trạng thái 120Hz Pinch-to-Zoom (NSEventTypeMagnify) & Bộ phân rã động học 2 ngón
static int twoFingerMode = 0; // 0 = Chưa khóa, 1 = Cuộn 2 chiều (Scroll), 2 = Phóng to/Thu nhỏ (Pinch Zoom)
static int zoomTouchContactActive = 0;
static int zoomPhaseState = 0;
static double zoomTargetBuffer = 0.0;
static int pinchStreak = 0;
static int scrollStreak = 0;

static inline double nowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static CGEventSourceRef sharedHIDSource(void) {
    if (!hidEventSource) {
        hidEventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (hidEventSource) {
            CGEventSourceSetLocalEventsSuppressionInterval(hidEventSource, 0.0);
        }
    }
    return hidEventSource;
}

static CGPoint cursorNow(void) {
    CGPoint p = CGPointZero;
    CGEventRef e = CGEventCreate(NULL);
    if (e) {
        p = CGEventGetLocation(e);
        CFRelease(e);
    }
    return p;
}

// Kiểm tra phím Option (⌥) đang được giữ để kích hoạt Dash (Cuộn siêu tốc kiểu Mos)
static inline int isOptionDashActive(void) {
    CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState);
    return ((flags & kCGEventFlagMaskAlternate) != 0 &&
            (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)) == 0) ? 1 : 0;
}

// Phát sự kiện Phóng to / Thu nhỏ (NSEventTypeMagnify = CGEventType 29, field 110 = 8) ở tần số 120Hz
static void emitMagnifyEvent(double stepMag, uint32_t phase) {
    CGEventRef gestureEvent = CGEventCreate(sharedHIDSource());
    if (!gestureEvent) return;

    CGEventSetType(gestureEvent, (CGEventType)29);
    CGEventSetIntegerValueField(gestureEvent, 110, 8);     // kIOHIDEventTypeZoom -> NSEventTypeMagnify (30)
    CGEventSetIntegerValueField(gestureEvent, 132, phase); // 1=Began, 2=Changed, 4=Ended, 8=Cancelled
    CGEventSetDoubleValueField(gestureEvent, 118, stepMag); // -[NSEvent magnification]
    CGEventSetIntegerValueField(gestureEvent, kCGEventSourceUserData, MOS_PASS_MAGIC);
    CGEventPost(kCGSessionEventTap, gestureEvent);
    CFRelease(gestureEvent);
}

static void stopZoomImmediately(int cancelPhase) {
    if (zoomPhaseState == 1) {
        emitMagnifyEvent(0.0, cancelPhase ? kCGScrollPhaseCancelled : kCGScrollPhaseEnded);
    }
    zoomPhaseState = 0;
    zoomTouchContactActive = 0;
    zoomTargetBuffer = 0.0;
    pinchStreak = 0;
}

static int emitMosScrollEvent(double stepX, double stepY, uint32_t phase, uint32_t momentumPhase) {
    int natural = atomic_load_explicit(&naturalScrollingSetting, memory_order_relaxed);
    // Trục X của MultitouchSupport tăng từ trái (0.0) sang phải (1.0), cùng chiều dương với scrollingDeltaX khi bật Natural Scrolling
    double directedX = natural ? stepX : -stepX;
    // Trục Y của MultitouchSupport tăng từ dưới (0.0) lên trên (1.0), ngược chiều dương với scrollingDeltaY khi bật Natural Scrolling
    double directedY = natural ? -stepY : stepY;

    int isClosingEvent = (phase == kCGScrollPhaseEnded ||
                          phase == kCGScrollPhaseCancelled ||
                          momentumPhase == kCGMomentumScrollPhaseEnd);

    int32_t ptX = 0;
    int32_t ptY = 0;

    if (isClosingEvent && fabs(directedX) < 1e-4 && fabs(directedY) < 1e-4) {
        subpixelRemX = 0.0;
        subpixelRemY = 0.0;
        directedX = 0.0;
        directedY = 0.0;
    } else {
        double totalX = directedX + subpixelRemX;
        double totalY = directedY + subpixelRemY;
        ptX = (int32_t)llround(totalX);
        ptY = (int32_t)llround(totalY);

        // Đảm bảo sự kiện Began luôn có ít nhất ±1px trên trục chính để Microsoft Word không khóa nhầm trục dọc!
        if (phase == kCGScrollPhaseBegan) {
            if (fabs(totalY) >= fabs(totalX)) {
                if (ptY == 0 && fabs(totalY) >= 0.25) ptY = (totalY >= 0.0) ? 1 : -1;
                ptX = 0;
                directedX = 0.0;
            } else {
                if (ptX == 0 && fabs(totalX) >= 0.25) ptX = (totalX >= 0.0) ? 1 : -1;
                ptY = 0;
                directedY = 0.0;
            }
        }

        if (!isClosingEvent && ptX == 0 && ptY == 0) {
            subpixelRemX = totalX;
            subpixelRemY = totalY;
            return 0;
        }

        subpixelRemX = totalX - (double)ptX;
        subpixelRemY = totalY - (double)ptY;
    }

    // 2 trục (wheelCount = 2): Axis 1 = Dọc (Y), Axis 2 = Ngang (X)
    CGEventRef scrollEvent = CGEventCreateScrollWheelEvent2(
        sharedHIDSource(), kCGScrollEventUnitPixel, 2, ptY, ptX, 0);
    if (!scrollEvent) return 0;

    // Gỡ cờ Option (⌥) khỏi sự kiện cuộn để trình duyệt / VS Code / Figma / Word không hiểu nhầm là phím tắt Zoom
    CGEventFlags flags = CGEventGetFlags(scrollEvent);
    if ((flags & kCGEventFlagMaskAlternate) &&
        !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl))) {
        CGEventSetFlags(scrollEvent, flags & ~kCGEventFlagMaskAlternate);
    }

    CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollCount, 1);
    // Trường 137 (0x89) = -[NSEvent isDirectionInvertedFromDevice], bắt buộc cho vuốt Back/Forward trên Chrome & Safari
    CGEventSetIntegerValueField(scrollEvent, 137, natural ? 1 : 0);

    if (phase != 0) {
        CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollPhase, phase);
    }
    if (momentumPhase != 0) {
        CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventMomentumPhase, momentumPhase);
    }

    // Đặt DeltaAxis1/2 TRƯỚC PointDeltaAxis1/2 và FixedPtDeltaAxis1/2 để tương thích cả Microsoft Word lẫn Chrome/Safari
    CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventDeltaAxis1, ptY > 0 ? 1 : (ptY < 0 ? -1 : 0));
    CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventDeltaAxis2, ptX > 0 ? 1 : (ptX < 0 ? -1 : 0));
    CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventPointDeltaAxis1, ptY);
    CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventPointDeltaAxis2, ptX);
    CGEventSetDoubleValueField(scrollEvent, kCGScrollWheelEventFixedPtDeltaAxis1, directedY);
    CGEventSetDoubleValueField(scrollEvent, kCGScrollWheelEventFixedPtDeltaAxis2, directedX);
    CGEventSetIntegerValueField(scrollEvent, kCGEventSourceUserData, MOS_PASS_MAGIC);

    CGEventPost(kCGSessionEventTap, scrollEvent);
    CFRelease(scrollEvent);

    // Chỉ phát kèm NSEventTypeGesture (type = 29, field 110 = 6) khi đang vuốt NGANG (Back/Forward trình duyệt)
    if (phase == kCGScrollPhaseBegan && abs(ptX) > abs(ptY)) {
        mosHorizontalSwipeActive = 1;
    }
    if (mosHorizontalSwipeActive &&
        (phase == kCGScrollPhaseChanged || phase == kCGScrollPhaseEnded || phase == kCGScrollPhaseCancelled)) {
        CGEventRef gestureEvent = CGEventCreate(sharedHIDSource());
        if (gestureEvent) {
            CGEventSetType(gestureEvent, (CGEventType)29);
            if ((flags & kCGEventFlagMaskAlternate) &&
                !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl))) {
                CGEventSetFlags(gestureEvent, flags & ~kCGEventFlagMaskAlternate);
            }
            CGEventSetIntegerValueField(gestureEvent, 110, 6); // kCGEventGestureHIDType = 6 (Scroll Gesture)
            CGEventSetIntegerValueField(gestureEvent, 132, phase); // Gesture Phase (2=Changed, 4=Ended, 8=Cancelled)
            CGEventSetDoubleValueField(gestureEvent, 118, directedX * 1.85); // Horizontal Swipe Delta
            CGEventSetDoubleValueField(gestureEvent, 119, 0.0);              // Vertical Swipe Delta = 0
            CGEventSetIntegerValueField(gestureEvent, 137, natural ? 1 : 0); // isDirectionInvertedFromDevice
            CGEventSetIntegerValueField(gestureEvent, kCGEventSourceUserData, MOS_PASS_MAGIC);
            CGEventPost(kCGSessionEventTap, gestureEvent);
            CFRelease(gestureEvent);
        }
        if (phase == kCGScrollPhaseEnded || phase == kCGScrollPhaseCancelled) {
            mosHorizontalSwipeActive = 0;
        }
    }
    return 1;
}

static void stopMosScrollImmediately(int cancelTouchPhase) {
    if (mosPhaseState == 1) {
        emitMosScrollEvent(0.0, 0.0, cancelTouchPhase ? kCGScrollPhaseCancelled : kCGScrollPhaseEnded, 0);
    } else if (mosPhaseState == 2) {
        emitMosScrollEvent(0.0, 0.0, 0, kCGMomentumScrollPhaseEnd);
    }
    mosPhaseState = 0;
    mosTouchContactActive = 0;
    mosHorizontalSwipeActive = 0;
    mosDashMomentum = 0;
    mosTargetBufferX = 0.0;
    mosTargetBufferY = 0.0;
    mosVelocityPerTickX = 0.0;
    mosVelocityPerTickY = 0.0;
    mosPeakVelPerTickX = 0.0;
    mosPeakVelPerTickY = 0.0;
    subpixelRemX = 0.0;
    subpixelRemY = 0.0;
    scrollIntentX = 0.0;
    scrollIntentY = 0.0;
    scrollStreak = 0;
}

static void postDragMouseEvent(CGEventType type, CGPoint p, double dx, double dy) {
    CGEventSourceRef src = sharedHIDSource();
    if (type == kCGEventLeftMouseDown) {
        dragEventNumber++;
    }

    CGWarpMouseCursorPosition(p);
    CGAssociateMouseAndMouseCursorPosition(true);

    CGEventRef e = CGEventCreateMouseEvent(src, type, p, kCGMouseButtonLeft);
    if (!e) return;

    CGEventSetIntegerValueField(e, kCGEventSourceUserData, MAGIC);
    CGEventSetIntegerValueField(e, kCGMouseEventNumber, dragEventNumber);
    CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
    CGEventSetIntegerValueField(e, kCGMouseEventDeltaX, (int64_t)llround(dx));
    CGEventSetIntegerValueField(e, kCGMouseEventDeltaY, (int64_t)llround(dy));
    CGEventSetDoubleValueField(e, kCGMouseEventDeltaX, dx);
    CGEventSetDoubleValueField(e, kCGMouseEventDeltaY, dy);

    CGEventPost(kCGSessionEventTap, e);
    CFRelease(e);
}

// Trạng thái khởi động kéo 3 ngón
static double dragArmDx = 0.0;
static double dragArmDy = 0.0;
static int dragArmed = 0;

static CFMachPortRef eventTap = NULL;
static CFRunLoopSourceRef eventTapSource = NULL;
static CFRunLoopTimerRef timer = NULL;
static CFArrayRef deviceListRef = NULL;
static int attached = 0;
static uint64_t connectedDeviceId = 0;
static MTDeviceRef connectedDeviceRef = NULL;
static void stopDrag(const char *why);

static int multitouchAPIReady(void) {
    return MTDeviceCreateList && MTRegisterContactFrameCallback &&
           MTUnregisterContactFrameCallback && MTDeviceStart && MTDeviceStop &&
           MTDeviceGetDeviceID && MTDeviceIsBuiltIn;
}

static double readSystemTrackpadScaling(void) {
    CFPreferencesAppSynchronize(CFSTR(".GlobalPreferences"));
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR("com.apple.trackpad.scaling"), CFSTR(".GlobalPreferences"));
    double scaling = 2.0;
    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)val, kCFNumberDoubleType, &scaling);
    }
    if (val) CFRelease(val);
    if (!isfinite(scaling)) scaling = 2.0;
    if (scaling < 0.1) scaling = 0.1;
    if (scaling > 6.0) scaling = 6.0;
    return scaling;
}

static CGEventRef mouseEventTap(CGEventTapProxy proxy, CGEventType type,
                                CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        atomic_store(&eventPipelineReady, 0);
        stopDrag("Event tap bị ngắt");
        if (eventTap && AXIsProcessTrusted() && !atomic_load(&stopRequested)) {
            CGEventTapEnable(eventTap, true);
            atomic_store(&eventPipelineReady, CGEventTapIsEnabled(eventTap));
        }
        return event;
    }
    if (!event) return event;

    int64_t userData = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    if (userData == MAGIC || userData == MOS_PASS_MAGIC) return event;

    double now = nowMs();
    int isDragging = atomic_load_explicit(&dragging, memory_order_relaxed);
    double elapsedMulti = now - atomic_load_explicit(&lastMultiTouchT, memory_order_relaxed);
    int isMultiTouch = atomic_load_explicit(&multiTouchActive, memory_order_relaxed) && (elapsedMulti < 65.0);

    // Chặn sự kiện cuộn thô từ phần cứng Jomaa (IsContinuous != 0) khi đang dùng >= 2 ngón,
    // nhưng CHO QUA 100% con lăn chuột rời (IsContinuous == 0)!
    if (type == kCGEventScrollWheel) {
        if (CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous) != 0) {
            if (isMultiTouch || isDragging || elapsedMulti < 320.0) {
                return NULL;
            }
        }
        return event;
    }

    // Chặn sự kiện Zoom phần cứng bị trễ/khựng của Jomaa để bộ nội suy 120Hz Pinch-to-Zoom đảm nhiệm mượt mà
    if (type == (CGEventType)29) {
        int64_t hidType = CGEventGetIntegerValueField(event, 110);
        if (hidType == 8 && (isMultiTouch || elapsedMulti < 320.0)) {
            return NULL;
        }
        return event;
    }

    if (isMultiTouch || isDragging) {
        if (type == kCGEventMouseMoved ||
            type == kCGEventLeftMouseDragged ||
            type == kCGEventRightMouseDragged) {
            return NULL;
        }
    }

    if (!isDragging) return event;

    if (type == kCGEventLeftMouseUp || type == kCGEventLeftMouseDown) {
        return NULL;
    }

    return event;
}

static int computeMatchedFingerDelta(const TouchPos *curr, int currN,
                                     const TouchPos *prev, int prevN,
                                     double *outDx, double *outDy) {
    double sumDx = 0.0, sumDy = 0.0;
    int matched = 0;

    for (int i = 0; i < currN; i++) {
        for (int j = 0; j < prevN; j++) {
            if (curr[i].identifier == prev[j].identifier) {
                double dx = curr[i].x - prev[j].x;
                double dy = curr[i].y - prev[j].y;
                if (fabs(dx) < 0.15 && fabs(dy) < 0.15) {
                    sumDx += dx;
                    sumDy += dy;
                    matched++;
                }
                break;
            }
        }
    }

    if (matched > 0) {
        *outDx = sumDx / (double)matched;
        *outDy = sumDy / (double)matched;
    } else {
        *outDx = 0.0;
        *outDy = 0.0;
    }
    return matched;
}

// Phân rã động học 2 ngón tay: Tách biệt Tịnh tiến song song (Scroll) và Co giãn bán kính (Pinch-to-Zoom)
static int computeTwoFingerKinematics(const TouchPos *curr, int currN,
                                      const TouchPos *prev, int prevN,
                                      double *outAvgDx, double *outAvgDy,
                                      double *outRadialDelta, double *outPinchPurity,
                                      double *outCosSim) {
    *outAvgDx = 0.0;
    *outAvgDy = 0.0;
    *outRadialDelta = 0.0;
    *outPinchPurity = 0.0;
    *outCosSim = 1.0;

    if (currN < 2 || prevN < 2) {
        return computeMatchedFingerDelta(curr, currN, prev, prevN, outAvgDx, outAvgDy);
    }

    int cIdx[2] = {-1, -1};
    int pIdx[2] = {-1, -1};
    int matched = 0;

    for (int i = 0; i < currN && matched < 2; i++) {
        for (int j = 0; j < prevN; j++) {
            if (curr[i].identifier == prev[j].identifier) {
                double dx = curr[i].x - prev[j].x;
                double dy = curr[i].y - prev[j].y;
                if (fabs(dx) < 0.15 && fabs(dy) < 0.15) {
                    cIdx[matched] = i;
                    pIdx[matched] = j;
                    matched++;
                }
                break;
            }
        }
    }

    if (matched < 2) {
        return computeMatchedFingerDelta(curr, currN, prev, prevN, outAvgDx, outAvgDy);
    }

    double dx0 = curr[cIdx[0]].x - prev[pIdx[0]].x;
    double dy0 = curr[cIdx[0]].y - prev[pIdx[0]].y;
    double dx1 = curr[cIdx[1]].x - prev[pIdx[1]].x;
    double dy1 = curr[cIdx[1]].y - prev[pIdx[1]].y;

    *outAvgDx = 0.5 * (dx0 + dx1);
    *outAvgDy = 0.5 * (dy0 + dy1);

    double prevDist = hypot(prev[pIdx[1]].x - prev[pIdx[0]].x, prev[pIdx[1]].y - prev[pIdx[0]].y);
    double currDist = hypot(curr[cIdx[1]].x - curr[cIdx[0]].x, curr[cIdx[1]].y - curr[cIdx[0]].y);
    double radialDelta = currDist - prevDist;
    *outRadialDelta = radialDelta;

    double d0 = hypot(dx0, dy0);
    double d1 = hypot(dx1, dy1);
    double totalMotion = d0 + d1;
    if (totalMotion > 1e-6) {
        double purity = fabs(radialDelta) / totalMotion;
        if (purity > 1.0) purity = 1.0;
        *outPinchPurity = purity;
    }

    if (d0 > 1e-5 && d1 > 1e-5) {
        *outCosSim = (dx0 * dx1 + dy0 * dy1) / (d0 * d1);
    } else if (totalMotion > 1e-5) {
        // 1 ngón làm trụ (ngón cái đứng yên), 1 ngón di chuyển
        *outCosSim = 0.0;
    }

    return 2;
}

static void releaseDragAndUnlockCursorLocked(void) {
    dragArmed = 0;
    dragArmDx = dragArmDy = 0.0;
    dragTargetDx = dragTargetDy = 0.0;
    singleFingerSinceT = 0.0;
    atomic_store_explicit(&dragging, 0, memory_order_relaxed);
    atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);
}

// Keep down/drag/up ordered under mu, including the final buffered movement.
static void finishDragLocked(int flushPendingMovement) {
    int wasDragging = atomic_load(&dragging);
    if (wasDragging && flushPendingMovement &&
        (fabs(dragTargetDx) >= 0.05 || fabs(dragTargetDy) >= 0.05)) {
        curX += dragTargetDx;
        curY += dragTargetDy;
        postDragMouseEvent(kCGEventLeftMouseDragged, CGPointMake(curX, curY),
                           dragTargetDx, dragTargetDy);
    }
    releaseDragAndUnlockCursorLocked();
    if (wasDragging) {
        postDragMouseEvent(kCGEventLeftMouseUp, CGPointMake(curX, curY), 0.0, 0.0);
    }
}

static int touchCallback(MTDeviceRef d, MTTouch *t, int n, double ts, int frame) {
    (void)d; (void)ts; (void)frame;
    double tn = nowMs();

    pthread_mutex_lock(&mu);
    // The private callback's device token is not stable across framework versions.
    // Detach closes this gate and drains the old driver before reattaching.
    if (!acceptingTouches || atomic_load(&stopRequested) || atomic_load(&engineSuspended) ||
        !atomic_load(&eventPipelineReady) || n < 0 || (n > 0 && !t)) {
        pthread_mutex_unlock(&mu);
        return 0;
    }

    TouchPos currTouches[MAX_TOUCHES];
    int currCount = 0;
    for (int i = 0; i < n && currCount < MAX_TOUCHES; i++) {
        int st = t[i].state;
        if (st >= 1 && st <= 4 && isfinite(t[i].normalized.pos.x) &&
            isfinite(t[i].normalized.pos.y) && t[i].normalized.pos.x >= 0.0f &&
            t[i].normalized.pos.x <= 1.0f && t[i].normalized.pos.y >= 0.0f &&
            t[i].normalized.pos.y <= 1.0f) {
            currTouches[currCount].identifier = t[i].identifier;
            currTouches[currCount].x = t[i].normalized.pos.x;
            currTouches[currCount].y = t[i].normalized.pos.y;
            currTouches[currCount].size = t[i].size;
            currTouches[currCount].majorAxis = t[i].majorAxis;
            currTouches[currCount].minorAxis = t[i].minorAxis;
            currTouches[currCount].valid = 1;
            currCount++;
        }
    }
    latestPresent = currCount;

    if (currCount > 0) {
        lastTouchT = tn;
        atomic_store_explicit(&lastAnyJomaaTouchT, tn, memory_order_relaxed);
    }

    int isDragging = atomic_load_explicit(&dragging, memory_order_relaxed);

    if (isDragging) {
        if (currCount >= 2) {
            lastDragContactT = tn;
            singleFingerSinceT = 0.0;
        } else if (currCount == 1) {
            if (singleFingerSinceT == 0.0) {
                singleFingerSinceT = tn;
                singleFingerStartX = currTouches[0].x;
                singleFingerStartY = currTouches[0].y;
            } else {
                double d1 = hypot(currTouches[0].x - singleFingerStartX,
                                  currTouches[0].y - singleFingerStartY) * SPEED_FACTOR;
                if (((tn - singleFingerSinceT) >= 20.0 && d1 >= 1.0) || (tn - singleFingerSinceT) >= 45.0) {
                    finishDragLocked(1);
                    isDragging = 0;
                }
            }
        }
    }

    if (currCount >= 2 || isDragging) {
        atomic_store_explicit(&multiTouchActive, 1, memory_order_relaxed);
        atomic_store_explicit(&lastMultiTouchT, tn, memory_order_relaxed);
    } else if (currCount == 1 && !mosTouchContactActive && !zoomTouchContactActive) {
        atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);
    }

    if (!isDragging) {
        // --- 1. XỬ LÝ KHỞI ĐỘNG KÉO 3 NGÓN ---
        if (currCount >= 3) {
            double matchedDx = 0.0, matchedDy = 0.0;
            int matched = computeMatchedFingerDelta(currTouches, currCount,
                prevTouches, prevCount, &matchedDx, &matchedDy);
            if (!dragArmed || currCount != prevCount || matched != currCount) {
                dragArmDx = dragArmDy = 0.0;
                dragArmed = 1;
            } else {
                dragArmDx += matchedDx;
                dragArmDy += matchedDy;
                double dist = hypot(dragArmDx, dragArmDy) * SPEED_FACTOR;

                if (dist >= 1.0) {
                    stopMosScrollImmediately(1);
                    stopZoomImmediately(1);
                    twoFingerMode = 0;

                    CGPoint pNow = cursorNow();
                    curX = pNow.x;
                    curY = pNow.y;
                    dragTargetDx = 0.0;
                    dragTargetDy = 0.0;
                    lastDragContactT = tn;
                    singleFingerSinceT = 0.0;
                    dragArmed = 0;

                    atomic_store_explicit(&dragging, 1, memory_order_relaxed);
                    isDragging = 1;

                    postDragMouseEvent(kCGEventLeftMouseDown, pNow, 0.0, 0.0);
                    postDragMouseEvent(kCGEventLeftMouseDragged, pNow, 0.0, 0.0);
                }
            }
        } else {
            dragArmed = 0;
            dragArmDx = dragArmDy = 0.0;
        }

        // --- 2. BỘ ĐỊNH TUYẾN ĐỘNG HỌC 2 NGÓN 120Hz: CUỘN MƯỢT 2 CHIỀU vs PINCH-TO-ZOOM ---
        double timeSinceTwoFingers = tn - lastTwoFingerT;
        int isTwoFingerActive = 0;

        if (!isDragging) {
            if (currCount == 2) {
                isTwoFingerActive = 1;
                lastTwoFingerT = tn;
            } else if (currCount == 1 && (mosTouchContactActive || zoomTouchContactActive) && timeSinceTwoFingers < 55.0) {
                isTwoFingerActive = 1;
            }
        }

        if (isTwoFingerActive) {
            if (!mosTouchContactActive && !zoomTouchContactActive) {
                if (mosPhaseState == 2) {
                    emitMosScrollEvent(0.0, 0.0, 0, kCGMomentumScrollPhaseEnd);
                }
                mosPhaseState = 0;
                mosHorizontalSwipeActive = 0;
                mosTargetBufferX = 0.0;
                mosTargetBufferY = 0.0;
                mosVelocityPerTickX = 0.0;
                mosVelocityPerTickY = 0.0;
                mosPeakVelPerTickX = 0.0;
                mosPeakVelPerTickY = 0.0;
                subpixelRemX = 0.0;
                subpixelRemY = 0.0;
                scrollIntentX = 0.0;
                scrollIntentY = 0.0;
                mosDashMomentum = isOptionDashActive();
                mosTouchContactActive = 1;

                zoomPhaseState = 0;
                zoomTargetBuffer = 0.0;
                zoomTouchContactActive = 0;
                twoFingerMode = 0;
                pinchStreak = 0;
                scrollStreak = 0;
            }

            double matchedDx = 0.0, matchedDy = 0.0;
            double radialDelta = 0.0, pinchPurity = 0.0, cosSim = 1.0;
            int checkFingers = (currCount == 1) ? 1 : 2;
            int matchedCount = computeTwoFingerKinematics(
                currTouches, checkFingers, prevTouches, prevCount,
                &matchedDx, &matchedDy, &radialDelta, &pinchPurity, &cosSim);

            if (matchedCount > 0) {
                double dt = tn - lastScrollFrameT;
                if (dt < 4.0) dt = 4.0;
                if (dt > 45.0) dt = 12.0;

                double panMag = hypot(matchedDx, matchedDy);
                double pinchMag = fabs(radialDelta);

                // Phân loại tức thì giữa Pinch-to-Zoom (co giãn khoảng cách 2 ngón) và Scroll (tịnh tiến song song)
                if (matchedCount == 2 && (panMag > 0.00003 || pinchMag > 0.00005)) {
                    int isPinchFrame = ((pinchPurity >= 0.56 && cosSim <= 0.22 && pinchMag > panMag * 1.10 && pinchMag > 0.00028) ||
                                        (cosSim < -0.22 && pinchMag > panMag * 0.85 && pinchMag > 0.00025));
                    int isScrollFrame = ((pinchPurity < 0.42 && panMag > 0.00018) ||
                                         (cosSim > 0.38 && panMag > pinchMag * 1.15 && panMag > 0.00018));

                    if (twoFingerMode == 0) {
                        if (isPinchFrame) {
                            twoFingerMode = 2;
                            zoomTouchContactActive = 1;
                            mosTouchContactActive = 0;
                        } else if (isScrollFrame) {
                            twoFingerMode = 1;
                            mosTouchContactActive = 1;
                        }
                    } else if (twoFingerMode == 1) {
                        // Cho phép chuyển mượt từ Scroll sang Pinch-to-Zoom nếu người dùng chụm/bung 2 ngón rõ rệt
                        if (isPinchFrame && pinchPurity >= 0.65 && pinchMag > 0.00075) {
                            pinchStreak++;
                            if (pinchStreak >= 2) {
                                stopMosScrollImmediately(0);
                                twoFingerMode = 2;
                                zoomTouchContactActive = 1;
                                zoomPhaseState = 0;
                                zoomTargetBuffer = 0.0;
                            }
                        } else {
                            pinchStreak = 0;
                        }
                    } else if (twoFingerMode == 2) {
                        // Cho phép chuyển từ Pinch-to-Zoom sang Scroll nếu 2 ngón lướt song song rõ rệt
                        if (isScrollFrame && cosSim > 0.55 && pinchPurity < 0.28 && panMag > 0.0016) {
                            scrollStreak++;
                            if (scrollStreak >= 3) {
                                stopZoomImmediately(0);
                                twoFingerMode = 1;
                                mosTouchContactActive = 1;
                                mosPhaseState = 0;
                            }
                        } else {
                            scrollStreak = 0;
                        }
                    }
                }

                double sens = atomic_load_explicit(&sensitivityMultiplier, memory_order_relaxed);
                if (sens < 0.2) sens = 0.2;
                if (sens > 4.0) sens = 4.0;

                if (twoFingerMode == 2 && matchedCount == 2) {
                    // --- NHÁNH 2A: NỘI SUY 120Hz PINCH-TO-ZOOM (MƯỢT NHƯ TRACKPAD MACBOOK) ---
                    if (pinchMag > 0.00004) {
                        double rawPinchVel = pinchMag / dt;
                        double pinchGain = 1.0 + fmin(rawPinchVel * 180.0, 0.85);
                        double deltaMag = radialDelta * (2.65 * sqrt(sens)) * pinchGain;

                        if ((deltaMag > 0.002 && zoomTargetBuffer < -0.0015) ||
                            (deltaMag < -0.002 && zoomTargetBuffer > 0.0015)) {
                            zoomTargetBuffer = deltaMag;
                        } else {
                            zoomTargetBuffer += deltaMag;
                        }
                        if (zoomTargetBuffer > 0.85) zoomTargetBuffer = 0.85;
                        if (zoomTargetBuffer < -0.85) zoomTargetBuffer = -0.85;
                    }
                } else if (twoFingerMode != 2 && panMag > 0.00003) {
                    // --- NHÁNH 2B: NỘI SUY 120Hz CUỘN 2 CHIỀU (NGANG & DỌC + OPTION DASH) ---
                    int dashActive = isOptionDashActive();
                    if (dashActive) mosDashMomentum = 1;
                    double dashBoost = dashActive ? 3.2 : 1.0;
                    double maxBuf = dashActive ? 1800.0 : 650.0;

                    double ax = fabs(matchedDx);
                    double ay = fabs(matchedDy);
                    scrollIntentX = scrollIntentX * 0.72 + ax * 0.28;
                    scrollIntentY = scrollIntentY * 0.72 + ay * 0.28;

                    // Khóa trục thông minh KHÔNG xóa bộ đệm đang trôi
                    if (scrollIntentY > scrollIntentX * 1.30 || ay > ax * 1.50) {
                        matchedDx = 0.0;
                    } else if (scrollIntentX > scrollIntentY * 1.30 || ax > ay * 1.50) {
                        matchedDy = 0.0;
                    }

                    double rawVelX = fabs(matchedDx) / dt;
                    double flickGainX = 1.0 + fmin(rawVelX * 520.0, 1.65);
                    double deltaPixelsX = matchedDx * (1080.0 * sens) * flickGainX * dashBoost;

                    double rawVelY = fabs(matchedDy) / dt;
                    double flickGainY = 1.0 + fmin(rawVelY * 520.0, 1.65);
                    double deltaPixelsY = matchedDy * (1050.0 * sens) * flickGainY * dashBoost;

                    // Đảo chiều tức thì trên trục X
                    if ((deltaPixelsX > 2.0 && mosTargetBufferX < -1.5) ||
                        (deltaPixelsX < -2.0 && mosTargetBufferX > 1.5)) {
                        mosTargetBufferX = deltaPixelsX;
                        mosVelocityPerTickX = 0.0;
                        mosPeakVelPerTickX = 0.0;
                    } else {
                        mosTargetBufferX += deltaPixelsX;
                    }
                    if (mosTargetBufferX > maxBuf) mosTargetBufferX = maxBuf;
                    if (mosTargetBufferX < -maxBuf) mosTargetBufferX = -maxBuf;

                    // Đảo chiều tức thì trên trục Y
                    if ((deltaPixelsY > 2.5 && mosTargetBufferY < -2.0) ||
                        (deltaPixelsY < -2.5 && mosTargetBufferY > 2.0)) {
                        mosTargetBufferY = deltaPixelsY;
                        mosVelocityPerTickY = 0.0;
                        mosPeakVelPerTickY = 0.0;
                    } else {
                        mosTargetBufferY += deltaPixelsY;
                    }
                    if (mosTargetBufferY > maxBuf) mosTargetBufferY = maxBuf;
                    if (mosTargetBufferY < -maxBuf) mosTargetBufferY = -maxBuf;

                    double instVelPerTickX = deltaPixelsX * (8.33 / dt);
                    double instVelPerTickY = deltaPixelsY * (8.33 / dt);
                    mosVelocityPerTickX = 0.65 * instVelPerTickX + 0.35 * mosVelocityPerTickX;
                    mosVelocityPerTickY = 0.65 * instVelPerTickY + 0.35 * mosVelocityPerTickY;

                    double instSpeed = hypot(instVelPerTickX, instVelPerTickY);
                    double peakSpeed = hypot(mosPeakVelPerTickX, mosPeakVelPerTickY);
                    if (instSpeed >= peakSpeed * 0.85 || (tn - mosPeakVelTime) > 75.0) {
                        mosPeakVelPerTickX = instVelPerTickX * 1.15;
                        mosPeakVelPerTickY = instVelPerTickY * 1.15;
                        mosPeakVelTime = tn;
                    }
                }
            }
            lastScrollFrameT = tn;
        } else if (!isDragging && currCount < 2) {
            if ((mosTouchContactActive || zoomTouchContactActive) && timeSinceTwoFingers >= 55.0) {
                if (zoomTouchContactActive) {
                    stopZoomImmediately(0);
                }
                mosTouchContactActive = 0;
                twoFingerMode = 0;
                atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);
            }
            if (currCount == 1 && mosPhaseState == 2 && timeSinceTwoFingers > 110.0) {
                stopMosScrollImmediately(0);
            }
        }
    } else {
        // --- 3. ĐANG TRONG PHIÊN KÉO 3 NGÓN (TĂNG TỐC & GIA TỐC NHẠY BÉN) ---
        if (currCount >= 2) {
            double matchedDx = 0.0, matchedDy = 0.0;
            int matched = computeMatchedFingerDelta(currTouches, currCount,
                prevTouches, prevCount, &matchedDx, &matchedDy);
            if (matched >= 2) {
                double sens = atomic_load_explicit(&sensitivityMultiplier, memory_order_relaxed);
                if (sens < 0.2) sens = 0.2;
                if (sens > 4.0) sens = 4.0;

                double effectiveSpeed = SPEED_FACTOR * sens;
                double rawDx = matchedDx * effectiveSpeed;
                double rawDy = -matchedDy * effectiveSpeed;

                double dist = hypot(rawDx, rawDy);
                if (dist < 220.0 && dist > 0.02) {
                    // Gia tốc lũy tiến: di chậm đi chính xác (1.0x), lướt nhanh tăng vọt lên tới 2.30x!
                    double dragGain = 1.0 + fmin(dist * 0.035, 1.30);
                    dragTargetDx += rawDx * dragGain;
                    dragTargetDy += rawDy * dragGain;
                }
            }

        }
    }

    prevCount = currCount;
    for (int i = 0; i < currCount; i++) {
        prevTouches[i] = currTouches[i];
    }

    pthread_mutex_unlock(&mu);
    return 0;
}

static void stopDrag(const char *why) {
    (void)why;
    pthread_mutex_lock(&mu);
    prevCount = 0;
    stopMosScrollImmediately(1);
    stopZoomImmediately(1);
    twoFingerMode = 0;
    latestPresent = 0;
    lastTouchT = lastDragContactT = lastTwoFingerT = lastScrollFrameT = 0.0;
    atomic_store(&lastMultiTouchT, 0.0);
    atomic_store(&lastAnyJomaaTouchT, 0.0);
    finishDragLocked(0);
    pthread_mutex_unlock(&mu);
}

// ============================================================================
// VÒNG LẶP NỘI SUY 120Hz (8.33ms TICK)
// ============================================================================
static void tick(CFRunLoopTimerRef timerRef, void *info) {
    (void)timerRef; (void)info;

    if (terminationRequested) {
        [NSApp terminate:nil];
        return;
    }
    if (atomic_load(&stopRequested) || atomic_load(&engineSuspended)) {
        return;
    }

    double tn = nowMs();
    double dragEmitDx = 0.0, dragEmitDy = 0.0;

    pthread_mutex_lock(&mu);
    int isDragging = atomic_load_explicit(&dragging, memory_order_relaxed);
    double touchGap = tn - lastTouchT;
    double twoFingerGap = tn - lastTwoFingerT;
    double dragContactGap = tn - lastDragContactT;

    // 1. Khi người dùng đang KÉO 3 NGÓN:
    if (isDragging) {
        // Brief grace for lost sensor frames; release promptly after an explicit lift.
        if ((latestPresent == 0 && dragContactGap >= 45.0) ||
            (latestPresent == 1 && singleFingerSinceT > 0.0 && tn - singleFingerSinceT >= 45.0) ||
            dragContactGap >= 380.0) {
            finishDragLocked(1);
            isDragging = 0;
        }
    }
    if (isDragging && latestPresent >= 2) {
        if (fabs(dragTargetDx) >= 0.05 || fabs(dragTargetDy) >= 0.05) {
            dragEmitDx = dragTargetDx * 0.75;
            dragEmitDy = dragTargetDy * 0.75;
            dragTargetDx -= dragEmitDx;
            dragTargetDy -= dragEmitDy;

            curX += dragEmitDx;
            curY += dragEmitDy;
            postDragMouseEvent(kCGEventLeftMouseDragged, CGPointMake(curX, curY),
                               dragEmitDx, dragEmitDy);
        }
    }

    // 2A. Khi người dùng nhấc 2 ngón tay sau khi PINCH-TO-ZOOM:
    if (!isDragging && zoomTouchContactActive && twoFingerGap >= 38.0) {
        stopZoomImmediately(0);
        twoFingerMode = 0;
        if (!mosTouchContactActive) {
            atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);
        }
    }

    // 2B. Khi người dùng nhấc 2 ngón tay khỏi bàn rê (Cuộn trang 2 chiều):
    if (!isDragging && mosTouchContactActive && twoFingerGap >= 38.0) {
        mosTouchContactActive = 0;
        twoFingerMode = 0;
        atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);

        double launchVelX = mosVelocityPerTickX;
        double launchVelY = mosVelocityPerTickY;
        if ((tn - mosPeakVelTime) <= 80.0) {
            if (fabs(mosPeakVelPerTickX) > fabs(launchVelX)) launchVelX = mosPeakVelPerTickX;
            if (fabs(mosPeakVelPerTickY) > fabs(launchVelY)) launchVelY = mosPeakVelPerTickY;
        }
        if (fabs(launchVelX) > fabs(launchVelY) * 1.30) {
            launchVelY = 0.0;
        } else if (fabs(launchVelY) > fabs(launchVelX) * 1.30) {
            launchVelX = 0.0;
        }

        if (mosPhaseState == 1) {
            emitMosScrollEvent(0.0, 0.0, kCGScrollPhaseEnded, 0);
        }

        if (isOptionDashActive()) {
            mosDashMomentum = 1;
        }
        double maxLaunchVel = mosDashMomentum ? 125.0 : 42.0;

        if (hypot(launchVelX, launchVelY) >= 1.2) {
            mosVelocityPerTickX = fmin(fmax(launchVelX, -maxLaunchVel), maxLaunchVel);
            mosVelocityPerTickY = fmin(fmax(launchVelY, -maxLaunchVel), maxLaunchVel);
            mosPhaseState = 2;
            mosTargetBufferX = 0.0;
            mosTargetBufferY = 0.0;
            emitMosScrollEvent(mosVelocityPerTickX, mosVelocityPerTickY, 0, kCGMomentumScrollPhaseBegin);
        } else {
            mosPhaseState = 0;
            mosDashMomentum = 0;
            mosTargetBufferX = 0.0;
            mosTargetBufferY = 0.0;
            mosVelocityPerTickX = 0.0;
            mosVelocityPerTickY = 0.0;
        }
        mosPeakVelPerTickX = 0.0;
        mosPeakVelPerTickY = 0.0;
    }

    if (touchGap >= 45.0 && !isDragging && !mosTouchContactActive && !zoomTouchContactActive) {
        latestPresent = 0;
        dragArmed = 0;
        twoFingerMode = 0;
        atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);
    }

    // 3A. Khi 2 ngón tay ĐANG PINCH-TO-ZOOM ở 120Hz:
    if (!isDragging && zoomTouchContactActive) {
        if (fabs(zoomTargetBuffer) >= 0.00025) {
            double stepMag = zoomTargetBuffer * 0.44;
            zoomTargetBuffer -= stepMag;
            uint32_t phase = (zoomPhaseState == 0) ? kCGScrollPhaseBegan : kCGScrollPhaseChanged;
            zoomPhaseState = 1;
            emitMagnifyEvent(stepMag, phase);
        }
    }
    // 3B. Khi 2 ngón tay ĐANG CHẠM bàn rê để CUỘN 2 CHIỀU ở 120Hz:
    else if (!isDragging && mosTouchContactActive) {
        double minTrigger = (mosPhaseState == 0) ? 0.65 : 0.12;
        if (fabs(mosTargetBufferX) >= minTrigger || fabs(mosTargetBufferY) >= minTrigger) {
            double stepX = mosTargetBufferX * 0.36;
            double stepY = mosTargetBufferY * 0.35;
            mosTargetBufferX -= stepX;
            mosTargetBufferY -= stepY;

            if (fabs(stepY) >= fabs(stepX) * 1.25) {
                stepX = 0.0;
            } else if (fabs(stepX) > fabs(stepY) * 1.25) {
                stepY = 0.0;
            }

            uint32_t phase = (mosPhaseState == 0) ? kCGScrollPhaseBegan : kCGScrollPhaseChanged;
            if (emitMosScrollEvent(stepX, stepY, phase, 0)) {
                mosPhaseState = 1;
            }
        }
    }
    // 3C. Khi ĐÃ NHẤC TAY (Pha trôi quán tính Momentum 2 chiều + Option Dash):
    else if (!isDragging && !mosTouchContactActive && mosPhaseState == 2) {
        double speedMag = hypot(mosVelocityPerTickX, mosVelocityPerTickY);
        double speedRatio = fmin(speedMag / (mosDashMomentum ? 36.0 : 18.0), 1.0);
        double decay = mosDashMomentum
            ? (0.945 + 0.025 * speedRatio)
            : (0.925 + (0.955 - 0.925) * speedRatio);
        mosVelocityPerTickX *= decay;
        mosVelocityPerTickY *= decay;

        if (hypot(mosVelocityPerTickX, mosVelocityPerTickY) >= 0.35) {
            emitMosScrollEvent(mosVelocityPerTickX, mosVelocityPerTickY, 0, kCGMomentumScrollPhaseContinue);
        } else {
            emitMosScrollEvent(0.0, 0.0, 0, kCGMomentumScrollPhaseEnd);
            mosPhaseState = 0;
            mosDashMomentum = 0;
            mosVelocityPerTickX = 0.0;
            mosVelocityPerTickY = 0.0;
        }
    }
    pthread_mutex_unlock(&mu);
}

static BOOL trySetupEventTap(void) {
    if (atomic_load(&stopRequested)) return NO;
    if (!AXIsProcessTrusted()) {
        atomic_store(&eventPipelineReady, 0);
        stopDrag("Chưa có quyền Trợ năng");
        if (eventTap && CFMachPortIsValid(eventTap)) CGEventTapEnable(eventTap, false);
        return NO;
    }
    if (eventTap && CFMachPortIsValid(eventTap) && CGEventTapIsEnabled(eventTap)) {
        atomic_store(&eventPipelineReady, 1);
        return atomic_load(&eventPipelineReady) ? YES : NO;
    }
    atomic_store(&eventPipelineReady, 0);
    if (eventTapSource) {
        CFRunLoopSourceInvalidate(eventTapSource);
        CFRelease(eventTapSource);
        eventTapSource = NULL;
    }
    if (eventTap) {
        CFMachPortInvalidate(eventTap);
        CFRelease(eventTap);
        eventTap = NULL;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventScrollWheel) |
                       CGEventMaskBit(kCGEventMouseMoved) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventRightMouseDragged) |
                       CGEventMaskBit(kCGEventOtherMouseDragged) |
                       CGEventMaskBit((CGEventType)29);
    eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                                kCGEventTapOptionDefault, mask, mouseEventTap, NULL);
    if (eventTap) {
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
        if (!eventTapSource) {
            CFMachPortInvalidate(eventTap);
            CFRelease(eventTap);
            eventTap = NULL;
            return NO;
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, kCFRunLoopCommonModes);
        CGEventTapEnable(eventTap, true);
        atomic_store(&eventPipelineReady, CGEventTapIsEnabled(eventTap));
        fprintf(stderr, "[JomaaDrag] Đã tạo thành công CGEventTap!\n");
        return YES;
    }
    return NO;
}

static void detachAndResetTrackpad(void) {
    pthread_mutex_lock(&mu);
    acceptingTouches = 0;
    pthread_mutex_unlock(&mu);
    // Never hold mu while stopping the driver: it may wait for a callback.
    if (connectedDeviceRef) {
        if (MTUnregisterContactFrameCallback) {
            MTUnregisterContactFrameCallback(connectedDeviceRef, touchCallback);
        }
        if (MTDeviceStop) {
            MTDeviceStop(connectedDeviceRef);
        }
    }
    stopDrag("Trackpad đổi cổng / ngắt kết nối");
    pthread_mutex_lock(&mu);
    connectedDeviceRef = NULL;
    pthread_mutex_unlock(&mu);
    if (deviceListRef) {
        CFRelease(deviceListRef);
        deviceListRef = NULL;
    }
    attached = 0;
    connectedDeviceId = 0;
}

static void checkAndAttachTrackpad(void) {
    if (!multitouchAPIReady() || !atomic_load(&eventPipelineReady) ||
        atomic_load(&stopRequested) || atomic_load(&engineSuspended)) {
        if (attached) detachAndResetTrackpad();
        return;
    }

    CFArrayRef list = MTDeviceCreateList();
    if (!list) return;

    MTDeviceRef externalDev = NULL;
    uint64_t externalId = 0;

    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        int isBuiltIn = MTDeviceIsBuiltIn ? MTDeviceIsBuiltIn(dev) : 0;
        uint64_t devId = 0;
        MTDeviceGetDeviceID(dev, &devId);

        if (isBuiltIn || devId == BUILTIN_ID) continue;

        externalDev = dev;
        externalId = devId;
        break;
    }

    if (externalDev) {
        if (attached) {
            if (connectedDeviceId != externalId || (MTDeviceIsRunning && !MTDeviceIsRunning(connectedDeviceRef))) {
                detachAndResetTrackpad();
            } else {
                CFRelease(list);
                return;
            }
        }

        pthread_mutex_lock(&mu);
        connectedDeviceRef = externalDev;
        acceptingTouches = 1;
        pthread_mutex_unlock(&mu);
        MTRegisterContactFrameCallback(externalDev, touchCallback);
        MTDeviceStart(externalDev, 0);
        attached = 1;
        connectedDeviceId = externalId;
        deviceListRef = list;
        fprintf(stderr, "[JomaaDrag] Đã kết nối trackpad ngoài: ID=%llu\n", (unsigned long long)externalId);
    } else {
        if (attached) {
            detachAndResetTrackpad();
        }
        CFRelease(list);
    }
}

static void shutdownEngine(void) {
    if (atomic_exchange(&stopRequested, 1)) return;
    if (timer) {
        CFRunLoopTimerInvalidate(timer);
        CFRelease(timer);
        timer = NULL;
    }
    // Finish gestures while the shared event source is still alive.
    detachAndResetTrackpad();
    atomic_store(&eventPipelineReady, 0);
    if (eventTapSource) {
        CFRunLoopSourceInvalidate(eventTapSource);
        CFRelease(eventTapSource);
        eventTapSource = NULL;
    }
    if (eventTap) {
        CGEventTapEnable(eventTap, false);
        CFMachPortInvalidate(eventTap);
        CFRelease(eventTap);
        eventTap = NULL;
    }
    pthread_mutex_lock(&mu);
    if (hidEventSource) {
        CFRelease(hidEventSource);
        hidEventSource = NULL;
    }
    pthread_mutex_unlock(&mu);
}

static void requestTermination(int signo) {
    (void)signo;
    terminationRequested = 1;
}

// --- Menu Bar App Delegate ---
@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (strong, nonatomic) NSMenuItem *statusMenuItem;
@property (strong, nonatomic) NSMenuItem *deviceMenuItem;
@property (strong, nonatomic) NSMenuItem *sensitivityMenuItem;
@property (strong, nonatomic) NSMenu *sensitivitySubmenu;
@property (strong, nonatomic) NSTimer *pollTimer;

@property (assign, nonatomic) BOOL syncWithSystemTrackpad;
@property (assign, nonatomic) double customSensitivity;
@property (assign, nonatomic) double lastSystemScaling;
@property (assign, nonatomic) double effectiveMultiplier;

@property (strong, nonatomic) NSWindow *prefsWindow;
@property (strong, nonatomic) NSSlider *prefsSlider;
@property (strong, nonatomic) NSTextField *prefsValueLabel;
@property (strong, nonatomic) NSButton *prefsSyncCheckbox;
@property (strong, nonatomic) NSTextField *prefsSystemInfoLabel;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [self loadSensitivitySettings];
    atomic_store_explicit(&naturalScrollingSetting, readNaturalScrolling(), memory_order_relaxed);

    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (h) {
        MTDeviceCreateList = dlsym(h, "MTDeviceCreateList");
        MTRegisterContactFrameCallback = dlsym(h, "MTDeviceRegisterContactFrameCallback");
        if (!MTRegisterContactFrameCallback) {
            MTRegisterContactFrameCallback = dlsym(h, "MTRegisterContactFrameCallback");
        }
        MTUnregisterContactFrameCallback = dlsym(h, "MTUnregisterContactFrameCallback");
        MTDeviceStart = dlsym(h, "MTDeviceStart");
        MTDeviceStop = dlsym(h, "MTDeviceStop");
        MTDeviceGetDeviceID = dlsym(h, "MTDeviceGetDeviceID");
        MTDeviceIsBuiltIn = dlsym(h, "MTDeviceIsBuiltIn");
        MTDeviceIsAvailable = dlsym(h, "MTDeviceIsAvailable");
        MTDeviceIsRunning = dlsym(h, "MTDeviceIsRunning");
    }

    trySetupEventTap();
    checkAndAttachTrackpad();

    timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 0.00833, 0.00833, 0, 0, tick, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);

    [self setupStatusBar];

    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(onWakeFromSleep:)
                                                               name:NSWorkspaceDidWakeNotification
                                                             object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
        selector:@selector(onWillSleep:) name:NSWorkspaceWillSleepNotification object:nil];

    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(onPollTimer)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)loadSensitivitySettings {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if ([defs objectForKey:@"SyncWithSystemTrackpad"] == nil) {
        [defs setBool:YES forKey:@"SyncWithSystemTrackpad"];
    }
    if ([defs objectForKey:@"CustomSensitivity"] == nil) {
        [defs setDouble:1.0 forKey:@"CustomSensitivity"];
    }

    self.syncWithSystemTrackpad = [defs boolForKey:@"SyncWithSystemTrackpad"];
    self.customSensitivity = [defs doubleForKey:@"CustomSensitivity"];
    if (!isfinite(self.customSensitivity) || self.customSensitivity < 0.3) self.customSensitivity = 1.0;
    self.customSensitivity = fmin(self.customSensitivity, 2.5);

    [self applySensitivitySettings];
}

- (void)applySensitivitySettings {
    self.lastSystemScaling = readSystemTrackpadScaling();

    if (self.syncWithSystemTrackpad) {
        self.effectiveMultiplier = fmax(0.25, self.lastSystemScaling / 2.0);
    } else {
        self.effectiveMultiplier = self.customSensitivity;
    }

    atomic_store_explicit(&sensitivityMultiplier, self.effectiveMultiplier, memory_order_relaxed);

    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setBool:self.syncWithSystemTrackpad forKey:@"SyncWithSystemTrackpad"];
    [defs setDouble:self.customSensitivity forKey:@"CustomSensitivity"];
    [defs synchronize];

    [self updateSensitivityMenuUI];
    [self updatePrefsWindowUI];
}

- (void)setupStatusBar {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    NSImage *img = [NSImage imageWithSystemSymbolName:@"hand.draw.fill" accessibilityDescription:@"JomaaDrag"];
    if (img) {
        [img setTemplate:YES];
        self.statusItem.button.image = img;
    } else {
        self.statusItem.button.title = @"🖐️";
    }

    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:@"JomaaDrag v15.1" action:nil keyEquivalent:@""];
    [header setEnabled:NO];
    [menu addItem:header];

    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:eventTap ?
        @"Trạng thái: Hoạt động mượt mà 🟢" :
        @"Trạng thái: Cần cấp quyền Trợ năng ⚠️" action:nil keyEquivalent:@""];
    [self.statusMenuItem setEnabled:NO];
    [menu addItem:self.statusMenuItem];

    self.deviceMenuItem = [[NSMenuItem alloc] initWithTitle:attached ?
        [NSString stringWithFormat:@"Trackpad: Đã kết nối (ID: %llu)", connectedDeviceId] :
        @"Trackpad: Đang chờ cắm thiết bị..." action:nil keyEquivalent:@""];
    [self.deviceMenuItem setEnabled:NO];
    [menu addItem:self.deviceMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    self.sensitivityMenuItem = [[NSMenuItem alloc] initWithTitle:@"Độ nhạy (Sensitivity) ▶" action:nil keyEquivalent:@""];
    self.sensitivitySubmenu = [[NSMenu alloc] init];
    [self.sensitivityMenuItem setSubmenu:self.sensitivitySubmenu];
    [menu addItem:self.sensitivityMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *loginItem = [[NSMenuItem alloc] initWithTitle:@"Khởi động cùng máy: Đã bật ✅" action:nil keyEquivalent:@""];
    [loginItem setEnabled:NO];
    [menu addItem:loginItem];

    NSMenuItem *openSettings = [[NSMenuItem alloc] initWithTitle:@"Mở Cài đặt Trợ năng (Accessibility)..." action:@selector(openAccessibility) keyEquivalent:@""];
    [openSettings setTarget:self];
    [menu addItem:openSettings];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Thoát JomaaDrag" action:@selector(quitApp) keyEquivalent:@"q"];
    [quitItem setTarget:self];
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
    [self updateSensitivityMenuUI];
}

- (void)updateSensitivityMenuUI {
    if (!self.sensitivitySubmenu) return;
    [self.sensitivitySubmenu removeAllItems];

    NSString *headerTitle = [NSString stringWithFormat:@"Độ nhạy: %.0f%%%@",
                             self.effectiveMultiplier * 100.0,
                             self.syncWithSystemTrackpad ? @" (Đồng bộ macOS)" : @""];
    self.sensitivityMenuItem.title = headerTitle;

    NSString *syncTitle = [NSString stringWithFormat:@"Tự động đồng bộ với Trackpad macOS (Tốc độ: %.2g)", self.lastSystemScaling];
    NSMenuItem *syncItem = [[NSMenuItem alloc] initWithTitle:syncTitle action:@selector(toggleSyncWithSystem:) keyEquivalent:@""];
    [syncItem setTarget:self];
    [syncItem setState:self.syncWithSystemTrackpad ? NSControlStateValueOn : NSControlStateValueOff];
    [self.sensitivitySubmenu addItem:syncItem];

    [self.sensitivitySubmenu addItem:[NSMenuItem separatorItem]];

    NSArray *presets = @[
        @{@"title": @"Rất chậm (60%)", @"val": @60},
        @{@"title": @"Chậm (80%)", @"val": @80},
        @{@"title": @"Tiêu chuẩn (100% - Mặc định)", @"val": @100},
        @{@"title": @"Nhanh (125%)", @"val": @125},
        @{@"title": @"Rất nhanh (150%)", @"val": @150},
        @{@"title": @"Cực nhanh (180%)", @"val": @180},
        @{@"title": @"Siêu tốc (220%)", @"val": @220}
    ];

    for (NSDictionary *p in presets) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:p[@"title"] action:@selector(selectPresetSensitivity:) keyEquivalent:@""];
        mi.tag = [p[@"val"] integerValue];
        mi.target = self;
        if (!self.syncWithSystemTrackpad && fabs(self.customSensitivity * 100.0 - mi.tag) < 3.0) {
            [mi setState:NSControlStateValueOn];
        } else {
            [mi setState:NSControlStateValueOff];
        }
        [self.sensitivitySubmenu addItem:mi];
    }

    [self.sensitivitySubmenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *customItem = [[NSMenuItem alloc] initWithTitle:@"Tuỳ chỉnh độ nhạy & Slider..." action:@selector(openPreferencesWindow) keyEquivalent:@""];
    [customItem setTarget:self];
    [self.sensitivitySubmenu addItem:customItem];

    NSMenuItem *sysTrackpadItem = [[NSMenuItem alloc] initWithTitle:@"Mở Cài đặt Trackpad macOS..." action:@selector(openSystemTrackpadSettings) keyEquivalent:@""];
    [sysTrackpadItem setTarget:self];
    [self.sensitivitySubmenu addItem:sysTrackpadItem];
}

- (void)toggleSyncWithSystem:(id)sender {
    self.syncWithSystemTrackpad = !self.syncWithSystemTrackpad;
    [self applySensitivitySettings];
}

- (void)selectPresetSensitivity:(NSMenuItem *)sender {
    self.syncWithSystemTrackpad = NO;
    self.customSensitivity = (double)sender.tag / 100.0;
    [self applySensitivitySettings];
}

- (void)openSystemTrackpadSettings {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Trackpad-Settings.extension"];
    if (![[NSWorkspace sharedWorkspace] openURL:url]) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.trackpad"]];
    }
}

- (void)openPreferencesWindow {
    if (!self.prefsWindow) {
        NSRect frame = NSMakeRect(0, 0, 480, 310);
        self.prefsWindow = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        self.prefsWindow.title = @"Cài đặt Độ nhạy Trackpad (JomaaDrag)";
        self.prefsWindow.releasedWhenClosed = NO;
        self.prefsWindow.delegate = self;
        [self.prefsWindow center];

        NSView *cv = self.prefsWindow.contentView;

        NSTextField *title = [NSTextField labelWithString:@"Cài đặt Tốc độ Con trỏ & Cử chỉ 3 ngón"];
        title.frame = NSMakeRect(24, 260, 432, 28);
        title.font = [NSFont boldSystemFontOfSize:16];
        [cv addSubview:title];

        self.prefsSyncCheckbox = [NSButton checkboxWithTitle:@"Tự động đồng bộ độ nhạy với Trackpad thật trên MacBook"
                                                      target:self
                                                      action:@selector(onPrefsSyncToggled:)];
        self.prefsSyncCheckbox.frame = NSMakeRect(24, 222, 432, 24);
        self.prefsSyncCheckbox.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        [cv addSubview:self.prefsSyncCheckbox];

        self.prefsSystemInfoLabel = [NSTextField labelWithString:@""];
        self.prefsSystemInfoLabel.frame = NSMakeRect(44, 198, 412, 20);
        self.prefsSystemInfoLabel.font = [NSFont systemFontOfSize:11];
        self.prefsSystemInfoLabel.textColor = [NSColor secondaryLabelColor];
        [cv addSubview:self.prefsSystemInfoLabel];

        self.prefsValueLabel = [NSTextField labelWithString:@""];
        self.prefsValueLabel.frame = NSMakeRect(24, 150, 432, 24);
        self.prefsValueLabel.font = [NSFont boldSystemFontOfSize:15];
        [cv addSubview:self.prefsValueLabel];

        self.prefsSlider = [NSSlider sliderWithValue:self.effectiveMultiplier
                                            minValue:0.50
                                            maxValue:2.50
                                              target:self
                                              action:@selector(onPrefsSliderMoved:)];
        self.prefsSlider.frame = NSMakeRect(24, 120, 432, 24);
        self.prefsSlider.continuous = YES;
        [cv addSubview:self.prefsSlider];

        NSTextField *minLbl = [NSTextField labelWithString:@"Chậm (50%)"];
        minLbl.frame = NSMakeRect(24, 100, 100, 16);
        minLbl.font = [NSFont systemFontOfSize:10];
        minLbl.textColor = [NSColor secondaryLabelColor];
        [cv addSubview:minLbl];

        NSTextField *midLbl = [NSTextField labelWithString:@"Chuẩn (100%)"];
        midLbl.frame = NSMakeRect(200, 100, 100, 16);
        midLbl.alignment = NSTextAlignmentCenter;
        midLbl.font = [NSFont systemFontOfSize:10];
        midLbl.textColor = [NSColor secondaryLabelColor];
        [cv addSubview:midLbl];

        NSTextField *maxLbl = [NSTextField labelWithString:@"Nhanh (250%)"];
        maxLbl.frame = NSMakeRect(356, 100, 100, 16);
        maxLbl.alignment = NSTextAlignmentRight;
        maxLbl.font = [NSFont systemFontOfSize:10];
        maxLbl.textColor = [NSColor secondaryLabelColor];
        [cv addSubview:maxLbl];

        NSButton *btnSys = [NSButton buttonWithTitle:@"Mở Cài đặt Trackpad macOS..."
                                              target:self
                                              action:@selector(openSystemTrackpadSettings)];
        btnSys.frame = NSMakeRect(24, 30, 210, 32);
        btnSys.bezelStyle = NSBezelStyleRounded;
        [cv addSubview:btnSys];

        NSButton *btnReset = [NSButton buttonWithTitle:@"Đặt lại Mặc định"
                                                target:self
                                                action:@selector(onPrefsReset:)];
        btnReset.frame = NSMakeRect(246, 30, 120, 32);
        btnReset.bezelStyle = NSBezelStyleRounded;
        [cv addSubview:btnReset];

        NSButton *btnClose = [NSButton buttonWithTitle:@"Xong"
                                                target:self
                                                action:@selector(closePrefsWindow)];
        btnClose.frame = NSMakeRect(376, 30, 80, 32);
        btnClose.bezelStyle = NSBezelStyleRounded;
        btnClose.keyEquivalent = @"\r";
        [cv addSubview:btnClose];
    }

    [self updatePrefsWindowUI];
    [NSApp activateIgnoringOtherApps:YES];
    [self.prefsWindow makeKeyAndOrderFront:nil];
}

- (void)updatePrefsWindowUI {
    if (!self.prefsWindow) return;

    self.prefsSyncCheckbox.state = self.syncWithSystemTrackpad ? NSControlStateValueOn : NSControlStateValueOff;

    self.prefsSystemInfoLabel.stringValue = [NSString stringWithFormat:
        @"Hệ thống hiện tại: %.2g (Tự cập nhật khi chỉnh trong Cài đặt hệ thống > Bàn di chuột)",
        self.lastSystemScaling];

    self.prefsValueLabel.stringValue = [NSString stringWithFormat:@"Độ nhạy hiện tại: %.0f%% (Hệ số: %.2fx)%@",
        self.effectiveMultiplier * 100.0,
        self.effectiveMultiplier,
        self.syncWithSystemTrackpad ? @" [Đang đồng bộ macOS]" : @" [Tuỳ chỉnh]"];

    self.prefsSlider.doubleValue = self.effectiveMultiplier;
}

- (void)onPrefsSyncToggled:(NSButton *)sender {
    self.syncWithSystemTrackpad = (sender.state == NSControlStateValueOn);
    [self applySensitivitySettings];
}

- (void)onPrefsSliderMoved:(NSSlider *)sender {
    self.syncWithSystemTrackpad = NO;
    self.customSensitivity = sender.doubleValue;
    [self applySensitivitySettings];
}

- (void)onPrefsReset:(id)sender {
    self.syncWithSystemTrackpad = YES;
    self.customSensitivity = 1.0;
    [self applySensitivitySettings];
}

- (void)closePrefsWindow {
    [self.prefsWindow orderOut:nil];
}

- (void)onWakeFromSleep:(NSNotification *)note {
    (void)note;
    detachAndResetTrackpad();
    atomic_store(&engineSuspended, 0);
    trySetupEventTap();
    checkAndAttachTrackpad();
}

- (void)onWillSleep:(NSNotification *)note {
    (void)note;
    atomic_store(&engineSuspended, 1);
    detachAndResetTrackpad();
}

- (void)onPollTimer {
    if (atomic_load(&stopRequested) || atomic_load(&engineSuspended)) return;
    BOOL ready = trySetupEventTap();
    self.statusMenuItem.title = !multitouchAPIReady()
        ? @"Trạng thái: Không thể tải driver cảm ứng ⚠️"
        : (ready ? @"Trạng thái: Đang hoạt động 🟢" : @"Trạng thái: Cần cấp quyền Trợ năng ⚠️");

    checkAndAttachTrackpad();
    atomic_store_explicit(&naturalScrollingSetting, readNaturalScrolling(), memory_order_relaxed);

    if (self.syncWithSystemTrackpad) {
        double currentSys = readSystemTrackpadScaling();
        if (fabs(currentSys - self.lastSystemScaling) > 0.001) {
            [self applySensitivitySettings];
        }
    }

    if (self.deviceMenuItem) {
        if (attached) {
            self.deviceMenuItem.title = [NSString stringWithFormat:@"Trackpad: Đã kết nối (ID: %llu)", connectedDeviceId];
        } else {
            self.deviceMenuItem.title = @"Trackpad: Đang chờ cắm thiết bị...";
        }
    }
}

- (void)openAccessibility {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)quitApp {
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    (void)aNotification;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    shutdownEngine();
}

@end

int main(void) {
    signal(SIGTERM, requestTermination);
    signal(SIGINT, requestTermination);
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
