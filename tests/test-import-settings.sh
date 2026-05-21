#!/usr/bin/env bash
# test-import-settings.sh — Unit tests for settings.local.php import

set -euo pipefail
PASS=0
FAIL=0
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

PROJECT_NAME="test-project"
VAULT_DIR="${TMPDIR_TEST}/vault"
VAULT_FILE="${VAULT_DIR}/test-project.vault"
mkdir -p "${VAULT_DIR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../secret-vault-helpers/ui.sh"
source "${SCRIPT_DIR}/../secret-vault-helpers/crypto.sh"

crypto_get_master_password() { echo "test-password-123"; }
crypto_load_master_password() { return 1; }
ui_confirm() { return 0; }

source "${SCRIPT_DIR}/../secret-vault-helpers/import-settings-local.sh"

# ---------------------------------------------------------------------------
assert_eq() {
  local desc="${1}" expected="${2}" actual="${3}"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  PASS: ${desc}"
    (( PASS++ )) || true
  else
    echo "  FAIL: ${desc}"
    echo "        expected: '${expected}'"
    echo "        actual:   '${actual}'"
    (( FAIL++ )) || true
  fi
}

make_vault() {
  local password="${1:-test-password-123}"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local json
  json=$(printf '{"version":1,"project":"test-project","created":"%s","updated":"%s","secrets":{},"metadata":{}}' \
    "${now}" "${now}")
  crypto_encrypt "${json}" "${VAULT_FILE}" "${password}"
}

assert_file_contains() {
  local desc="${1}" file="${2}" needle="${3}"
  if grep -Fq "${needle}" "${file}"; then
    echo "  PASS: ${desc}"
    (( PASS++ )) || true
  else
    echo "  FAIL: ${desc}"
    echo "        expected file to contain: ${needle}"
    (( FAIL++ )) || true
  fi
}

assert_file_not_contains() {
  local desc="${1}" file="${2}" pattern="${3}"
  if grep -Eq "${pattern}" "${file}"; then
    echo "  FAIL: ${desc}"
    echo "        expected file NOT to match: ${pattern}"
    (( FAIL++ )) || true
  else
    echo "  PASS: ${desc}"
    (( PASS++ )) || true
  fi
}

# ---------------------------------------------------------------------------
# TEST 1: hash_salt extraction
echo ""
echo "=== Test 1: hash_salt extraction ==="
make_vault

cat > "${TMPDIR_TEST}/settings1.php" <<'PHP'
<?php
$settings['hash_salt'] = 'my_super_secret_hash_value_12345';
$databases['default']['default'] = [
  'database' => 'drupal',
  'username' => 'db',
  'password' => 'totally_secret_db_pass',
  'host' => 'db',
  'driver' => 'mysql',
];
PHP

import_settings_local "${TMPDIR_TEST}/settings1.php" "${VAULT_FILE}" "test-password-123" "false"
json=$(crypto_decrypt "${VAULT_FILE}" "test-password-123")

val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('DRUPAL_HASH_SALT','MISSING'))" <<< "${json}")
assert_eq "DRUPAL_HASH_SALT extracted" "my_super_secret_hash_value_12345" "${val}"

val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('DB_PASSWORD','MISSING'))" <<< "${json}")
assert_eq "DB_PASSWORD extracted" "totally_secret_db_pass" "${val}"

# ---------------------------------------------------------------------------
# TEST 2: Array-style database config
echo ""
echo "=== Test 2: Array-style database config ==="
make_vault

cat > "${TMPDIR_TEST}/settings2.php" <<'PHP'
<?php
$databases = [];
$databases['default']['default'] = array(
  'database' => 'my_db',
  'username' => 'db',
  'password' => 'array_style_password',
  'host' => 'localhost',
  'port' => '3306',
  'driver' => 'mysql',
  'prefix' => '',
);
PHP

import_settings_local "${TMPDIR_TEST}/settings2.php" "${VAULT_FILE}" "test-password-123" "false"
json=$(crypto_decrypt "${VAULT_FILE}" "test-password-123")

val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('DB_PASSWORD','MISSING'))" <<< "${json}")
assert_eq "DB_PASSWORD from array() style" "array_style_password" "${val}"

