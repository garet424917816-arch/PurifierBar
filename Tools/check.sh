#!/bin/bash
# Build + tests in one call. A green exit is the minimum condition for readiness.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | tail -20
swift test 2>&1 | tail -20
echo "check.sh: OK"
