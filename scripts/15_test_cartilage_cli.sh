#!/usr/bin/env bash
# Cartilage OS — Automated Verification Suite for Phase 3: The Appliance Framework
# Tests:
#   1. JSON Schema & Pure-Python Validator (Task 16)
#   2. Unified Cartilage CLI Engine & Dispatcher (Task 17)
#   3. Modular /init.d/ Stage Runner & Fault Boundaries (Task 18)
#   4. Declarative Recipe Hub (Task 19)
#   5. Universal Bare-Metal USB Flashing Engine (Task 20)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"
export PYTHONPATH="${REPO_ROOT}/src:${PYTHONPATH:-}"

PASS_COUNT=0

FAIL_COUNT=0

log_pass() {
    echo "[PASS] $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
    echo "[FAIL] $1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "============================================================"
echo "Cartilage OS — Phase 3 Appliance Framework Verification"
echo "============================================================"

# Test 1: JSON Schema Validity (Task 16)
echo "==> Test 1: Checking JSON schema validity..."
if python3 -c "import json; json.load(open('spec/cartilage.schema.json')); print('Schema JSON is valid')"; then
    log_pass "spec/cartilage.schema.json is valid JSON"
else
    log_fail "spec/cartilage.schema.json failed JSON parsing"
fi

# Test 2: Unified CLI Help & Module Entrypoint (Task 17)
echo "==> Test 2: Checking CLI execution (cartilage --help and python3 -m cartilage)..."
if ./cartilage --help >/dev/null && python3 -m cartilage --help >/dev/null; then
    log_pass "Unified cartilage CLI and module entrypoint pass --help"
else
    log_fail "cartilage CLI --help failed"
fi

# Test 3: Recipe Hub Validation (Task 19)
echo "==> Test 3: Validating all standard recipes against schema..."
if ./cartilage validate recipes/*.yaml; then
    log_pass "All 4 standard recipes (chromium, dillo, mousepad, foot) pass schema validation"
else
    log_fail "Recipe validation failed"
fi

# Test 4: Schema Rejection of Invalid Manifests (Task 16)
echo "==> Test 4: Testing schema rejection on invalid manifest..."
INVALID_OUTPUT=$(python3 -c '
import sys
sys.path.insert(0, "src")
import cartilage.yaml as yaml
import cartilage.schema as schema
bad_data = yaml.loads("appliance:\n  name: INVALID NAME\n  version: 1.0\nruntime:\n  engine: ubuntu\n")
try:
    schema.validate_manifest(bad_data)
    print("UNEXPECTED_PASS")
except schema.ValidationError as e:
    print("CAUGHT_ERROR: " + str(e))
')
if echo "$INVALID_OUTPUT" | grep -q "CAUGHT_ERROR"; then
    log_pass "Schema validator correctly rejected invalid manifest syntax"
else
    log_fail "Schema validator failed to reject invalid manifest"
fi

# Test 5: Safe USB Flash Engine Dry-Run (Task 20)
echo "==> Test 5: Testing safe block-device flasher in dry-run mode..."
if ./cartilage flash --dry-run /dev/null recipes/browser-dillo.yaml | grep -q "DRY RUN SUCCESS"; then
    log_pass "cartilage flash --dry-run /dev/null calculated partition layout cleanly"
else
    log_fail "cartilage flash dry-run failed"
fi

# Test 6: Appliance Execution in QEMU (Task 18)
echo "==> Test 6: Running appliance in QEMU via declarative runner..."
RUN_LOG=$(./cartilage run recipes/browser-dillo.yaml --test 2>&1 || true)
if echo "$RUN_LOG" | grep -q "CARTRIDGE VERIFICATION FOR dillo SUCCEEDED"; then
    log_pass "Appliance booted via modular stage runner and passed verification in QEMU"
else
    echo "$RUN_LOG" >&2
    log_fail "Appliance QEMU test execution failed"
fi


echo "============================================================"
echo "Phase 3 Verification Summary: ${PASS_COUNT} Passed, ${FAIL_COUNT} Failed"
echo "============================================================"

if [[ $FAIL_COUNT -eq 0 ]]; then
    exit 0
else
    exit 1
fi