# ---------------------------------------------------------------------------
# TEST 3: Custom API key patterns
echo ""
echo "=== Test 3: Custom API key in \$settings ==="
make_vault

cat > "${TMPDIR_TEST}/settings3.php" <<'PHP'
<?php
$settings['hash_salt'] = 'somehash';
$settings['smtp_password'] = 'my_smtp_pass_xyz';
$settings['google_maps_api_key'] = 'AIzaSyABC123XYZ';
PHP

import_settings_local "${TMPDIR_TEST}/settings3.php" "${VAULT_FILE}" "test-password-123" "false"
json=$(crypto_decrypt "${VAULT_FILE}" "test-password-123")

val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('SMTP_PASSWORD','MISSING'))" <<< "${json}")
assert_eq "SMTP_PASSWORD extracted" "my_smtp_pass_xyz" "${val}"

val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('GOOGLE_MAPS_API_KEY','MISSING'))" <<< "${json}")
assert_eq "GOOGLE_MAPS_API_KEY extracted" "AIzaSyABC123XYZ" "${val}"

# ---------------------------------------------------------------------------
# TEST 4: Metadata is set
echo ""
echo "=== Test 4: Import metadata ==="
make_vault

cat > "${TMPDIR_TEST}/settings4.php" <<'PHP'
<?php
$settings['hash_salt'] = 'metahash';
PHP

import_settings_local "${TMPDIR_TEST}/settings4.php" "${VAULT_FILE}" "test-password-123" "false"
json=$(crypto_decrypt "${VAULT_FILE}" "test-password-123")

source=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['metadata'].get('DRUPAL_HASH_SALT',{}).get('imported_from','MISSING'))" <<< "${json}")
assert_eq "Metadata imported_from set" "settings4.php" "${source}"

# ---------------------------------------------------------------------------
# TEST 5: --clean replaces null-coalescing hash_salt fallback
echo ""
echo "=== Test 5: Clean null-coalescing hash_salt ==="
make_vault

cat > "${TMPDIR_TEST}/settings5.php" <<'PHP'
<?php
$settings['hash_salt'] = $settings['hash_salt'] ?? 'fallback_secret_hash';
PHP

import_settings_local "${TMPDIR_TEST}/settings5.php" "${VAULT_FILE}" "test-password-123" "true"
assert_file_contains "hash_salt fallback cleaned" "${TMPDIR_TEST}/settings5.php" "getenv('DRUPAL_HASH_SALT')"

# ---------------------------------------------------------------------------
# TEST 6: --clean replaces generic extracted setting values
echo ""
echo "=== Test 6: Clean generic API key setting ==="
make_vault

cat > "${TMPDIR_TEST}/settings6.php" <<'PHP'
<?php
$settings['google_maps_api_key'] = 'AIzaSyABC123XYZ';
PHP

import_settings_local "${TMPDIR_TEST}/settings6.php" "${VAULT_FILE}" "test-password-123" "true"
assert_file_contains "generic API key cleaned" "${TMPDIR_TEST}/settings6.php" "getenv('GOOGLE_MAPS_API_KEY')"

# ---------------------------------------------------------------------------
# TEST 7: subsite import prefixes keys
echo ""
echo "=== Test 7: Subsite-prefixed import ==="
make_vault

cat > "${TMPDIR_TEST}/settings7.php" <<'PHP'
<?php
$settings['hash_salt'] = 'subsitehash';
$databases['default']['default']['password'] = 'subsitepass';
PHP

import_settings_local "${TMPDIR_TEST}/settings7.php" "${VAULT_FILE}" "test-password-123" "false" "stock"
json=$(crypto_decrypt "${VAULT_FILE}" "test-password-123")

val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('STOCK__DRUPAL_HASH_SALT','MISSING'))" <<< "${json}")
assert_eq "Prefixed hash_salt imported" "subsitehash" "${val}"

val=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['secrets'].get('STOCK__DB_PASSWORD','MISSING'))" <<< "${json}")
assert_eq "Prefixed DB_PASSWORD imported" "subsitepass" "${val}"

# ---------------------------------------------------------------------------
# TEST 8: subsite clean uses prefixed getenv names
echo ""
echo "=== Test 8: Subsite-prefixed clean ==="
make_vault

