#!/usr/bin/env bash
# #ddev-generated
# update-check.sh — Non-blocking update checker for ddev-secret-vault
# Called from the pre-start hook. Must never block for more than ~2 seconds.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_VAULT_VERSION=$(cat "${SCRIPT_DIR}/../VERSION" 2>/dev/null | tr -d '[:space:]')
CACHE_DIR="${HOME}/.ddev/secret-vault"
CACHE_FILE="${CACHE_DIR}/.update_check"
REPO="RandalVanheede/secretvault-ddev"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_now() { date +%s; }

_version_gt() {
  # Returns 0 if $1 > $2 (semantic version comparison, strips leading 'v')
  local v1="${1#v}" v2="${2#v}"
  if [[ "${v1}" == "${v2}" ]]; then
    return 1
  fi
  local higher
  higher=$(printf '%s\n%s\n' "${v1}" "${v2}" | sort -V | tail -n1)
  [[ "${higher}" == "${v1}" ]]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "${CACHE_DIR}"

CURRENT_TIME=$(_now)
LAST_CHECK=0
LATEST_VERSION=""

# Read cache
if [[ -f "${CACHE_FILE}" ]]; then
  source "${CACHE_FILE}" 2>/dev/null || true
fi

# Decide whether to check the network
if (( CURRENT_TIME - LAST_CHECK >= 86400 )); then
  # Cache is stale or missing — fetch from GitHub
  response=$(curl -fsSL --connect-timeout 1.5 --max-time 2 \
    "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null) || response=""

  if [[ -n "${response}" ]]; then
    # Parse tag_name (simple grep, avoids jq dependency)
    tag=$(echo "${response}" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -n "${tag}" ]]; then
      LATEST_VERSION="${tag}"
      cat > "${CACHE_FILE}" <<EOF
LAST_CHECK=${CURRENT_TIME}
LATEST_VERSION=${LATEST_VERSION}
EOF
    fi
  else
    # Network failed — retry in 1 hour instead of 24 hours
    RETRY_TIME=$(( CURRENT_TIME - 82800 ))
    cat > "${CACHE_FILE}" <<EOF
LAST_CHECK=${RETRY_TIME}
LATEST_VERSION=${LATEST_VERSION}
EOF
  fi
fi

# Display alert if a newer version is available
if [[ -n "${LATEST_VERSION}" ]] && _version_gt "${LATEST_VERSION}" "${SECRET_VAULT_VERSION}"; then
  local_line="  Installed: ${SECRET_VAULT_VERSION}, Latest: ${LATEST_VERSION}"
  update_line="  Run: ddev get ${REPO} to update"
  width=65
  echo ""
  echo "┌$(printf '─%.0s' $(seq 1 $width))┐"
  printf "│  A new version of ddev-secret-vault is available!%*s│\n" $(( width - 51 )) ""
  printf "│%s%*s│\n" "${local_line}" $(( width - ${#local_line} )) ""
  printf "│%s%*s│\n" "${update_line}" $(( width - ${#update_line} )) ""
  echo "└$(printf '─%.0s' $(seq 1 $width))┘"
  echo ""
fi
