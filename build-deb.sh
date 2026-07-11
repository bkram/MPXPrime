#!/usr/bin/env bash
#
# Build a Debian/Ubuntu package for the MPX Prime Studio encoder (Linux CLI:
# headless encoder + REST API/web dashboard). Run ON the target Ubuntu
# release after `swift build --package-path macOS -c release
# --product MPXPrime --static-swift-stdlib` (the Swift runtime is static;
# system deps are resolved by dpkg-shlibdeps at package time).
#
#   ./build-deb.sh <version> [distro-label]
#   ./build-deb.sh 0.42 ubuntu-24.04   -> mpxprime_0.42-ubuntu24.04_amd64.deb
#
# Installs:
#   /usr/bin/mpxprime                    the encoder (MPXPrime binary)
#   /lib/systemd/system/mpxprime.service systemd unit (disabled by default)
#   /usr/share/mpxprime/                 sample config
#   /usr/share/doc/mpxprime/             manual, README, changelog
# The service runs as the dedicated `mpxprime` system user (created on
# install, member of `audio`) with its config at
# /var/lib/mpxprime/MPXPrime.ini (created with defaults on first run; the
# REST API persists changes there).
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:?usage: ./build-deb.sh <version> [distro-label]}"
DISTRO="${2:-}"
BIN="macOS/.build/release/MPXPrime"
[ -x "$BIN" ] || { echo "error: build first: swift build --package-path macOS -c release --product MPXPrime --static-swift-stdlib" >&2; exit 1; }

DEBVER="$VERSION"
if [ -n "$DISTRO" ]; then
    DEBVER="${VERSION}-${DISTRO//-/}"
fi
STAGE="$(mktemp -d)/mpxprime_${DEBVER}_amd64"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/lib/systemd/system" \
    "$STAGE/usr/share/mpxprime" "$STAGE/usr/share/doc/mpxprime"

install -m 0755 "$BIN" "$STAGE/usr/bin/mpxprime"
# SPM resource bundle (web dashboard); Bundle.module resolves it relative to
# the executable, so it must live next to the binary.
RESOURCES="$(dirname "$BIN")/MPXPrime_MPXPrime.resources"
if [ -d "$RESOURCES" ]; then
    cp -R "$RESOURCES" "$STAGE/usr/bin/"
else
    echo "warning: resource bundle not found; dashboard will serve the stub" >&2
fi
install -m 0644 macOS/MPXPrime.ini "$STAGE/usr/share/mpxprime/MPXPrime.sample.ini"
install -m 0644 docs/manual.md README.md CHANGELOG.md "$STAGE/usr/share/doc/mpxprime/"
install -m 0644 LICENSE "$STAGE/usr/share/doc/mpxprime/copyright"

cat > "$STAGE/lib/systemd/system/mpxprime.service" <<'EOF'
[Unit]
Description=MPX Prime Studio FM composite encoder (headless)
Documentation=file:/usr/share/doc/mpxprime/manual.md
After=sound.target network.target

[Service]
Type=exec
User=mpxprime
Group=audio
ExecStart=/usr/bin/mpxprime --nogui --config /var/lib/mpxprime/MPXPrime.ini
Restart=on-failure
RestartSec=3
# Real-time-friendly scheduling for the audio threads (best-effort in the
# engine; this grants the headroom).
LimitRTPRIO=70
LimitMEMLOCK=64M

[Install]
WantedBy=multi-user.target
EOF

# Control metadata. Depends are computed from the binary's actual linkage
# via dpkg-shlibdeps when available; the fallback list covers Ubuntu 24.04+.
DEPENDS="libasound2t64 | libasound2, libcurl4t64 | libcurl4, libxml2, libc6 (>= 2.38)"
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
    SHLIB_DIR="$(mktemp -d)"
    (
        cd "$SHLIB_DIR"
        mkdir -p debian
        touch debian/control
        if dpkg-shlibdeps -O "$STAGE/usr/bin/mpxprime" > shlibs.out 2>/dev/null; then
            COMPUTED="$(sed -n 's/^shlibs:Depends=//p' shlibs.out)"
            [ -n "$COMPUTED" ] && echo "$COMPUTED" > depends.txt
        fi
    )
    [ -f "$SHLIB_DIR/depends.txt" ] && DEPENDS="$(cat "$SHLIB_DIR/depends.txt")"
    rm -rf "$SHLIB_DIR"
fi

cat > "$STAGE/DEBIAN/control" <<EOF
Package: mpxprime
Version: ${DEBVER}
Section: sound
Priority: optional
Architecture: amd64
Depends: ${DEPENDS}
Maintainer: MPX Prime Project <noreply@example.invalid>
Homepage: https://github.com/bkram/MPXPrime
Description: FM composite (MPX) encoder with RDS - headless + web control
 Real-time broadcast-style FM stereo encoder producing a 192 kHz MPX
 composite (pilot, stereo subcarrier, RDS) through an ALSA output,
 with a full audio processing chain (AGC, multiband, clippers,
 limiters) and an embedded REST API + web dashboard for local or
 remote control. Experimental software: not certified for licensed
 broadcast use without verification.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if ! getent passwd mpxprime >/dev/null; then
    adduser --system --group --home /var/lib/mpxprime \
        --gecos "MPX Prime encoder" mpxprime
fi
adduser mpxprime audio >/dev/null 2>&1 || true
mkdir -p /var/lib/mpxprime
chown mpxprime:mpxprime /var/lib/mpxprime
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
fi
echo "mpxprime installed. Configure /var/lib/mpxprime/MPXPrime.ini (created"
echo "with defaults on first run), then: systemctl enable --now mpxprime"
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ -d /run/systemd/system ]; then
    systemctl stop mpxprime >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/prerm"

dpkg-deb --build --root-owner-group "$STAGE" .
echo "built: $(ls mpxprime_${DEBVER}_amd64.deb)"
