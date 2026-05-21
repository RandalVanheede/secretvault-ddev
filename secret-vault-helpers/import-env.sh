#!/usr/bin/env bash
# #ddev-generated
# import-env.sh — Import secrets from a .env file into the vault

# ---------------------------------------------------------------------------
# Import secrets from a .env file
# Usage: import_env_file <env_file> <vault_file> <password> <clean:bool>
# ---------------------------------------------------------------------------
import_env_file() {
  local env_file="${1}"
  local vault_file="${2}"
  local password="${3}"
  local clean="${4:-false}"

  if [[ ! -f "${env_file}" ]]; then
    ui_error "File not found: ${env_file}"
    return 1
  fi

  # Parse KEY=VALUE lines (skip comments, empty lines, lines without =)
  local parsed_pairs=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Skip comments and empty lines
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    # Must have = sign and valid key
    [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue

    local key="${BASH_REMATCH[1]}"
    local raw_value="${BASH_REMATCH[2]}"

    # Strip surrounding quotes (single or double)
    local value="${raw_value}"
    if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "${value}" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi

    # Strip inline comments (unquoted values only)
    if ! [[ "${raw_value}" =~ ^[\"\'] ]]; then
      value="${value%%[[:space:]]#*}"
      value="${value%"${value##*[![:space:]]}"}"  # rtrim
    fi

    parsed_pairs+=("${key}=${value}")
  done < "${env_file}"

  if [[ ${#parsed_pairs[@]} -eq 0 ]]; then
    ui_warn "No KEY=VALUE entries found in ${env_file}"
    return 0
  fi

  ui_info "Found ${#parsed_pairs[@]} secret(s) in ${env_file}:"
  for pair in "${parsed_pairs[@]}"; do
    local k="${pair%%=*}"
    local v="${pair#*=}"
    local masked
    if [[ ${#v} -le 4 ]]; then
      masked="${v}"
    else
      masked="${v:0:2}$(printf '*%.0s' $(seq 1 $((${#v} - 4))))${v: -2}"
    fi
    ui_dim "    ${k} = ${masked}"
  done

  if ! ui_confirm "Import all into vault?"; then
    ui_info "Import cancelled."
    return 0
  fi

  # Load current vault JSON
  local json
  json=$(crypto_decrypt "${vault_file}" "${password}")
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build updated JSON with all pairs
  # Write vault JSON to a temp file so we can pass it cleanly to Python
  local json_tmp
  json_tmp=$(mktemp)
  echo "${json}" > "${json_tmp}"

  # Use a Python script that reads vault JSON + pairs and outputs updated JSON
  local updated_json
  updated_json=$(python3 - "${env_file}" "${now}" "${json_tmp}" <<'PYEOF'
import sys, json, os

env_file = sys.argv[1]
now = sys.argv[2]
json_file = sys.argv[3]
source = os.path.basename(env_file)

with open(json_file) as f:
    data = json.loads(f.read())

# Parse the env file directly in Python for reliability
pairs = []
with open(env_file) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, raw_value = line.partition("=")
        key = key.strip()
        if not key or not key.replace("_","").isalnum():
            continue
        # Strip quotes
        v = raw_value.strip()
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            v = v[1:-1]
        else:
            # Strip inline comment
            if " #" in v:
                v = v[:v.index(" #")].rstrip()
        pairs.append((key, v))

for key, value in pairs:
    data["secrets"][key] = value
    data["metadata"][key] = {
        "imported_from": source,
        "imported_at": now,
        "updated_at": now
    }

data["updated"] = now
print(json.dumps(data, indent=2))
PYEOF
  )
  rm -f "${json_tmp}"

  crypto_encrypt "${updated_json}" "${vault_file}" "${password}"

  local count=${#parsed_pairs[@]}
  ui_success "Imported ${count} secret(s) from ${env_file} into vault"

  # --clean: sanitize the source file
  if [[ "${clean}" == "true" ]]; then
    _clean_env_file "${env_file}" "${parsed_pairs[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Clean an .env file by replacing secret values with variable references
# ---------------------------------------------------------------------------
_clean_env_file() {
  local env_file="${1}"
  shift
  local pairs=("${@}")

  local backup="${env_file}.bak"
  cp "${env_file}" "${backup}"
  ui_dim "  Backup saved: ${backup}"

  # Show diff preview
  ui_header "Preview changes to ${env_file}"

  local tmpfile
  tmpfile=$(mktemp)

  python3 - "${env_file}" <<'PYEOF' > "${tmpfile}"
import sys, os, re

env_file = sys.argv[1]

lines_orig = []
lines_new = []

with open(env_file) as f:
    for line in f:
        line_stripped = line.rstrip("\n")
        lines_orig.append(line_stripped)

        # Check if this is a KEY=VALUE line
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line_stripped)
        if m:
            key = m.group(1)
            rest = m.group(2).strip()
            # Check if it looks like a real value (not already a variable reference)
            if not rest.startswith("${") and not rest == "" and not rest.startswith("#"):
                lines_new.append(f'# {key} — managed by secret-vault')
                lines_new.append(f'{key}="${{{key}}}"')
            else:
                lines_new.append(line_stripped)
        else:
            lines_new.append(line_stripped)

# Print unified diff
import difflib
diff = list(difflib.unified_diff(lines_orig, lines_new, fromfile=env_file, tofile=env_file + " (cleaned)", lineterm=""))
for d in diff:
    print(d)
PYEOF

  if [[ ! -s "${tmpfile}" ]]; then
    ui_dim "  No changes needed."
    rm -f "${tmpfile}"
    return 0
  fi

  while IFS= read -r line; do
    ui_diff_line "${line}"
  done < "${tmpfile}"
  rm -f "${tmpfile}"

  if ui_confirm "Apply these changes?"; then
    python3 - "${env_file}" <<'PYEOF'
import sys, re

env_file = sys.argv[1]
lines_new = []

with open(env_file) as f:
    for line in f:
        line_stripped = line.rstrip("\n")
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line_stripped)
        if m:
            key = m.group(1)
            rest = m.group(2).strip()
            if not rest.startswith("${") and not rest == "" and not rest.startswith("#"):
                lines_new.append(f'# {key} — managed by secret-vault')
                lines_new.append(f'{key}="${{{key}}}"')
            else:
                lines_new.append(line_stripped)
        else:
            lines_new.append(line_stripped)

with open(env_file, "w") as f:
    f.write("\n".join(lines_new) + "\n")
PYEOF
    ui_success "Cleaned ${env_file}"
  else
    ui_info "Changes not applied. Backup preserved at ${backup}"
  fi
}
