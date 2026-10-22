# JomaaDrag 15.2.2

Handle short fourth-finger dropouts observed on the physical Jomaa trackpad.

- Claim a four-finger gesture after four active contacts are observed. Keep
  using ID-matched movement from at least three valid contacts for up to
  180 ms after the fourth contact disappears. This covers brief 4 → 3 drops
  without requiring four stable contacts in every frame.
- Require actual four-contact evidence before accepting a four-finger gesture.
  Three-finger movement alone never establishes that evidence. Expired evidence
  cannot launch a workspace action; trailing contacts remain consumed until lift.
- Separate contact presence from coordinate validity. Four active records with
  one invalid coordinate may establish presence if three valid points remain.
  Invalid coordinates are never used to calculate movement.
- Retain one action per touch sequence, existing drag ownership, shortcut
  configuration, pause, scrolling, pinch and cleanup behavior.
- Report the maximum active contact count before coordinate filtering, and
  log whether a four-contact attempt arrived after dragging had already begun.

## Physical diagnosis and verification

The user reproduced the failure with four fingers. Early Multitouch samples
showed no more than three contacts. Later read-only capture observed four active
contacts briefly, followed immediately by three active contacts (the missing
contact reported state 7). This disproved the initial suspicion that the active
Multitouch stream could never report four contacts.

After the user granted Input Monitoring to the diagnostic host, IOHID opened
successfully. The sampled HID metadata included report ID 0x02 with length 8;
the separate Windows digitizer contact-count field produced no samples. The
descriptor's five contact slots do not establish a working five-contact stream
in the current device mode. No firmware or input-mode change was made.

The standalone probes were stopped before testing the installed application.
The user confirmed that gestures worked on 15.2.2 after testing upward and
horizontal four-finger swipes. This is a user-reported hardware result; other
devices, every application and every macOS version have not been verified.

`make test`: 24 scenarios pass with AddressSanitizer and UndefinedBehaviorSanitizer,
with event and cursor output intercepted. New regressions cover a brief fourth
contact dropout, expiry of four-contact evidence, and a fourth contact whose
coordinate is invalid. `make build` and strict installed signature verification
pass. The installed executable digest matches the built candidate.
