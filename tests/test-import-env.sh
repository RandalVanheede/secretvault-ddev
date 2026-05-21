#!/usr/bin/env bash
# test-import-env.sh — Unit tests for .env file import parsing

set -euo pipefail
PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# Minimal stubs so we can source the helpers without a full DDEV context
PROJECT_NAME="test-project"
VAULT_DIR="${TMPDIR_TEST}/vault"
VAULT_FILE="${VAULT_DIR}/test-project.vault"
mkdir -p "${VAULT_DIR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../secret-vault-helpers/ui.sh"
source "${SCRIPT_DIR}/../secret-vault-helpers/crypto.sh"

# Stub master password — skip keychain during tests
crypto_get_master_password() { echo "test-password-123"; }
crypto_load_master_password() { return 1; }
# Stub ui_confirm to always say yes
ui_confirm() { return 0; }

source "${SCRIPT_DIR}/../secret-vault-helpers/import-env.sh"

# ---------------------------------------------------------------------------
assert_eq() {
  local desc="${1}" expected="${2}" actual="${3}"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  PASS: ${desc}"
    (( PASS++ )) || true
  else
    echo "  FAIL: ${desc}"
    echo "        expected: ${expected}"
    echo "        actual:   ${actual}"
    (( FAIL++ )) || true
  fi
}

# ---------------------------------------------------------------------------
# Helper: create a fresh vault
make_vault() {
  local password="${1:-test-password-123}"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local json
  json=$(printf '{"version":1,"project":"test-project","created":"%s","updated":"%s","secrets":{},"metadata":{}}' \
    "${now}" "${now}")
  crypto_encrypt "${json}" "${VAULT_FILE}" "${password}"
}

# ---------------------------------------------------------------------------
# TEST 1: Basic KEY=VALUE parsing
echo ""
echo "=== Test 1: Basic KEY=VALUE parsing ==="
make_vault

cat > "${TMPDIR_TEST}/basic.env" <<'EOF'
API_KEY=abc123
SECRET_TOKEN=hunter2
DB_PASSWORD=super_secret
EOF

import_env_file "${TMPDIR_TEST}/basic.env" "${VAULT_FILE}" "test-password-123" "false"

json=$(crypto_decrypt "${VAULT_FILE}" "test-password-123")
val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('API_KEY','MISSING'))" <<< "${json}")
assert_eq "API_KEY imported" "abc123" "${val}"
val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('SECRET_TOKEN','MISSING'))" <<< "${json}")
assert_eq "SECRET_TOKEN imported" "hunter2" "${val}"
val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('DB_PASSWORD','MISSING'))" <<< "${json}")
assert_eq "DB_PASSWORD imported" "super_secret" "${val}"

# ---------------------------------------------------------------------------
# TEST 2: Quoted values
echo ""
echo "=== Test 2: Quoted values ==="
make_vault

cat > "${TMPDIR_TEST}/quoted.env" <<'EOF'
DOUBLE_QUOTED="hello world"
SINGLE_QUOTED='another value'
UNQUOTED=simple
EOF

import_env_file "${TMPDIR_TEST}/quoted.env" "${VAULT_FILE}" "test-password-123" "false"
json=$(crypto_decrypt "${VAULT_FILE}" "test-password-123")

val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('DOUBLE_QUOTED','MISSING'))" <<< "${json}")
assert_eq "Double-quoted value stripped" "hello world" "${val}"
val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('SINGLE_QUOTED','MISSING'))" <<< "${json}")
assert_eq "Single-quoted value stripped" "another value" "${val}"
val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('UNQUOTED','MISSING'))" <<< "${json}")
assert_eq "Unquoted value preserved" "simple" "${val}"

# ---------------------------------------------------------------------------
# TEST 3: Comments and blank lines are skipped
echo ""
echo "=== Test 3: Comments and blank lines ==="
make_vault

cat > "${TMPDIR_TEST}/comments.env" <<'EOF'
# This is a comment
REAL_KEY=real_value

# Another comment
ANOTHER_KEY=another_value
# COMMENTED_OUT_KEY=should_not_import
EOF

import_env_file "${TMPDIR_TEST}/comments.env" "${VAULT_FILE}" "test-password-123" "false"
json=$(crypto_decrypt "${VAULT_FILE}" "test-password-123")

count=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(len(d['secrets']))" <<< "${json}")
assert_eq "Only 2 real keys imported" "2" "${count}"

val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('COMMENTED_OUT_KEY','NOTFOUND'))" <<< "${json}")
assert_eq "Commented-out key NOT imported" "NOTFOUND" "${val}"

# ---------------------------------------------------------------------------
# TEST 4: Metadata is set on import
echo ""
echo "=== Test 4: Import metadata ==="
make_vault

cat > "${TMPDIR_TEST}/meta.env" <<'EOF'
META_KEY=meta_value
EOF

import_env_file "${TMPDIR_TEST}/meta.env" "${VAULT_FILE}" "test-password-123" "false"
json=$(crypto_decrypt "${VAULT_FILE}" "test-password-123")

source=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['metadata'].get('META_KEY',{}).get('imported_from','MISSING'))" <<< "${json}")
assert_eq "Metadata imported_from set" "meta.env" "${source}"

# ---------------------------------------------------------------------------
# Summary
echo ""
echo "================================"
echo "  PASSED: ${PASS}"
echo "  FAILED: ${FAIL}"
echo "================================"

[[ "${FAIL}" -eq 0 ]] || exit 1
