#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 "$REPO_ROOT/tests/test_fixture_mapping.py"
python3 "$REPO_ROOT/tests/test_traffic_receipt.py"
