# VoxOS design language — "Prism Glass" (14 Oct 2026)

Your voice is one beam of light; VoxOS splits it into modes. The app is a calm, dark violet glass
shell (from the user's purple mock-up) where colour carries meaning: the brand violet marks what is
active, and each **mode** has its own colour from a spectrum (the prism). Native macOS (SwiftUI),
not a web template.

## Tokens (use these, never raw colours)
- Ground: dark window with a soft ambient violet glow behind content (shell only, set once in the
  shell — pages never add their own glows).
- Text: `AppTheme.Text.primary / secondary / muted`.
- Surfaces: cards `AppTheme.Surface.card` fill + `AppTheme.Border.card` 1pt stroke, corner radius
  **14** (rows inside grouped lists: dividers, no per-row cards), padding 16–18. Hover:
  `Surface.subtle`/`Surface.control`. No drop shadows, no per-card gradients or glows.
- Accent (brand violet): `AppTheme.Accent.primary`, fills `Accent.fillSubtle/fill`, stroke
  `Accent.border`, selection `Selection.border`. Use for: selected nav item, primary button (one per
  screen at most), active/"in use" state.
- Mode colour: `ModeSpectrum.color(for:)` / `color(forModeNamed:)` → `AppTheme.Spectrum`. Use for a
  mode's icon tile tint (colour at ~0.18 opacity fill + full-colour glyph), a 3pt leading bar or dot
  in History rows, chart bands. Never for unrelated decoration.
- Type: page titles `Font.appDisplay(size: 30)` (serif, via `AppScreenHeader`); section eyebrows
  `Font.appMono(size: 11, weight: .medium)` uppercase, tracking 0.6, `Text.secondary`; body
  `Font.app(size: 13–14)`; figures/shortcuts/times `Font.appMono`.
- Controls: native where possible — segmented `Picker` for tabs, `Toggle.switch` small for on/off,
  `.borderedProminent` tinted accent for the one primary action, `.bordered` otherwise.
- Motion: subtle (0.15–0.3s ease); respect Reduce Motion (`@Environment(\.accessibilityReduceMotion)`).

## Copy
Sentence case, from the user's side, plain verbs ("Change mode", "Drop audio or video files here").
Empty states say what to do. Errors say what happened and how to fix it.

## Signature
Mode colour is the prism: your voice splits into modes, and each mode keeps its colour wherever it
appears — the "By mode" bars on the Dashboard, the dots in History, the icon tiles in Modes.

## Dashboard structure (from the reference dashboards)
Serif greeting with a mode chip; one hero metric (words dictated, range picker, change pill, a wide
thin accent line chart); four equal stat tiles with sparklines; "By mode" bars beside an "Activity"
calendar heatmap; recent dictations; quick-action keys on one line.
