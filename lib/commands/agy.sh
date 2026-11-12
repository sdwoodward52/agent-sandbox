#!/bin/bash
#
# Antigravity CLI authentication and chat command handlers.

[[ -n "${_AGY_CMD_AGY_LOADED:-}" ]] && return 0
_AGY_CMD_AGY_LOADED=1

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${LIB_DIR}/sandbox_config.sh"
source "${LIB_DIR}/sandbox_lib.sh"

#######################################
# Extract OAuth sign-in URL from an active tmux background session.
# Arguments:
#   Repository name.
# Outputs:
#   Prints authentication URL if present.
#######################################
extract_auth_url() {
  local rname="${1:-}"
  local session_name
  session_name="$(session_name_for_repo "${rname}")"
  if ! command -v docker &>/dev/null; then
    return 0
  fi
  docker exec agy-agent-sandbox tmux capture-pane -pt "${session_name}" 2>/dev/null | \
    awk '
      /(https:\/\/(accounts\.google\.com|www\.google\.com\/device|antigravity\.google\/login|antigravity\.google\/auth))/ {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^https:\/\//) {
            u = $i
            sub(/\.*$/, "", u)
            print u
            exit
          }
        }
      }
    ' || true
}

#######################################
# Check whether an Antigravity tmux session requires interactive authentication.
# Arguments:
#   Repository name.
# Returns:
#   0 if auth is required, 1 otherwise.
#######################################
is_auth_needed() {
  local rname="${1:-}"
  local session_name
  session_name="$(session_name_for_repo "${rname}")"
  if ! command -v docker &>/dev/null; then
    return 1
  fi
  local pane_content
  pane_content="$(docker exec agy-agent-sandbox tmux capture-pane -pt "${session_name}" 2>/dev/null || true)"
  if echo "${pane_content}" | grep -Eiq '(authenticate|authentication|sign in|log in|authorization code|google\.com\/device|accounts\.google\.com)'; then
    return 0
  fi
  return 1
}

#######################################
# Perform interactive Antigravity authentication or configure Gemini API key.
# Globals:
#   AGY_AUTOCOMPLETE_MODEL
#   GEMINI_API_KEY
#   HOME
#   STATE_DIR
# Arguments:
#   Options (--import-host, --api-key) and optional directory target.
# Outputs:
#   Status and instruction messages.
#######################################
cmd_auth() {
  local import_host="false"
  local api_key_arg=""
  local target_arg=""

  while (( $# > 0 )); do
    case "$1" in
      --import-host|-i)
        import_host="true"
        shift
        ;;
      --api-key)
        api_key_arg="${2:-}"
        [[ -n "${api_key_arg}" ]] || err "--api-key requires a value"
        shift 2
        ;;
      --api-key=*)
        api_key_arg="${1#--api-key=}"
        shift
        ;;
      -*)
        err "Unknown flag for auth: $1"
        ;;
      *)
        target_arg="$1"
        shift
        ;;
    esac
  done

  if [[ -n "${api_key_arg}" ]]; then
    GEMINI_API_KEY="${api_key_arg}" ensure_sandbox_layout
    ok "Saved GEMINI_API_KEY and enabled Continue Tab Autocomplete (${AGY_AUTOCOMPLETE_MODEL:-gemini-flash-lite-latest}) in ${STATE_DIR}/continue/config.yaml"
    return 0
  fi

  require_running_container agy-agent-sandbox

  local workdir
  workdir="$(resolve_container_workdir "${target_arg}")"
  local rname
  rname="$(basename "${workdir}")"
  local session_name
  session_name="$(session_name_for_repo "${rname}")"

  ensure_sandbox_layout
  ensure_agy_project_config "${rname}"

  if [[ "${import_host}" == "true" ]]; then
    local host_gemini="${HOME}/.gemini"
    local container_gemini="${STATE_DIR}/gemini"
    info "Checking for existing Antigravity settings/credentials on host (${host_gemini})..."
    local -i copied=0
    local sub
    for sub in "antigravity-cli" "antigravity"; do
      if [[ -d "${host_gemini}/${sub}" ]]; then
        mkdir -p "${container_gemini}/${sub}"
        cp -R "${host_gemini}/${sub}/"* "${container_gemini}/${sub}/" 2>/dev/null || true
        (( copied += 1 ))
      fi
    done
    ensure_sandbox_gemini_settings
    if (( copied > 0 )); then
      ok "Imported host settings/credentials from '${host_gemini}' to '${container_gemini}'."
    else
      warn "No host credentials found under ${host_gemini}."
    fi
  fi

  info "Starting interactive Antigravity CLI authentication session for '${rname}'..."
  echo ""
  echo "  - Follow on-screen instructions to sign in with your Google account."
  echo "  - If an authorization URL is displayed, open it in your browser."
  echo "  - Credentials are automatically persisted on your Mac at: ${STATE_DIR}/gemini"
  echo ""

  if docker exec agy-agent-sandbox tmux has-session -t "${session_name}" 2>/dev/null; then
    info "Attaching to existing session '${session_name}'..."
    info "(Tip: After completing login, press Ctrl+B then D to detach back to host terminal)"
    docker exec -it -w "${workdir}" agy-agent-sandbox tmux attach-session -t "${session_name}"
  else
    info "Launching interactive 'agy --sandbox=false' session..."
    info "(Tip: Complete sign-in, then exit or run 'agy-workflow start' to resume background remote-control)"
    docker exec -it -w "${workdir}" agy-agent-sandbox agy --sandbox=false
  fi

  echo ""
  ok "Authentication session finished. State saved on host at: ${STATE_DIR}/gemini"
  info "Run 'agy-workflow start' or 'agy-workflow chat' to launch or reopen the remote web UI."
}

