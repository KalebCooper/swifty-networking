#!/usr/bin/env bash
#
# Runs the package's tests on Linux, in the same container image the CI Linux lane uses, so the claim
# that HTTPCore stays portable off Apple platforms is checked before a push instead of after one.
# Anything Darwin-only is expected to compile out; a failure here is a real portability regression.
#
# `HTTPPortable` and `Logging` are enabled, the trait list the CI Linux lane runs first, so the
# AsyncHTTPClient transport, the swift-log observer, and both their suites build and run here; this is
# the only lane that compiles them at all.
#
# Usage: ./Scripts/linux-test.sh [additional swiftpm arguments]
#   e.g. ./Scripts/linux-test.sh --filter HTTPCoreTests
#
# Set SWIFTY_NETWORKING_TRAITS to run under another trait list:
#   e.g. SWIFTY_NETWORKING_TRAITS=HTTPPortable ./Scripts/linux-test.sh
# Set it to the empty string for the package's default trait set, which enables none; that is the
# lane's second run, and the one that proves what a consumer who asks for no trait gets.

set -euo pipefail

# Pinned to the CI image: a local pass is only evidence about CI if it is the same toolchain.
readonly IMAGE="swift:6.3-noble"

# Build products live in a named volume rather than in the repo, for two reasons: Linux object files
# must not share a scratch directory with the host's macOS build, and a volume survives the container
# so repeat runs are incremental instead of cold.
readonly SCRATCH_VOLUME="swifty-networking-linux-build"

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Unset means the CI lane's trait list; explicitly empty means the package's default trait set, so `-`
# rather than `:-` is the substitution that tells the two apart.
readonly TRAITS="${SWIFTY_NETWORKING_TRAITS-HTTPPortable,Logging}"

traits_argument=()
if [ -n "$TRAITS" ]; then
  traits_argument=(--traits "$TRAITS")
fi

if ! docker info >/dev/null 2>&1; then
  echo "error: docker is not available. Start Docker Desktop and try again." >&2
  exit 1
fi

docker volume create "$SCRATCH_VOLUME" >/dev/null

# `${array[@]+...}` guards the expansion: under `set -u` the bash macOS ships rejects an empty array.
exec docker run --rm \
  --volume "$REPO_ROOT:/workspace" \
  --volume "$SCRATCH_VOLUME:/scratch" \
  --workdir /workspace \
  "$IMAGE" \
  swift test --scratch-path /scratch \
  ${traits_argument[@]+"${traits_argument[@]}"} "$@"
