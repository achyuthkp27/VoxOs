# ADR 0007 — Notch Home: one surface between dictations

Status: accepted (2026-10-28)

Notch Home (`NotchHomeManager`) is its own persistent panel at `.statusBar + 1`, under Claude
Code's cards (`+2`) and the recorder (`+3`), which both hide it. Collapsed it shows one thing at
a time — a notice (a device, the sound output, the power, a finished timer), the next meeting, a
microphone or camera in use, a running timer, the playing track — and otherwise a notch-sized
black target that disappears into the hardware notch. Only the top strip of the notch opens it on
hover (browser tabs sit right under the notch); the band's wings do not, so the pointer can cross
them to the menu bar. Open, it is one card of fixed height with five pages walked by a sideways
swipe or click-drag: Music, Calendar, Reminders, Pomodoro, Shelf.

Decisions, and what they rest on (measured on macOS 26 unless noted):
- **Music bars.** Real bars come from a Core Audio process tap (`SystemAudioLevels`), not
  ScreenCaptureKit, but any system-audio capture lights macOS's purple recording dot. So the tap
  runs only if Live Music Bars is on (off by default), and then only while live bars are on
  screen (the band or the open Music page); with it off, the bars are ambient and listen to
  nothing. A click on the player's bars switches the setting.
- **Battery.** Nothing polls without a reason. Live bars fall back to ambient in Low Power Mode
  and, if the user says so, on battery (`PowerState`). The tap lingers 3 s after the bars hide,
  because a hover that opens the card over the band would otherwise rebuild it each time. Bar
  timers tick at 30 Hz live and 20 Hz ambient, only while their window is visible and the
  displays are awake. Claude Code's checks run every 0.5 s only while a card waits, and the
  main-thread watchdog rests while the screen sleeps or is locked.
- **Several players.** MediaRemote names one player. Music and Spotify are followed through their
  distributed notifications and AppleScript (`NotchPlayers`) beside MediaRemote's player, and the
  card's controls act on the player shown.
- **Menu bar.** Status items are drawn into the menu bar, not as windows, so free space beside the
  notch is read through Accessibility, off the main thread with a short timeout per app; a band
  that lasts (music, a timer) is not drawn where it would cover an item.
- **Gestures.** Closed: toward the middle puts a band away, outward brings it back. Open:
  sideways turns pages, up and down changes player. Scroll phases are read from a local event
  monitor; momentum is ignored.
- **Permissions.** Calendar, Reminders and Bluetooth need their usage strings and, under the
  hardened runtime, the matching entitlements (`personal-information.calendars`,
  `device.bluetooth`); without them requests fail silently or block. Calendar and Reminders are
  asked for from their pages, never at launch, and the request's own answer is trusted: the status
  read still said "not determined" in the same run after the user allowed.
- **Mic and camera.** Core Audio's process objects say which processes run input, so VoxOS's own
  dictation is left out and the app can be named (a helper traced to its app); CoreMediaIO says
  whether a camera runs, not for whom. Listeners only. The mute uses the input's own mute, or its
  volume, and is undone when the call ends or VoxOS quits, so a dictation never records muted.
- **Meetings.** From the calendar the Calendar page already reads, and only once access is
  granted: timed, not cancelled, not declined; shown from five minutes before to five after the
  start, with Join for a known video-call host. Re-read when the calendar changes and on a timer
  set for the next moment the answer can change.
- **Drag to the shelf.** A global mouse monitor reads the drag pasteboard's count on mouse-down;
  a later drag that wrote file URLs and reaches the open card's area (plus a margin) opens the
  card on the Shelf page, and the card stays while the file is in that area.
- **Nothing is fixed to one Mac.** Icons come from Bluetooth device classes, sizes from the
  screen's notch, players from bundle ids; tests use generic names.
