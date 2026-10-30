#!/usr/bin/env bash
#
# Run the test suite (Swift Testing; needs a full Xcode on macOS, which
# build-env.sh points DEVELOPER_DIR at). Arguments go to swift test:
#
#   scripts/test.sh                              # default suite (~40 s)
#   scripts/test.sh --filter BassClipperTests    # one suite
#   MPXPRIME_DEEP=1 scripts/test.sh --filter Deep   # the opt-in deep DSP suite (~3 min)
set -euo pipefail

# shellcheck source=scripts/build-env.sh
. "$(dirname "$0")/build-env.sh"

echo "+ swift test $*"
exec swift test "$@"
