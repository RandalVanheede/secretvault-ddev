#!/usr/bin/env bash
# #ddev-generated

launch_secret_vault_desktop() {
  local project_name="${1}"

  # 1. Check if the app is installed in macOS Applications
  if [[ -d "/Applications/Secret Vault.app" ]] && command -v open >/dev/null 2>&1; then
    open -a "/Applications/Secret Vault.app" --args --project "${project_name}"
    return $?
  fi

  if [[ -d "${HOME}/Applications/Secret Vault.app" ]] && command -v open >/dev/null 2>&1; then
    open -a "${HOME}/Applications/Secret Vault.app" --args --project "${project_name}"
    return $?
  fi

  # 2. Check if the binary is in PATH (Linux/Windows)
  if command -v secret-vault-desktop >/dev/null 2>&1; then
    nohup secret-vault-desktop --project "${project_name}" >/tmp/secret-vault-desktop.log 2>&1 &
    return 0
  fi

  # 3. Fallback for local development (running from the source repo)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repo_root
  repo_root="$(cd "${script_dir}/../.." && pwd)"
  local desktop_dir="${repo_root}/desktop"

  if [[ -d "${desktop_dir}" ]]; then
    local macos_app="${desktop_dir}/src-tauri/target/release/bundle/macos/Secret Vault.app"
    local linux_bin="${desktop_dir}/src-tauri/target/release/secret-vault-desktop"
    local windows_bin="${desktop_dir}/src-tauri/target/release/secret-vault-desktop.exe"

    if [[ -d "${macos_app}" ]] && command -v open >/dev/null 2>&1; then
      open -a "${macos_app}" --args --project "${project_name}"
      return $?
    fi

    if [[ -x "${linux_bin}" ]]; then
      nohup "${linux_bin}" --project "${project_name}" >/tmp/secret-vault-desktop.log 2>&1 &
      return 0
    fi

    if [[ -f "${windows_bin}" ]]; then
      nohup "${windows_bin}" --project "${project_name}" >/tmp/secret-vault-desktop.log 2>&1 &
      return 0
    fi

    if [[ -d "${desktop_dir}/node_modules" ]]; then
      cd "${desktop_dir}" || return 1
      nohup npm run tauri dev -- -- --project "${project_name}" >/tmp/secret-vault-desktop.log 2>&1 &
      return 0
    fi
  fi

  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  launch_secret_vault_desktop "$@"
fi
