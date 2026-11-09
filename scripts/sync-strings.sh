#!/bin/sh
# Adds the strings the app's code uses to VoxOS/Localizable.xcstrings, from the .stringsdata the
# last `make local` build wrote. Command-line builds never update the catalog themselves (only
# building in Xcode does), so new labels were missing from it and showed untranslated.
# New strings arrive without translations; SettingsSectionTests fails until they have them.
set -eu
cd "$(dirname "$0")/.."
BUILD="${1:-.local-build}"
CATALOG=VoxOS/Localizable.xcstrings
LIST=$(find "$BUILD" -path '*VoxOS.build*' -name '*.stringsdata' ! -name 'ExtractedAppShortcutsMetadata*')
if [ -z "$LIST" ]; then
    echo "No .stringsdata under $BUILD: run make local first." >&2
    exit 1
fi
set --
for f in $LIST; do set -- "$@" --stringsdata "$f"; done
xcrun xcstringstool sync "$CATALOG" "$@"
# xcstringstool leaves off the final newline that Xcode writes.
[ -n "$(tail -c 1 "$CATALOG")" ] && printf '\n' >> "$CATALOG"
echo "Synced $CATALOG from $(echo "$LIST" | wc -l | tr -d ' ') files."
