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
    if (val) {
        nat = CFBooleanGetValue((CFBooleanRef)val) ? 1 : 0;
        CFRelease(val);
    }
    return nat;
}

// Trạng thái đồng bộ
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int dragging = 0;
static volatile sig_atomic_t stopRequested = 0;

static double lastTouchT = 0.0;
static double lastDragContactT = 0.0;
static double singleFingerSinceT = 0.0;
static double singleFingerStartX = 0.0;
static double singleFingerStartY = 0.0;
static double armSince = 0.0;
static int latestPresent = 0;
static double tRef = 0.0;

// Vị trí con trỏ & Bộ đệm Nội suy Kéo 3 ngón 120Hz
static double curX = 0.0, curY = 0.0;
static double dragTargetDx = 0.0, dragTargetDy = 0.0;
static double prevDragCentroidX = 0.0;
static double prevDragCentroidY = 0.0;
static int prevDragFingerCount = 0;
static int dragCentroidValid = 0;

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
// PER-FINGER ID TRACKING & MOS 120Hz SCROLL INTERPOLATOR
// ============================================================================
static double lastScrollFrameT = 0.0;
static double lastTwoFingerT = 0.0;

static double mosTargetBufferY = 0.0;
static double mosVelocityPerTick = 0.0;
static double mosPeakVelPerTick = 0.0;
static double mosPeakVelTime = 0.0;
static int mosTouchContactActive = 0;
static int mosPhaseState = 0;

static inline double nowMs(void) {
    return CFAbsoluteTimeGetCurrent() * 1000.0;
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

static void emitMosScrollEvent(double stepY, uint32_t phase, uint32_t momentumPhase) {
    int natural = atomic_load_explicit(&naturalScrollingSetting, memory_order_relaxed);
    double directedStep = natural ? -stepY : stepY;

    int32_t intPixel = (int32_t)round(directedStep);
    if (intPixel == 0 && fabs(directedStep) >= 0.35) {
        intPixel = (directedStep > 0) ? 1 : -1;
    }

    CGEventRef scrollEvent = CGEventCreateScrollWheelEvent2(sharedHIDSource(), kCGScrollEventUnitPixel, 1, intPixel, 0, 0);
    if (!scrollEvent) return;

    CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventIsContinuous, 1);
    
    if (phase != 0) {
        CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventScrollPhase, phase);
    }
    if (momentumPhase != 0) {
        CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventMomentumPhase, momentumPhase);
    }
    
    CGEventSetDoubleValueField(scrollEvent, kCGScrollWheelEventPointDeltaAxis1, directedStep);
    CGEventSetIntegerValueField(scrollEvent, kCGScrollWheelEventFixedPtDeltaAxis1, (int64_t)llround(directedStep * 65536.0));
    CGEventSetIntegerValueField(scrollEvent, kCGEventSourceUserData, MAGIC);

    CGEventPost(kCGSessionEventTap, scrollEvent);
    CFRelease(scrollEvent);
}

