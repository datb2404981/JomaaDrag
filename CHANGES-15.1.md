# JomaaDrag 15.1

Based on the v15 source, including horizontal scrolling, browser swipes,
Option Dash, and pinch zoom.

- Track dragging by matching finger identifiers. Replacing one finger no longer
  moves the centroid and jumps the cursor; movement continues through 3-to-2
  finger transitions.
- Release a drag after a 45 ms grace when all contacts are lifted, while keeping
  the existing 380 ms fallback for missing sensor reports. Finish buffered
  movement before releasing the mouse button.
- Serialize mouse-down, movement, and mouse-up events across input callbacks
  and the interpolation timer.
- Close the callback gate before disconnecting a device. Reset scroll, zoom,
  momentum, and touch history even when no drag is active.
- Suspend input before sleep; restore attachment after wake. Avoid intercepting
  input without a working event tap and recover after Accessibility changes.
- Validate private framework symbols, touch coordinates, and numeric settings.
  Gesture deadlines now use monotonic time.
- Invalidate timers and event taps before releasing resources; handle ordinary
  SIGTERM/SIGINT shutdown through the main run loop.
- Keep the preferences window reusable after its close button is clicked.
- Align the bundle and menu version at 15.1.

## Validation

Run `make test` for 10 regression scenarios with AddressSanitizer and
UndefinedBehaviorSanitizer. Tests intercept all generated input and cursor writes.
They cover finger replacement/dropout, false drag activation, lift/release,
scroll/zoom reset, late callbacks, invalid input/permission gating, sleep,
concurrent event ordering, and repeated shutdown.

Run `make build` to produce a signed app with compiler warnings treated as errors.

Hardware feel, pinch behavior in individual apps, and sleep/wake with a physical
Jomaa trackpad still need interactive validation. The private MultitouchSupport
API may differ across macOS releases.