#######################################
# Launch or open the Antigravity Chat UI (headless or TUI mode).
# Globals:
#   AGY_NO_BROWSER
#   AGY_WEB_APP
#   SANDBOX_ROOT
#   STATE_DIR
# Arguments:
#   Flags (--app, --browser, --tui, -d, -r) and optional target directory.
# Outputs:
#   Status messages and session information.
#######################################
cmd_chat() {
  require_running_container agy-agent-sandbox
  local detach_mode="true"
  local restart_session="false"
  local app_mode="${AGY_WEB_APP:-false}"
  local target_arg=""

  while (( $# > 0 )); do
    case "$1" in
      -t|--tui|--attach)
        detach_mode="false"
        shift
        ;;
      -d|--detach|--headless)
        detach_mode="true"
        shift
        ;;
      -r|--restart)
        restart_session="true"
        shift
        ;;
      --app)
        app_mode="true"
        shift
        ;;
      --browser)
        app_mode="false"
        shift
        ;;
      -*)
        err "Unknown flag for chat: $1"
        ;;
      *)
        target_arg="$1"
        shift
        ;;
    esac
  done

  local workdir
  workdir="$(resolve_container_workdir "${target_arg}")"
  local rname
  rname="$(basename "${workdir}")"
  local session_name
  session_name="$(session_name_for_repo "${rname}")"

  if ! docker exec agy-agent-sandbox sh -c "command -v agy >/dev/null 2>&1"; then
    err "'agy' CLI binary was not found inside agy-agent-sandbox (/home/agent/.local/bin/agy or /opt/agy-vendor/agy).
Place the Linux ARM64 'agy' binary in '${SANDBOX_ROOT}/vendor/agy' (chmod +x) or rebuild with network access."
  fi

  ensure_sandbox_layout
  ensure_agy_project_config "${rname}"

  if [[ "${restart_session}" == "true" ]]; then
    docker exec agy-agent-sandbox tmux kill-session -t "${session_name}" 2>/dev/null || true
  fi

  if [[ "${detach_mode}" == "true" ]]; then
    info "Starting headless 'agy --project ${rname} --remote-control --sandbox=false' session (${session_name}) for ${workdir}..."
    start_headless_tmux_session "${rname}" "${workdir}"

    local remote_url=""
    local auth_url=""
    local -i tries=0
    while [[ -z "${remote_url}" ]] && (( tries < 8 )); do
      remote_url="$(extract_remote_url "${rname}")"
      [[ -n "${remote_url}" ]] && break
      auth_url="$(extract_auth_url "${rname}")"
      [[ -n "${auth_url}" ]] && break
      sleep 1
      (( tries += 1 ))
    done
    echo ""
    info "=== Live Session Output (${session_name}) ==="
    docker exec agy-agent-sandbox tmux capture-pane -pt "${session_name}" | sed '/^[[:space:]]*$/d' | tail -n 15 || true
    echo ""
    if [[ -n "${remote_url}" ]]; then
      ok "Headless session '${session_name}' (project: ${rname}) is running in the background."
      ok "Antigravity Remote Web URL: ${remote_url}"
      if [[ "${app_mode}" == "true" && "${AGY_NO_BROWSER:-false}" != "true" ]]; then
        info "Opening chromeless macOS App Window for Antigravity Remote Web UI..."
      fi
      open_ui_url "${remote_url}" "${app_mode}" "${STATE_DIR}/chrome-app-chat"
      info "Run 'agy-workflow chat' to reopen the web UI, 'agy-url' inside the IDE terminal, or 'agy-workflow chat --tui' for TUI."
    elif [[ -n "${auth_url}" ]] || is_auth_needed "${rname}"; then
      warn "Antigravity CLI is not yet authenticated in agy-agent-sandbox."
      if [[ -n "${auth_url}" ]]; then
        ok "Authentication URL: ${auth_url}"
        open_ui_url "${auth_url}" "${app_mode}" "${STATE_DIR}/chrome-app-chat"
      fi
      info "Run 'agy-sandbox auth' in your terminal to complete sign-in interactively."
    else
      ok "Headless session '${session_name}' (project: ${rname}) started in background."
      info "Run 'agy-sandbox auth' (or 'agy-workflow chat --tui') if sign-in is required, or 'agy-workflow chat' once initialized."
    fi
  else
    info "Starting 'agy --project ${rname} --remote-control --sandbox=false' inside agy-agent-sandbox for ${workdir}..."
    info "(Tip: Press Ctrl+B then D at any time to detach without stopping the session)"
    docker exec -it -w "${workdir}" agy-agent-sandbox \
      tmux new-session -A -s "${session_name}" "agy --project '${rname}' --remote-control --sandbox=false"
  fi
}