cat > "${TMPDIR_TEST}/settings8.php" <<'PHP'
<?php
$settings['hash_salt'] = 'subsitehash';
$databases['default']['default']['password'] = 'subsitepass';
PHP

import_settings_local "${TMPDIR_TEST}/settings8.php" "${VAULT_FILE}" "test-password-123" "true" "stock"
assert_file_contains "Prefixed hash_salt cleaned" "${TMPDIR_TEST}/settings8.php" "getenv('STOCK__DRUPAL_HASH_SALT')"
assert_file_contains "Prefixed DB password cleaned" "${TMPDIR_TEST}/settings8.php" "getenv('STOCK__DB_PASSWORD')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Test 9: Commented code is skipped ==="
cat > "${TMPDIR_TEST}/settings9.php" <<'PHP'
<?php
// $settings['hash_salt'] = 'commented_hash';
# $databases['default']['default']['password'] = 'commented_pass';
/* $settings['smtp_password'] = 'commented_smtp'; */
$settings['hash_salt'] = 'real_hash';
$databases['default']['default']['password'] = 'real_pass';
PHP

extracted_json=$(_regex_extract_php_secrets "${TMPDIR_TEST}/settings9.php")
hash_val=$(echo "${extracted_json}" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('DRUPAL_HASH_SALT',''))")
db_val=$(echo "${extracted_json}" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('DB_PASSWORD',''))")
assert_eq "Commented hash_salt skipped" "real_hash" "${hash_val}"
assert_eq "Commented DB password skipped" "real_pass" "${db_val}"
# Ensure commented values not extracted
smtp_val=$(echo "${extracted_json}" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('SMTP_PASSWORD',''))")
assert_eq "Commented smtp_password skipped" "" "${smtp_val}"

# ---------------------------------------------------------------------------
echo ""
echo "=== Test 10: No cross-contamination of secrets during clean ==="
cat > "${TMPDIR_TEST}/settings10.php" <<'PHP'
<?php
$settings['hash_salt'] = 'myhash123';
$settings['file_private_path'] = '/directory/outside/webroot';
$databases['default']['default'] = [
  'database' => 'drupal',
  'username' => 'dbadmin',
  'password' => 'secretdbpass',
  'host' => 'localhost',
];
PHP

import_settings_local "${TMPDIR_TEST}/settings10.php" "${VAULT_FILE}" "test-password-123" "true" "default"

# Verify the file_private_path was NOT replaced (it's not a secret)
assert_file_contains "file_private_path unchanged" "${TMPDIR_TEST}/settings10.php" "'/directory/outside/webroot'"
# Verify DB password was replaced correctly
assert_file_contains "DB password replaced correctly" "${TMPDIR_TEST}/settings10.php" "getenv('DEFAULT__DB_PASSWORD')"
# Verify hash_salt was replaced correctly
assert_file_contains "Hash salt replaced correctly" "${TMPDIR_TEST}/settings10.php" "getenv('DEFAULT__DRUPAL_HASH_SALT')"
# Verify the path value is NOT getenv('DEFAULT__DB_PASSWORD') or getenv('DEFAULT__DB_USER')
assert_file_not_contains "Path not replaced with DB_PASSWORD" "${TMPDIR_TEST}/settings10.php" "file_private_path.*getenv"

# ---------------------------------------------------------------------------
echo ""
echo "=== Test 11: Extra sensitive keys ([_-]key, [_-]token) ==="
cat > "${TMPDIR_TEST}/settings11.php" <<'PHP'
<?php
$settings['vat_per_country_key'] = 'secret-vat-key-123';
$settings['my_app_token'] = 'app-token-456';
PHP

extracted_json=$(_regex_extract_php_secrets "${TMPDIR_TEST}/settings11.php")
vat_val=$(echo "${extracted_json}" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('VAT_PER_COUNTRY_KEY',''))")
token_val=$(echo "${extracted_json}" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('MY_APP_TOKEN',''))")
assert_eq "vat_per_country_key extracted" "secret-vat-key-123" "${vat_val}"
assert_eq "my_app_token extracted" "app-token-456" "${token_val}"

# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "  PASSED: ${PASS}"
echo "  FAILED: ${FAIL}"
echo "================================"

[[ "${FAIL}" -eq 0 ]] || exit 1