static void stopMosScrollImmediately(int cancelTouchPhase) {
    if (mosPhaseState == 1) {
        emitMosScrollEvent(0.0, cancelTouchPhase ? kCGScrollPhaseCancelled : kCGScrollPhaseEnded, 0);
    } else if (mosPhaseState == 2) {
        emitMosScrollEvent(0.0, 0, kCGMomentumScrollPhaseEnd);
    }
    mosPhaseState = 0;
    mosTouchContactActive = 0;
    mosTargetBufferY = 0.0;
    mosVelocityPerTick = 0.0;
    mosPeakVelPerTick = 0.0;
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
static double dragCentroidStartX = 0.0;
static double dragCentroidStartY = 0.0;
static int dragArmed = 0;

static CFMachPortRef eventTap = NULL;
static CFRunLoopSourceRef eventTapSource = NULL;
static CFRunLoopTimerRef timer = NULL;
static CFArrayRef deviceListRef = NULL;
static int attached = 0;
static uint64_t connectedDeviceId = 0;
static MTDeviceRef connectedDeviceRef = NULL;

static double readSystemTrackpadScaling(void) {
    CFPreferencesAppSynchronize(CFSTR(".GlobalPreferences"));
    CFPropertyListRef val = CFPreferencesCopyAppValue(CFSTR("com.apple.trackpad.scaling"), CFSTR(".GlobalPreferences"));
    double scaling = 2.0;
    if (val) {
        scaling = [(__bridge NSNumber *)val doubleValue];
        CFRelease(val);
    }
    if (scaling < 0.1) scaling = 0.1;
    if (scaling > 6.0) scaling = 6.0;
    return scaling;
}

static CGEventRef mouseEventTap(CGEventTapProxy proxy, CGEventType type,
                                CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (eventTap) CGEventTapEnable(eventTap, true);
        return event;
    }
    if (!event) return event;

    int64_t userData = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    if (userData == MAGIC) return event;

    double now = nowMs();
    int isDragging = atomic_load_explicit(&dragging, memory_order_relaxed);
    double elapsedMulti = now - atomic_load_explicit(&lastMultiTouchT, memory_order_relaxed);
    double elapsedAny = now - atomic_load_explicit(&lastAnyJomaaTouchT, memory_order_relaxed);
    int isMultiTouch = atomic_load_explicit(&multiTouchActive, memory_order_relaxed) && (elapsedMulti < 65.0);

    if (type == kCGEventScrollWheel) {
        if (isMultiTouch || isDragging || elapsedAny < 300.0) {
            return NULL;
        }
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

static void releaseDragAndUnlockCursorLocked(void) {
    dragArmed = 0;
    armSince = 0.0;
    dragTargetDx = dragTargetDy = 0.0;
    dragCentroidValid = 0;
    prevDragFingerCount = 0;
    singleFingerSinceT = 0.0;
    atomic_store_explicit(&dragging, 0, memory_order_relaxed);
    atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);
    CGAssociateMouseAndMouseCursorPosition(true);
}

static int touchCallback(MTDeviceRef d, MTTouch *t, int n, double ts, int frame) {
    (void)d; (void)ts; (void)frame;
    double tn = nowMs();

    pthread_mutex_lock(&mu);

    TouchPos currTouches[MAX_TOUCHES];
    int currCount = 0;
    for (int i = 0; i < n && currCount < MAX_TOUCHES; i++) {
        int st = t[i].state;
        if (st >= 1 && st <= 4) {
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
                    CGPoint upPos = CGPointMake(curX, curY);
                    releaseDragAndUnlockCursorLocked();
                    isDragging = 0;
                    pthread_mutex_unlock(&mu);
                    postDragMouseEvent(kCGEventLeftMouseUp, upPos, 0.0, 0.0);
                    pthread_mutex_lock(&mu);
                }
            }
        } else {
            dragCentroidValid = 0;
        }
    }

    if (currCount >= 2 || isDragging) {
        atomic_store_explicit(&multiTouchActive, 1, memory_order_relaxed);
        atomic_store_explicit(&lastMultiTouchT, tn, memory_order_relaxed);
    } else if (currCount == 1 && !mosTouchContactActive) {
        atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);
    }

    if (!isDragging) {
        // --- 1. XỬ LÝ KHỞI ĐỘNG KÉO 3 NGÓN ---
        if (currCount >= 3) {
            double sumX = 0.0, sumY = 0.0;
            for (int i = 0; i < currCount; i++) {
                sumX += currTouches[i].x;
                sumY += currTouches[i].y;
            }
            double curCentroidX = sumX / (double)currCount;
            double curCentroidY = sumY / (double)currCount;

            if (!dragArmed) {
                dragCentroidStartX = curCentroidX;
                dragCentroidStartY = curCentroidY;
                dragArmed = 1;
                armSince = tn;
            } else {
                double dX = (curCentroidX - dragCentroidStartX) * SPEED_FACTOR;
                double dY = -(curCentroidY - dragCentroidStartY) * SPEED_FACTOR;
                double dist = sqrt(dX * dX + dY * dY);

                if (dist >= 1.0) {
                    stopMosScrollImmediately(1);

                    CGPoint pNow = cursorNow();
                    curX = pNow.x;
                    curY = pNow.y;
                    dragTargetDx = 0.0;
                    dragTargetDy = 0.0;
                    prevDragCentroidX = curCentroidX;
                    prevDragCentroidY = curCentroidY;
                    prevDragFingerCount = currCount;
                    dragCentroidValid = 1;
                    lastDragContactT = tn;
                    singleFingerSinceT = 0.0;
                    dragArmed = 0;

                    atomic_store_explicit(&dragging, 1, memory_order_relaxed);
                    isDragging = 1;

                    pthread_mutex_unlock(&mu);
                    postDragMouseEvent(kCGEventLeftMouseDown, pNow, 0.0, 0.0);
                    postDragMouseEvent(kCGEventLeftMouseDragged, pNow, 0.0, 0.0);
                    pthread_mutex_lock(&mu);
                }
            }
        } else {
            dragArmed = 0;
            armSince = 0.0;
        }

        // --- 2. THUẬT TOÁN CUỘN MƯỢT 2 NGÓN (GIỮ NGUYÊN ĐỘ ĐẦM VỪA PHẢI) ---
        double timeSinceTwoFingers = tn - lastTwoFingerT;
        int isTwoFingerScroll = 0;

        if (!isDragging) {
            if (currCount == 2) {
                isTwoFingerScroll = 1;
                lastTwoFingerT = tn;
            } else if (currCount == 1 && mosTouchContactActive && timeSinceTwoFingers < 60.0) {
                isTwoFingerScroll = 1;
            }
        }

        if (isTwoFingerScroll) {
            if (!mosTouchContactActive) {
                if (mosPhaseState == 2) {
                    emitMosScrollEvent(0.0, 0, kCGMomentumScrollPhaseEnd);
                }
                mosPhaseState = 0;
                mosTargetBufferY = 0.0;
                mosVelocityPerTick = 0.0;
                mosPeakVelPerTick = 0.0;
                mosTouchContactActive = 1;
            }

            double matchedDx = 0.0, matchedDy = 0.0;
            int matchedCount = computeMatchedFingerDelta(currTouches, currCount, prevTouches, prevCount, &matchedDx, &matchedDy);

            if (matchedCount > 0) {
                double dt = tn - lastScrollFrameT;
                if (dt < 4.0) dt = 4.0;
                if (dt > 45.0) dt = 12.0;

                if (fabs(matchedDy) > 0.00004) {
                    double sens = atomic_load_explicit(&sensitivityMultiplier, memory_order_relaxed);
                    if (sens < 0.2) sens = 0.2;
                    if (sens > 4.0) sens = 4.0;

                    double rawVel = fabs(matchedDy) / dt;
                    double flickGain = 1.0 + fmin(rawVel * 480.0, 1.40);

                    double BASE_SCALE = 780.0 * sens;
                    double deltaPixels = matchedDy * BASE_SCALE * flickGain;

                    if ((deltaPixels > 2.5 && mosTargetBufferY < -2.0) ||
                        (deltaPixels < -2.5 && mosTargetBufferY > 2.0)) {
                        mosTargetBufferY = deltaPixels;
                        mosVelocityPerTick = 0.0;
                        mosPeakVelPerTick = 0.0;
                    } else {
                        mosTargetBufferY += deltaPixels;
                    }

                    if (mosTargetBufferY > 600.0) mosTargetBufferY = 600.0;
                    if (mosTargetBufferY < -600.0) mosTargetBufferY = -600.0;

                    double instVelPerTick = deltaPixels * (8.33 / dt);
                    mosVelocityPerTick = 0.65 * instVelPerTick + 0.35 * mosVelocityPerTick;

                    if (fabs(instVelPerTick) >= fabs(mosPeakVelPerTick) * 0.85 || (tn - mosPeakVelTime) > 75.0) {
                        mosPeakVelPerTick = instVelPerTick * 1.15;
                        mosPeakVelTime = tn;
                    }
                }
            }
            lastScrollFrameT = tn;
        } else if (!isDragging && currCount < 2) {
            if (mosTouchContactActive && timeSinceTwoFingers >= 60.0) {
                mosTouchContactActive = 0;
                atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);
            }
            if (currCount == 1 && mosPhaseState == 2 && timeSinceTwoFingers > 110.0) {
                stopMosScrollImmediately(0);
            }
        }
    } else {
        // --- 3. ĐANG TRONG PHIÊN KÉO 3 NGÓN (TĂNG TỐC & GIA TỐC NHẠY BÉN) ---
        if (currCount >= 2) {
            double sumX = 0.0, sumY = 0.0;
            for (int i = 0; i < currCount; i++) {
                sumX += currTouches[i].x;
                sumY += currTouches[i].y;
            }
            double curCentroidX = sumX / (double)currCount;
            double curCentroidY = sumY / (double)currCount;

            if (dragCentroidValid && currCount == prevDragFingerCount) {
                double sens = atomic_load_explicit(&sensitivityMultiplier, memory_order_relaxed);
                if (sens < 0.2) sens = 0.2;
                if (sens > 4.0) sens = 4.0;

                double effectiveSpeed = SPEED_FACTOR * sens;
                double rawDx = (curCentroidX - prevDragCentroidX) * effectiveSpeed;
                double rawDy = -(curCentroidY - prevDragCentroidY) * effectiveSpeed;

                double dist = hypot(rawDx, rawDy);
                if (dist < 220.0 && dist > 0.02) {
                    // Gia tốc lũy tiến: di chậm đi chính xác (1.0x), lướt nhanh tăng vọt lên tới 2.30x!
                    double dragGain = 1.0 + fmin(dist * 0.035, 1.30);
                    dragTargetDx += rawDx * dragGain;
                    dragTargetDy += rawDy * dragGain;
                }
            }

            prevDragCentroidX = curCentroidX;
            prevDragCentroidY = curCentroidY;
            prevDragFingerCount = currCount;
            dragCentroidValid = 1;
        } else {
            dragCentroidValid = 0;
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
    if (!atomic_load_explicit(&dragging, memory_order_relaxed)) {
        dragArmed = 0;
        atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);
        pthread_mutex_unlock(&mu);
        return;
    }
    prevCount = 0;
    stopMosScrollImmediately(1);
    CGPoint p = CGPointMake(curX, curY);
    releaseDragAndUnlockCursorLocked();
    pthread_mutex_unlock(&mu);

    postDragMouseEvent(kCGEventLeftMouseUp, p, 0.0, 0.0);
}

