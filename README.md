<div align="center">
  <img src="VoxOS/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="180" height="180" />
  <h1>VoxOS</h1>
  <p>A native macOS voice dictation + voice-to-action agent, for personal use</p>

  [![CI](https://github.com/achyuthkp27/VoxOs/actions/workflows/ci.yml/badge.svg)](https://github.com/achyuthkp27/VoxOs/actions/workflows/ci.yml)
  [![License](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
  ![Platform](https://img.shields.io/badge/platform-macOS%2014.4%2B-brightgreen)
</div>

---

VoxOS is a native macOS voice dictation and voice-to-action agent, built for my own day-to-day use —
not distributed or sold.

It does two things:

1. **Dictation** — hold a shortcut, speak, and it transcribes locally (Whisper / Parakeet) and pastes cleaned-up
   text wherever your cursor is.
2. **Agent Mode** — hold a different shortcut, speak a request, and it acts on your Mac: add calendar events,
   set reminders, draft emails, send WhatsApp/Slack/iMessage messages, find files, open apps and URLs, and more,
   using a provider-agnostic JSON tool-calling loop (works with local Ollama, Local CLI, or any hosted provider).

## Features

- 🎙️ **Local transcription** — Whisper.cpp / Parakeet models, fully offline
- 🤖 **Agent Mode** — 90+ voice-triggered tools: calendar, reminders, notes, mail drafts, WhatsApp, Slack,
  Linear, iMessage, memory, system utilities — plus full **computer control**: click UI by name through the
  Accessibility tree, OCR and on-screen set-of-marks ("click 7"), synthetic mouse/keyboard, window management,
  shell and AppleScript behind a risk gate, files and PDFs, browser DOM control, macros ("teach it a skill"),
  JSON plugins the agent can write and repair itself, screen/audio watchers, and control modes
  (act freely / ask before acting / observe only)
- 🔊 **System audio** — `⌃/` captures what the Mac is playing (never the mic), transcribes it, copies and
  pastes it; `⌃⇧/` transcribes the last N seconds from a rolling buffer; also callable by the agent
- 🪟 **Liquid Glass UI** — macOS Tahoe glass throughout: floating sidebar, glass cards, translucent notch panel,
  left-edge history card (hover the screen edge, click the notch, pin with the lock)
- ⚡ **One-click Agent setup** — a quick-install button wires up a working AI provider, the built-in Agent
  prompt, and a Control+Option hold-to-talk shortcut automatically
- 🧠 **Modes** — per-app/per-URL configuration for transcription + AI enhancement behavior
- 🔒 **Privacy-first** — transcription is always local; the agent loop can run entirely on-device via Ollama
- 🖥️ **Notch-docked recorder UI** — a compact panel that molds around the camera notch, with a left-edge
  hover history sidebar for past interactions

## Build

`make local` builds, signs with your Apple Development identity and installs to `/Applications`;
`make dev` does both build and launch. Run `make help` for the full target list.

See [BUILDING.md](BUILDING.md) for the general build instructions. This fork additionally requires:

```shell
xcodebuild -project VoxOS.xcodeproj -scheme VoxOS -configuration Debug \
  -derivedDataPath "$PWD/.local-build" \
  -xcconfig LocalBuild.xcconfig \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$PWD/VoxOS/VoxOS.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  build
```

(Needs the Metal toolchain installed once via `xcodebuild -downloadComponent MetalToolchain`.)

## Development

| command | what it does |
| --- | --- |
| `make local` | Build, sign, install to `/Applications` |
| `make dev` | `make local` then launch |
| `make test` | Run the test suite (72 tests) |
| `make lint` | Check formatting with swift-format |
| `make format` | Reformat sources in place |

`make test` scores the run from its `.xcresult` bundle rather than the xcodebuild console,
so it reports every test and fails the build when any of them fail:

```
Passed: 71 passed, 0 failed, 1 skipped (72 total)
```

The skipped test is a live MCP check; enable it with `TEST_RUNNER_VOXOS_LIVE_MCP=1 make test`.
The full xcodebuild log is written to `.local-build-tests/test.log`.

Formatting is enforced by [`.swift-format`](.swift-format). Two rules are deliberately off:
`AlwaysUseLowerCamelCase`, because it cannot tell a `Codable` property whose name is a
wire-format JSON key from a badly named constant, and `ReplaceForEachWithForLoop`, which is
a style opinion with no behavioural effect.

The tree was reformatted in one sweep; [`.git-blame-ignore-revs`](.git-blame-ignore-revs) keeps
that commit out of `git blame`. Enable it locally with:

```shell
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

### Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs `make test` and `make lint` on a
clean macOS runner for every push and pull request. The whisper.xcframework is cached against
the pinned `WHISPER_CPP_REF` in the [Makefile](Makefile), so only the first run pays for
building it.

Dependencies are pinned by revision rather than tracking branches, and `Package.resolved` is
committed, so every machine and CI build the same tree.

## Requirements

- macOS 14.4 or later

## License

Licensed under the GNU General Public License v3.0 — see [LICENSE](LICENSE).

## Acknowledgments

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — Whisper model inference
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet model implementation
- [TranscribeCpp for Swift](https://github.com/Beingpax/Transcribe-cpp-swift) — local GGUF transcription models
- [SenseVoice Small](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) — multilingual model
- [Sparkle](https://github.com/sparkle-project/Sparkle), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts),
  [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin), [MediaRemoteAdapter](https://github.com/ejbills/mediaremote-adapter),
  [Zip](https://github.com/marmelroy/Zip), [SelectedTextKit](https://github.com/tisfeng/SelectedTextKit),
  [Swift Atomics](https://github.com/apple/swift-atomics)

---

Personal project by Achyuth KP.
