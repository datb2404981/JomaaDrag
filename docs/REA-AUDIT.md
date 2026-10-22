# REA inspection of the installed JomaaDrag

Inspection date: 2026-10-22. Tool: `rea-agents` 6.7.0, installed locally from the
official npm package linked by <https://github.com/morluto/rea>.

The repository source is available separately in the local tools checkout.
REA runs through its CLI in this task; no Codex MCP registration is claimed.

## Shipped-artifact observations

REA `inspect-macho`, `inspect-plist`, and `inspect-signature` ran against
`/Applications/JomaaDrag.app` before modification. The complete local Evidence
JSON records are kept in the ignored `evidence/` directory.

- Executable SHA-256:
  `2413de1b2bbc48061302c003bd732d237e37ebb27dad7f8081b0101a281201cb`.
- Version: 15.1. Bundle identifier: `com.jomaa.drag`. Menu bar application
  (`LSUIElement = true`). Minimum macOS version: 12.0.
- A single ARM64 architecture was observed; the installed binary is not universal.
- Signed with designated requirement `identifier "com.jomaa.drag"` and no team
  identifier. REA's signature inspection does not establish notarization or trust.
- The preserved original 15.1 build has the identical executable digest.
  Its source and regression tests are in `release/15.1-current`.

Evidence IDs:

- Mach-O: `ev_408f21ee03f764b0c94a87a2a43215771b0ae4bb42e14d5f4aca27ef42c6129c`
- Plist: `ev_dc7c35a66fdbf781ee6843409b59334af256e451ef3804f3f640749234854d1c`
- Signature: `ev_c999a1109697eb1d24296a34fc199ef819f3e43a7caf553553a73b2e4ce2cb4d`

## Source-derived findings and changes

Source inspection, rather than binary decompilation, established the existing
scroll, pinch, browser swipe, Option Dash and dragging logic. It also showed
that a stationary finger could leave momentum running briefly, and that the
last scroll velocity could survive a long stationary hold before release.
Version 15.2 adds immediate braking on contact and expires that stale velocity.

Four-finger workspace gestures, a momentum option, and pause/resume are additive;
four-finger recognition is opt-in. See [CHANGES-15.2.md](../CHANGES-15.2.md) for
behavior, defaults, verification and limitations.

Reference gesture expectations: [Apple's Multi-Touch gesture guide](https://support.apple.com/en-gb/102482).

No Hopper/Ghidra decompilation or physical sensor replay was performed. REA's
artifact checks establish packaging facts; the regression suite establishes
behavior for simulated frames. Neither proves identical hardware feel to an
Apple trackpad, Force Touch, haptic feedback or interactive Spaces animations.
