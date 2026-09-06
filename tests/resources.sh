#!/usr/bin/env bash
# Run real Shadow tools against private files with a full subordinate-ID map.
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
RESOURCE_TEST_TOOLS=$(nix-build tests/resource-tools.nix --no-out-link)
export RESOURCE_TEST_TOOLS
exec unshare --user --map-auto --map-root-user --mount --fork \
    python3 -m unittest discover -s tests -v
