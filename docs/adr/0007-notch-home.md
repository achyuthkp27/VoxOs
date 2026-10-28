# ADR 0007 — Notch Home: one surface between dictations

Status: accepted (2026-10-28)

Notch Home (`NotchHomeManager`) is its own persistent panel at `.statusBar + 1`, under Claude
Code's cards (`+2`) and the recorder (`+3`), which both hide it. Collapsed it shows one thing at
a time — a notice (a device, a finished timer), a running timer, the playing track — and
otherwise a notch-sized black target that disappears into the hardware notch. Only the notch
itself opens it on hover; the band's wings do not, so the pointer can cross them to the menu
bar. Open, it is one card of fixed height with five pages walked by a sideways swipe or
click-drag: Music, Calendar, Reminders, Pomodoro, Shelf.

Decisions, and what they rest on (measured on macOS 26 unless noted):
- **Music bars.** Real bars come from a Core Audio process tap (`SystemAudioLevels`), not
  ScreenCaptureKit, but any system-audio capture lights macOS's purple recording dot. So the tap
  runs only if Live Music Bars is on (off by default), and then only while live bars are on
  screen (the band or the open Music page); with it off, the bars are ambient and listen to
  nothing.
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
- **Nothing is fixed to one Mac.** Icons come from Bluetooth device classes, sizes from the
  screen's notch, players from bundle ids; tests use generic names.