// ============================================================================
// VÒNG LẶP NỘI SUY 120Hz (8.33ms TICK)
// ============================================================================
static void tick(CFRunLoopTimerRef timerRef, void *info) {
    (void)timerRef; (void)info;

    if (stopRequested) {
        stopDrag("Dừng ứng dụng");
        return;
    }

    double tn = nowMs();
    int stopNow = 0;
    const char *stopWhy = NULL;
    int emitDragNow = 0;
    CGPoint dragEmitPos = CGPointZero;
    double dragEmitDx = 0.0, dragEmitDy = 0.0;

    pthread_mutex_lock(&mu);
    int isDragging = atomic_load_explicit(&dragging, memory_order_relaxed);
    double touchGap = tn - lastTouchT;
    double twoFingerGap = tn - lastTwoFingerT;
    double dragContactGap = tn - lastDragContactT;

    // 1. Khi người dùng đang KÉO 3 NGÓN:
    if (isDragging) {
        // Tăng hệ số xả lên 0.75 để cửa sổ vọt theo tay nhanh và sát hơn:
        if (fabs(dragTargetDx) >= 0.05 || fabs(dragTargetDy) >= 0.05) {
            dragEmitDx = dragTargetDx * 0.75;
            dragEmitDy = dragTargetDy * 0.75;
            dragTargetDx -= dragEmitDx;
            dragTargetDy -= dragEmitDy;

            curX += dragEmitDx;
            curY += dragEmitDy;
            dragEmitPos = CGPointMake(curX, curY);
            emitDragNow = 1;
        }

        if (dragContactGap >= 380.0) {
            stopNow = 1;
            stopWhy = "Kết thúc phiên kéo 3 ngón";
        }
    }

    // 2. Khi người dùng nhấc 2 ngón tay khỏi bàn rê (Cuộn trang):
    if (!isDragging && mosTouchContactActive && twoFingerGap >= 38.0) {
        mosTouchContactActive = 0;
        atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);

        double launchVel = mosVelocityPerTick;
        if ((tn - mosPeakVelTime) <= 80.0 && fabs(mosPeakVelPerTick) > fabs(launchVel)) {
            launchVel = mosPeakVelPerTick;
        }

        if (mosPhaseState == 1) {
            emitMosScrollEvent(0.0, kCGScrollPhaseEnded, 0);
        }

        if (fabs(launchVel) >= 1.2) {
            mosVelocityPerTick = launchVel;
            if (mosVelocityPerTick > 42.0) mosVelocityPerTick = 42.0;
            if (mosVelocityPerTick < -42.0) mosVelocityPerTick = -42.0;
            mosPhaseState = 2;
            mosTargetBufferY = 0.0;
            emitMosScrollEvent(mosVelocityPerTick, 0, kCGMomentumScrollPhaseBegin);
        } else {
            mosPhaseState = 0;
            mosTargetBufferY = 0.0;
            mosVelocityPerTick = 0.0;
        }
        mosPeakVelPerTick = 0.0;
    }

    if (touchGap >= 45.0 && !isDragging && !mosTouchContactActive) {
        latestPresent = 0;
        dragArmed = 0;
        atomic_store_explicit(&multiTouchActive, 0, memory_order_relaxed);
    }

    // 3A. Khi 2 ngón tay ĐANG CHẠM bàn rê:
    if (!isDragging && mosTouchContactActive) {
        if (fabs(mosTargetBufferY) >= 0.08) {
            double stepY = mosTargetBufferY * 0.35;
            mosTargetBufferY -= stepY;

            uint32_t phase = (mosPhaseState == 0) ? kCGScrollPhaseBegan : kCGScrollPhaseChanged;
            mosPhaseState = 1;
            emitMosScrollEvent(stepY, phase, 0);
        }
    }
    // 3B. Khi ĐÃ NHẤC TAY (Pha trôi quán tính Momentum):
    else if (!isDragging && !mosTouchContactActive && mosPhaseState == 2) {
        double speedRatio = fmin(fabs(mosVelocityPerTick) / 18.0, 1.0);
        double decay = 0.925 + (0.955 - 0.925) * speedRatio;
        mosVelocityPerTick *= decay;

        if (fabs(mosVelocityPerTick) >= 0.18) {
            emitMosScrollEvent(mosVelocityPerTick, 0, kCGMomentumScrollPhaseContinue);
        } else {
            emitMosScrollEvent(0.0, 0, kCGMomentumScrollPhaseEnd);
            mosPhaseState = 0;
            mosVelocityPerTick = 0.0;
        }
    }
    pthread_mutex_unlock(&mu);

    if (emitDragNow) {
        postDragMouseEvent(kCGEventLeftMouseDragged, dragEmitPos, dragEmitDx, dragEmitDy);
    }

    if (stopNow) {
        stopDrag(stopWhy ? stopWhy : "Dừng kéo");
        return;
    }
}

