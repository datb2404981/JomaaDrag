# JomaaDrag 15.2.1

Fix four-finger gestures that were enabled but did not activate.

- When four-finger gestures are enabled, wait 60 ms before committing three
  contacts to a drag. This lets staggered four-finger landings settle. Once a
  drag is established, adding another finger still keeps the drag active.
  With four-finger gestures disabled, drag activation retains its original timing.
- Read the configured macOS Mission Control/App Exposé/previous desktop/next
  desktop shortcuts, including custom keys and modifier flags, rather than
  hardcoding Control + arrow and removing the arrow/Fn modifier.
- Post the keyboard pair at the HID event tap so system hotkeys can see it.
- Handle disabled or unassigned shortcuts without sending an unrelated key.
  Refresh shortcut mappings once per second to pick up settings changes.
- Show the maximum finger count observed in the menu, and flag missing shortcuts.
  Add a menu link to keyboard shortcut settings. Local logs record recognition
  and dispatched actions without recording finger coordinates or typed text.

## Verification

`make test` passes 21 gesture/lifecycle scenarios with AddressSanitizer and
UndefinedBehaviorSanitizer. All event output is intercepted. Added regressions
cover staggered 3 → 4 finger landing and real/custom/disabled/malformed hotkey
configurations; existing gesture, momentum and lifecycle scenarios still pass.

`make build` passes with warnings treated as errors. The installed application's
signature was verified and its executable digest matches the built candidate.

On the affected machine, four-finger recognition was already enabled. The
previous/next desktop symbolic shortcuts (79/81) were disabled. Those shortcuts
were enabled and App Exposé (33) was explicitly configured, with the old system
preferences backed up outside the repository. The application reads these
settings; it never enables system shortcuts itself.

Physical gestures still require a user trial. The menu's finger count and local
recognition logs distinguish missing sensor contacts from missing system actions.
Desktop switching requires an adjacent desktop or full-screen Space.
