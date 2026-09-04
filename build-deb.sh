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
# /var/lib/mpxprime/MPXPrime.ini. On a FRESH install postinst seeds that INI
# from the sample (code defaults) with [CONTROL] control_enabled = True,
# control_bind = 0.0.0.0 and a freshly generated random control_api_key
# (printed once at install, readable from the INI later); an existing INI is
# never touched. The unit passes --web as belt-and-braces, so the dashboard
# is the interface from the first start: http://<host>:8737/ + the key.
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
# --web: the dashboard is the ONLY operator interface on Linux, so the service
# always serves it. The flag only forces the server on; bind address, port
# and API key still come from [CONTROL] in the INI (default 127.0.0.1:8737,
# a non-loopback bind requires control_api_key or the server refuses to
# start while the encoder keeps running).
ExecStart=/usr/bin/mpxprime --nogui --web --config /var/lib/mpxprime/MPXPrime.ini
Restart=on-failure
RestartSec=3
# Real-time-friendly scheduling for the audio threads. LimitRTPRIO lets the
# ALSA render/capture threads run SCHED_FIFO; CAP_SYS_NICE additionally lets
# the Swift runtime's worker threads apply their QoS without EACCES (removes
# the harmless "Failed to set thread priority" startup warnings).
LimitRTPRIO=70
LimitMEMLOCK=64M
AmbientCapabilities=CAP_SYS_NICE

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
# Fresh install only (an existing INI is the operator's and is never touched,
# also on upgrade): seed the config from the sample INI (code defaults) with
# the dashboard reachable from another machine -- a headless box has no
# local browser -- behind a freshly generated random API key. The key lives
# in the INI ([CONTROL] control_api_key); it is printed once here.
INI=/var/lib/mpxprime/MPXPrime.ini
SAMPLE=/usr/share/mpxprime/MPXPrime.sample.ini
if [ ! -f "$INI" ]; then
    # LC_ALL=C: tr must see raw bytes, not a UTF-8 decode of them. Hex
    # fallback if the alphanumeric filter ever yields too little.
    KEY=$(head -c 2048 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)
    if [ "${#KEY}" -lt 32 ]; then
        KEY=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
    fi
    if [ -f "$SAMPLE" ]; then
        sed -e 's/^control_enabled *=.*/control_enabled = True/' \
            -e 's/^control_bind *=.*/control_bind = 0.0.0.0/' \
            -e "s/^control_api_key *=.*/control_api_key = $KEY/" \
            "$SAMPLE" > "$INI"
    else
        printf '[CONTROL]\ncontrol_enabled = True\ncontrol_bind = 0.0.0.0\ncontrol_port = 8737\ncontrol_api_key = %s\n' "$KEY" > "$INI"
    fi
    chown mpxprime:mpxprime "$INI"
    chmod 0640 "$INI"
    echo "mpxprime: created $INI with the web dashboard enabled on all interfaces."
    echo "mpxprime: web dashboard API key: $KEY"
    echo "mpxprime: (stored in $INI as control_api_key; read it back with"
    echo "mpxprime:  sudo grep control_api_key $INI)"
fi
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
fi
echo "mpxprime installed. Start it with: systemctl enable --now mpxprime"
echo "Then open http://<this-host>:8737/ and paste the API key when the dashboard asks."
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
