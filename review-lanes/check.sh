#!/usr/bin/env bash
# check.sh — everything here that can be verified, verified.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
bash -n bin/review-lanes
echo "== syntax =="
echo "  ok    bin/review-lanes"

echo
echo "== lanes =="
./tests/selftest.sh
