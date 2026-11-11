#!/bin/bash
#
# IDE command handler for Antigravity Sandbox.
# Supports code-server browser UI, standalone app windows, and native host IDEs.

[[ -n "${_AGY_CMD_IDE_LOADED:-}" ]] && return 0
_AGY_CMD_IDE_LOADED=1

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${LIB_DIR}/sandbox_config.sh"
source "${LIB_DIR}/sandbox_lib.sh"

#######################################
# Open the code-server Web IDE or native macOS IDE for a repository.
# Globals:
#   AGY_IDE_MODE
#   AGY_NO_BROWSER
#   CODE_SERVER_PORT
#   STATE_DIR
#   TRUSTED_REPO
# Arguments:
#   Flags (--app, --native, --browser) and optional target directory.
# Outputs:
#   Status messages to stdout, errors to stderr.
# Returns:
#   0 on success, non-zero on error.
#######################################
cmd_ide() {
  local ide_mode="${AGY_IDE_MODE:-browser}"
  local target_arg=""

  while (( $# > 0 )); do
    case "$1" in
      --app)
        ide_mode="app"
        shift
        ;;
      --native)
        ide_mode="native"
        shift
        ;;
      --browser)
        ide_mode="browser"
        shift
        ;;
      -*)
        err "Unknown flag for ide: $1"
        ;;
      *)
        target_arg="$1"
        shift
        ;;
    esac
  done

  ensure_sandbox_layout
  local workdir
  workdir="$(resolve_container_workdir "${target_arg}")"

  if [[ "${ide_mode}" == "native" ]]; then
    local host_ws_target="${TRUSTED_REPO:-}"
    if [[ -z "${host_ws_target}" ]] && git rev-parse --show-toplevel &>/dev/null; then
      host_ws_target="$(git rev-parse --show-toplevel)"
    fi
    info "Opening native macOS IDE for ${host_ws_target}..."
    if [[ "${AGY_NO_BROWSER:-false}" == "true" ]]; then
      ok "Native IDE target ready: ${host_ws_target}"
      return 0
    fi
    if command -v cursor &>/dev/null; then
      cursor "${host_ws_target}"
    elif command -v code &>/dev/null; then
      code "${host_ws_target}"
    elif command -v open &>/dev/null; then
      open -a "Visual Studio Code" "${host_ws_target}" 2>/dev/null \
        || open "${host_ws_target}"
    else
      err "No native macOS IDE CLI ('cursor' or 'code') found on PATH."
    fi
    ok "Opened native macOS IDE for ${host_ws_target}."
    return 0
  fi

  require_running_container agy-agent-sandbox
  local port="${CODE_SERVER_PORT:-8443}"
  local base_url="http://127.0.0.1:${port}"
  local url="${base_url}/?folder=${workdir}"

  info "Checking sandboxed code-server IDE at ${base_url}..."
  local -i attempts=0
  while ! curl -fsS --max-time 2 "${base_url}/healthz" >/dev/null 2>&1; do
    (( attempts += 1 ))
    if (( attempts >= 15 )); then
      err "code-server did not respond at ${base_url}/healthz after 15 seconds."
    fi
    sleep 1
  done

  ok "Sandboxed code-server IDE is ready for ${workdir}: ${url}"
  if command -v open &>/dev/null && [[ "${AGY_NO_BROWSER:-false}" != "true" ]]; then
    if [[ "${ide_mode}" == "app" ]]; then
      info "Opening chromeless macOS App Window for ${workdir}..."
      open_chrome_app_window "${url}" "${STATE_DIR}/chrome-app-ide"
    else
      info "Opening dedicated IDE window for ${workdir}..."
      open "${url}"
    fi
  else
    info "Open ${url} in your browser."
  fi
}
