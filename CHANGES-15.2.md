# JomaaDrag 15.2

Based on the preserved installed release, `release/15.1-current`.

- Touch the trackpad again to brake an inertial scroll immediately, even with
  one stationary finger. Empty lift reports leave momentum running normally.
- Resting fingers before lifting no longer launch old scroll velocity.
- Menu → **Cử chỉ Trackpad → Cuộn có quán tính** enables/disables momentum.
  Direct two-finger scrolling stays active. This option defaults to enabled.
- Menu → **Cử chỉ Trackpad → Vuốt 4 ngón** optionally enables four-finger
  workspace gestures: up for Mission Control, down for App Exposé, right for
  the previous desktop and left for the next desktop. It defaults to disabled
  to retain the previous four-or-more-finger drag behavior.
- Four-finger actions use the standard macOS Control-arrow keyboard shortcuts.
  These shortcuts must be enabled with their default mappings in System
  Settings → Keyboard → Keyboard Shortcuts → Mission Control. The action is
  discrete; it does not provide Apple's interactive workspace animation.
- A four-finger gesture fires once per touch sequence, ignores small jitter
  and finger replacement, and consumes trailing contacts until lift. An
  established three-finger drag retains ownership if a fourth finger is added.
- Menu → **Tạm dừng JomaaDrag** releases active gestures and restores physical
  input passthrough. **Tiếp tục JomaaDrag** reattaches with fresh touch history.
  Pause lasts for the current process; gesture option choices persist.
- The menu version comes from the bundle version.

Two-axis scrolling, browser swipes, Option Dash, pinch zoom, three-finger drag,
natural scrolling, sensitivity settings and sleep/disconnect cleanup remain.
No force sensor or haptic actuator is added by software.

## Validation

`make test`: 19 gesture/lifecycle regression scenarios with AddressSanitizer and
UndefinedBehaviorSanitizer. Every generated event and cursor write is intercepted;
tests do not inject system input. New scenarios include all four swipe directions,
single firing and trailing fingers, jitter/identity replacement, existing drag
ownership, momentum braking, stationary release, disabled inertia, pause, and
existing horizontal scrolling/Option Dash, pinch and mouse-wheel passthrough.

`make build`: signed application, compiler warnings treated as errors.

Tests model sensor frames. Physical Jomaa gesture feel, host shortcut mappings,
and per-application gesture compatibility still require hands-on verification.
The app continues to depend on private macOS MultitouchSupport APIs.
