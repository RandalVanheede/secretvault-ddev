#!/usr/bin/env bash
# #ddev-generated
# ui.sh — Pretty output helpers for secret-vault

# ANSI colours (disabled when not a TTY or NO_COLOR is set)
_ui_colors_enabled() {
  [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 || -t 2 ]]
}

_C_RESET=""
_C_GREEN=""
_C_YELLOW=""
_C_RED=""
_C_CYAN=""
_C_DIM=""
_C_BOLD=""

if _ui_colors_enabled; then
  _C_RESET="\033[0m"
  _C_GREEN="\033[0;32m"
  _C_YELLOW="\033[0;33m"
  _C_RED="\033[0;31m"
  _C_CYAN="\033[0;36m"
  _C_DIM="\033[2m"
  _C_BOLD="\033[1m"
fi

ui_success() { printf "${_C_GREEN}✓${_C_RESET} %s\n" "${*}" >&2; }
ui_error()   { printf "${_C_RED}✗${_C_RESET} %s\n" "${*}" >&2; }
ui_warn()    { printf "${_C_YELLOW}⚠${_C_RESET} %s\n" "${*}" >&2; }
ui_info()    { printf "${_C_CYAN}→${_C_RESET} %s\n" "${*}" >&2; }
ui_dim()     { printf "${_C_DIM}%s${_C_RESET}\n" "${*}" >&2; }
ui_header()  { printf "\n${_C_BOLD}%s${_C_RESET}\n" "${*}" >&2; printf "%s\n" "$(printf '─%.0s' $(seq 1 ${#1}))" >&2; }

# Print a diff-style line (+ green, - red, unchanged dim)
ui_diff_line() {
  local line="${1}"
  case "${line}" in
    +*) printf "${_C_GREEN}%s${_C_RESET}\n" "${line}" >&2 ;;
    -*) printf "${_C_RED}%s${_C_RESET}\n" "${line}" >&2 ;;
    *)  printf "${_C_DIM}%s${_C_RESET}\n" "${line}" >&2 ;;
  esac
}

# Prompt yes/no, return 0 for yes, 1 for no
# Usage: ui_confirm "Import all?" && do_thing
ui_confirm() {
  if [[ "${ASSUME_YES:-}" == "true" ]]; then
    return 0
  fi

  local prompt="${1:-Continue?}"
  local default="${2:-y}"   # y or n

  local choices
  if [[ "${default}" == "y" ]]; then
    choices="[Y/n]"
  else
    choices="[y/N]"
  fi

  printf "${_C_CYAN}%s %s: ${_C_RESET}" "${prompt}" "${choices}" >&2
  local answer
  read -r answer </dev/tty

  if [[ -z "${answer}" ]]; then
    answer="${default}"
  fi

  [[ "${answer}" =~ ^[Yy] ]]
}
