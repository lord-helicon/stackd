#!/bin/bash
# Builds Stackd and assembles a runnable .app bundle (menu bar app, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

# SWIFT_BUILD_FLAGS: extra `swift build` flags, e.g. --disable-sandbox inside a Homebrew build
# (SwiftPM's own sandbox can't nest in Homebrew's). Intentionally unquoted so it word-splits.
# shellcheck disable=SC2086
swift build -c release ${SWIFT_BUILD_FLAGS:-}

APP="Stackd.app"
rm -rf "$APP" boxd-bar.app  # boxd-bar.app = leftover bundle from the old name
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/stackd "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# Icons: Assets.car from the layered Icon Composer document (macOS 26+, CFBundleIconName), then the
# classic AppIcon.icns fallback (macOS 14/15, CFBundleIconFile) — copied last because actool also
# emits its own AppIcon.icns. Regenerate the artwork with Tools/update-icon.sh.
# actool ships only with full Xcode; with just the Command Line Tools (e.g. a Homebrew build) skip it
# and rely on the .icns.
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
        --include-all-app-icons --platform macosx --target-device mac --minimum-deployment-target 14.0 \
        --output-partial-info-plist /dev/null --output-format human-readable-text >/dev/null
else
    echo "note: actool not found (needs full Xcode) — skipping Assets.car, using AppIcon.icns only"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The Keychain re-prompts for the login password unless the app's partition ID stays the same
# across builds, which needs a Team ID. Preference: SIGN_IDENTITY=… override, then an
# "Apple Development" certificate (free Apple ID: Xcode → Settings → Accounts → Manage
# Certificates → + → Apple Development; partition teamid:… → one "Always Allow" lasts), then
# the self-signed "boxd-bar dev" (no Team ID → partition is the build's cdhash → prompts after
# every rebuild), then ad hoc.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    # Not -v: without Apple's WWDR intermediate installed the cert isn't "valid", but codesign
    # still embeds its Team ID, which is all the Keychain partition check needs.
    IDENTITY=$(security find-identity -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$IDENTITY" ] && security find-identity -p codesigning | grep -q '"boxd-bar dev"'; then
    IDENTITY="boxd-bar dev"
    echo "note: signing with self-signed \"boxd-bar dev\" (no Team ID) — Keychain re-prompts after each build"
fi
if [ -n "$IDENTITY" ]; then
    # An Apple Development cert fails with errSecInternalComponent until Apple's WWDR G3
    # intermediate is installed; fall back instead of leaving an unsigned bundle behind.
    if ! codesign --force -s "$IDENTITY" "$APP" 2>/dev/null && [ "$IDENTITY" != "boxd-bar dev" ] \
        && security find-identity -p codesigning | grep -q '"boxd-bar dev"'; then
        echo "note: signing with \"$IDENTITY\" failed (missing WWDR G3 intermediate?) — using \"boxd-bar dev\""
        codesign --force -s "boxd-bar dev" "$APP"
    fi
else
    echo "note: no signing identity — signing ad hoc (Keychain re-prompts after each build)"
    codesign --force -s - "$APP"
fi

echo "Built $PWD/$APP ($(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true))"
if [ "${1:-}" = "--run" ]; then open "$APP"; fi  # not `[ … ] && …`: as the last line it set exit status 1
