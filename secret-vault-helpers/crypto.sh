#!/usr/bin/env bash
# #ddev-generated
# crypto.sh — Encryption/decryption helpers for secret-vault
# Uses openssl aes-256-cbc with PBKDF2 key derivation.
# One master password protects all project vaults.

# Keychain service name — single entry for all vaults
_VAULT_KEYCHAIN_SERVICE="ddev-secret-vault"
_VAULT_KEYCHAIN_ACCOUNT="master"

# ---------------------------------------------------------------------------
# Encrypt plaintext JSON string to a vault file
# Usage: crypto_encrypt <json_string> <output_file> <password>
# ---------------------------------------------------------------------------
crypto_encrypt() {
  local json="${1}"
  local outfile="${2}"
  local password="${3}"

  local tmpfile
  tmpfile=$(mktemp)
  echo -n "${json}" > "${tmpfile}"

  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
    -in "${tmpfile}" \
    -out "${outfile}" \
    -pass "pass:${password}" 2>/dev/null

  local exit_code=$?
  rm -f "${tmpfile}"

  if [[ ${exit_code} -ne 0 ]]; then
    echo "ERROR: Encryption failed" >&2
    return 1
  fi

  chmod 600 "${outfile}"
}

# ---------------------------------------------------------------------------
# Decrypt vault file to JSON string (stdout)
# Usage: crypto_decrypt <vault_file> <password>
# ---------------------------------------------------------------------------
crypto_decrypt() {
  local vault_file="${1}"
  local password="${2}"

  openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
    -in "${vault_file}" \
    -pass "pass:${password}" 2>/dev/null

  local exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    echo "ERROR: Decryption failed — wrong password or corrupted vault" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Get the master password — keychain first, then interactive prompt.
# Usage: password=$(crypto_get_master_password)
# ---------------------------------------------------------------------------
crypto_get_master_password() {
  # Try keychain silently first
  local stored
  stored=$(crypto_load_master_password 2>/dev/null)
  if [[ -n "${stored}" ]]; then
    echo "${stored}"
    return 0
  fi

  # Fall back to interactive prompt
  crypto_read_password "Master vault password"
}

# ---------------------------------------------------------------------------
# Prompt for a NEW master password (first-time setup), with confirmation
# and an offer to save in the OS keychain.
# Usage: password=$(crypto_prompt_new_master_password)
# ---------------------------------------------------------------------------
crypto_prompt_new_master_password() {
  while true; do
    local password
    password=$(crypto_read_password "New master vault password")

    if [[ ${#password} -lt 8 ]]; then
      echo "Password must be at least 8 characters." >&2
      continue
    fi

    local confirm
    confirm=$(crypto_read_password "Confirm master password")

    if [[ "${password}" != "${confirm}" ]]; then
      echo "Passwords do not match. Try again." >&2
      continue
    fi

    # Offer to save in keychain
    if _keychain_available; then
      printf "Save master password in OS keychain? [Y/n]: " >&2
      local save_choice
      read -r save_choice </dev/tty
      if [[ "${save_choice}" =~ ^[Yy]?$ ]]; then
        crypto_save_master_password "${password}"
        echo "Master password saved to keychain." >&2
      fi
    fi

    echo "${password}"
    return 0
  done
}

# ---------------------------------------------------------------------------
# Read a password from /dev/tty (no echo)
# ---------------------------------------------------------------------------
crypto_read_password() {
  local label="${1:-Password}"
  local password

  printf "%s: " "${label}" >&2
  local old_tty_settings
  old_tty_settings=$(stty -g </dev/tty 2>/dev/null || true)
  stty -echo </dev/tty 2>/dev/null || true
  read -r password </dev/tty
  stty "${old_tty_settings}" </dev/tty 2>/dev/null || true
  printf "\n" >&2

  echo "${password}"
}

# ---------------------------------------------------------------------------
# Keychain: load the single master password
# ---------------------------------------------------------------------------
crypto_load_master_password() {
  if [[ "$(uname)" == "Darwin" ]]; then
    security find-generic-password \
      -a "${_VAULT_KEYCHAIN_ACCOUNT}" \
      -s "${_VAULT_KEYCHAIN_SERVICE}" \
      -w 2>/dev/null
  elif command -v secret-tool &>/dev/null; then
    secret-tool lookup \
      application "${_VAULT_KEYCHAIN_SERVICE}" \
      account "${_VAULT_KEYCHAIN_ACCOUNT}" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Keychain: save the master password
# ---------------------------------------------------------------------------
crypto_save_master_password() {
  local password="${1}"

  if [[ "$(uname)" == "Darwin" ]]; then
    security add-generic-password \
      -a "${_VAULT_KEYCHAIN_ACCOUNT}" \
      -s "${_VAULT_KEYCHAIN_SERVICE}" \
      -w "${password}" \
      -U 2>/dev/null
  elif command -v secret-tool &>/dev/null; then
    echo "${password}" | secret-tool store \
      --label="DDEV Secret Vault (master)" \
      application "${_VAULT_KEYCHAIN_SERVICE}" \
      account "${_VAULT_KEYCHAIN_ACCOUNT}" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Keychain: delete the master password
# ---------------------------------------------------------------------------
crypto_delete_master_password() {
  if [[ "$(uname)" == "Darwin" ]]; then
    security delete-generic-password \
      -a "${_VAULT_KEYCHAIN_ACCOUNT}" \
      -s "${_VAULT_KEYCHAIN_SERVICE}" 2>/dev/null || true
  elif command -v secret-tool &>/dev/null; then
    secret-tool clear \
      application "${_VAULT_KEYCHAIN_SERVICE}" \
      account "${_VAULT_KEYCHAIN_ACCOUNT}" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Check if a keychain is available on this system
# ---------------------------------------------------------------------------
_keychain_available() {
  if [[ "$(uname)" == "Darwin" ]]; then
    command -v security &>/dev/null
  elif command -v secret-tool &>/dev/null; then
    true
  else
    false
  fi
}
