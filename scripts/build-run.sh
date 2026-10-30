#!/usr/bin/env bash
#
# Build MPX Prime Studio and MPX Prime Meter (release, this Mac's
# architecture), sign them with the local development identity, install them
# in /Applications and open the Studio. Always run the apps from there: one
# fixed path and one stable signature keep the Dock item, Launch Services and
# the Microphone permission pointing at the same app.
#
#   scripts/build-run.sh                 # both apps, then open the Studio
#   scripts/build-run.sh --meter         # both apps, then open the Meter
#   scripts/build-run.sh --studio-only   # the Studio only (no Homebrew tuner libs needed)
#   scripts/build-run.sh --no-open       # build and install, open nothing
#   scripts/build-run.sh -- --nogui      # arguments after -- go to the opened app
#
# A running copy is quit gracefully first, never killed; if it does not quit,
# nothing is replaced. Create the signing identity once with
# scripts/make-signing-identity.sh; without it the apps are signed ad hoc and
# macOS asks for the Microphone again after every build. For the release DMG
# use scripts/build-release.sh.
set -euo pipefail

# shellcheck source=scripts/build-env.sh
. "$(dirname "$0")/build-env.sh"
# shellcheck source=scripts/app-bundle.sh
. scripts/app-bundle.sh

OPEN="studio"
WITH_METER=1
APP_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
    --meter) OPEN="meter" ;;
    --studio-only) WITH_METER=0 ;;
    --no-open) OPEN="" ;;
    --)
        shift
        APP_ARGS=("$@")
        break
        ;;
    -h | --help)
        sed -n '2,/^set -/p' "$0" | sed '$d' | cut -c3-
        exit 0
        ;;
    *)
        echo "error: unknown option $1 (see --help)" >&2
        exit 2
        ;;
    esac
    shift
done
if [ "$OPEN" = "meter" ] && [ "$WITH_METER" = 0 ]; then
    echo "error: --meter needs the Meter; drop --studio-only" >&2
    exit 2
fi

VERSION="$(scripts/version.sh)"
STAGE="$BUILD_DIR/apps"
STUDIO_ID="com.mpxprime.app"
METER_ID="com.mpxprime.meter"
INSTALL_DIR="/Applications"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/mpx-prime-dev.keychain-db"
SIGNING_IDENTITY="MPX Prime Development"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ "$WITH_METER" = 1 ]; then
    scripts/build.sh release
else
    scripts/build.sh release --product MPXPrime
fi
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$STAGE"
mkdir -p "$STAGE"
bundle_studio "$STAGE/$APP_NAME.app" "$VERSION" "$BIN_DIR/MPXPrime"
[ "$WITH_METER" = 1 ] && bundle_meter "$STAGE/$METER_APP_NAME.app" "$VERSION" "$BIN_DIR/MPXPrimeMeter"

# Sign with the stable identity when it exists, so macOS keeps the Microphone
# permission across builds; otherwise ad hoc, as the release does.
sign() {
    local app="$1" identifier="$2"
    if [ -f "$SIGNING_KEYCHAIN" ]; then
        security unlock-keychain -p mpx-prime-dev "$SIGNING_KEYCHAIN"
        codesign --force --deep --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN" \
            --identifier "$identifier" "$app"
    else
        codesign --force --deep --sign - --identifier "$identifier" "$app"
    fi
    codesign --verify --deep --strict "$app"
}
if [ ! -f "$SIGNING_KEYCHAIN" ]; then
    echo "note: no development signing identity; run scripts/make-signing-identity.sh once." >&2
fi
sign "$STAGE/$APP_NAME.app" "$STUDIO_ID"
[ "$WITH_METER" = 1 ] && sign "$STAGE/$METER_APP_NAME.app" "$METER_ID"

# Quit a running copy gracefully. A copy started from .build by scripts/run.sh
# is not an app bundle and cannot be asked to quit; it is left running, the new
# app is installed beside it, and nothing is opened, so two never run at once.
quit_running() {
    local bundle_id="$1" process="$2" label="$3"
    pgrep -x "$process" >/dev/null || return 0
    if pgrep -fl "/$process( |$)" | grep -q "\.build/"; then
        echo "note: $label is running from .build (scripts/run.sh) and was left running." >&2
        echo "      The new app is installed; quit that copy, then open it from $INSTALL_DIR." >&2
        OPEN=""
        return 0
    fi
    echo "Quitting the running $label..."
    osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
    for _ in $(seq 1 100); do
        pgrep -x "$process" >/dev/null || return 0
        sleep 0.1
    done
    echo "error: $label has not quit; nothing was installed." >&2
    exit 1
}
quit_running "$STUDIO_ID" MPXPrime "$APP_NAME"
[ "$WITH_METER" = 1 ] && quit_running "$METER_ID" MPXPrimeMeter "$METER_APP_NAME"

install_app() {
    local name="$1"
    rm -rf "$INSTALL_DIR/$name.app"
    ditto "$STAGE/$name.app" "$INSTALL_DIR/$name.app"
    "$LSREGISTER" -u "$STAGE/$name.app" 2>/dev/null || true
    "$LSREGISTER" -f "$INSTALL_DIR/$name.app"
    echo "Installed $INSTALL_DIR/$name.app ($VERSION)"
}
install_app "$APP_NAME"
[ "$WITH_METER" = 1 ] && install_app "$METER_APP_NAME"

case "$OPEN" in
studio) open "$INSTALL_DIR/$APP_NAME.app" --args "${APP_ARGS[@]+"${APP_ARGS[@]}"}" ;;
meter) open "$INSTALL_DIR/$METER_APP_NAME.app" --args "${APP_ARGS[@]+"${APP_ARGS[@]}"}" ;;
esac
