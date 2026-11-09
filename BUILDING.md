# Building VoxOS

## Requirements

- macOS 14.4 or later (the app's deployment target; it builds against the macOS 26 SDK)
- Xcode 26 with the Command Line Tools
- Git
- The Metal toolchain, once: `xcodebuild -downloadComponent MetalToolchain`

## Local build

```bash
git clone https://github.com/achyuthkp27/VoxOs.git
cd VoxOs
make local
```

`make local` prepares `whisper.xcframework` in `~/VoxOS-Dependencies`, builds in `.local-build`
(SwiftPM checkouts are kept in `.local-packages` so they are not re-cloned on every build), and
installs `VoxOS.app` to `/Applications`. Nothing is left in `~/Downloads`.

It uses `LocalBuild.xcconfig`, `VoxOS/VoxOS.local.entitlements` and the `LOCAL_BUILD` Swift flag.
Without an override it uses the only available Apple Development identity, or falls back to
ad-hoc signing when none or several are found.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

For an optimised app (slower to build, faster to run):

```bash
make local LOCAL_CONFIG=Release
```

Local builds do not include iCloud dictionary sync or automatic updates. Ad-hoc builds may ask
for macOS permissions again after a rebuild.

## Other commands

- `make check` — verify the required tools
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build, install and launch the app
- `make run` — launch the installed app
- `make test` — run the test suite (see "Development" in the README)
- `make lint` / `make format` — check or apply swift-format
- `make hooks` — run `make lint` before every `git push` (once per clone)
- `make strings` — add new UI strings to `Localizable.xcstrings` after `make local`; translate them before committing
- `make release` — build the signed DMG and Sparkle appcast from `release-notes/<version>.html`
- `make release-setup` — store notarization credentials in Keychain
- `make clean` — remove build artifacts
- `make help` — list every target

## Build with Xcode

```bash
make setup
open VoxOS.xcodeproj
```

Select the `VoxOS` scheme and the Debug configuration. Xcode uses the project's normal signing
settings; `LOCAL_BUILD` applies only through `make local`.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/achyuthkp27/VoxOs/issues).