static BOOL trySetupEventTap(void) {
    if (eventTap) return YES;

    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventScrollWheel) |
                       CGEventMaskBit(kCGEventMouseMoved) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventRightMouseDragged) |
                       CGEventMaskBit(kCGEventOtherMouseDragged);
    eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                                kCGEventTapOptionDefault, mask, mouseEventTap, NULL);
    if (eventTap) {
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, kCFRunLoopCommonModes);
        CGEventTapEnable(eventTap, true);
        fprintf(stderr, "[JomaaDrag] Đã tạo thành công CGEventTap!\n");
        return YES;
    }
    return NO;
}

static void detachAndResetTrackpad(void) {
    stopDrag("Trackpad đổi cổng / ngắt kết nối");
    if (connectedDeviceRef) {
        if (MTUnregisterContactFrameCallback) {
            MTUnregisterContactFrameCallback(connectedDeviceRef, touchCallback);
        }
        if (MTDeviceStop) {
            MTDeviceStop(connectedDeviceRef);
        }
    }
    if (deviceListRef) {
        CFRelease(deviceListRef);
        deviceListRef = NULL;
    }
    connectedDeviceRef = NULL;
    attached = 0;
    connectedDeviceId = 0;
}

static void checkAndAttachTrackpad(void) {
    if (!MTDeviceCreateList) return;

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

        MTRegisterContactFrameCallback(externalDev, touchCallback);
        MTDeviceStart(externalDev, 0);
        attached = 1;
        connectedDeviceId = externalId;
        connectedDeviceRef = externalDev;
        deviceListRef = list;
        fprintf(stderr, "[JomaaDrag] Đã kết nối trackpad ngoài: ID=%llu\n", (unsigned long long)externalId);
    } else {
        if (attached) {
            detachAndResetTrackpad();
        }
        CFRelease(list);
    }
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
    tRef = nowMs();

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
        checkAndAttachTrackpad();
    }

    trySetupEventTap();

    timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 0.00833, 0.00833, 0, 0, tick, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);

    [self setupStatusBar];

    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(onWakeFromSleep:)
                                                               name:NSWorkspaceDidWakeNotification
                                                             object:nil];

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
    if (self.customSensitivity < 0.3) self.customSensitivity = 1.0;

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

    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:@"JomaaDrag v15 (Fast 3-Finger Drag)" action:nil keyEquivalent:@""];
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
    detachAndResetTrackpad();
    checkAndAttachTrackpad();
    if (!eventTap) {
        trySetupEventTap();
    }
}

- (void)onPollTimer {
    if (!eventTap) {
        if (trySetupEventTap()) {
            if (self.statusMenuItem) {
                self.statusMenuItem.title = @"Trạng thái: Hoạt động mượt mà 🟢";
            }
        }
    }

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
    stopRequested = 1;
    stopDrag("Người dùng thoát ứng dụng");
    if (timer) CFRelease(timer);
    if (eventTapSource) CFRelease(eventTapSource);
    if (eventTap) CFRelease(eventTap);
    if (hidEventSource) CFRelease(hidEventSource);
    detachAndResetTrackpad();
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    stopRequested = 1;
    stopDrag("Ứng dụng kết thúc");
    detachAndResetTrackpad();
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
