#!/bin/bash
#
# Common container orchestration and session helpers for Antigravity Sandbox.

[[ -n "${_AGY_CMD_SANDBOX_LIB_LOADED:-}" ]] && return 0
_AGY_CMD_SANDBOX_LIB_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/sandbox_config.sh"

#######################################
# Capture running tmux background sessions in agy-agent-sandbox.
# Outputs:
#   List of active session names to stdout.
#######################################
capture_active_sessions() {
  if docker inspect -f '{{.State.Running}}' agy-agent-sandbox 2>/dev/null | grep -q "true"; then
    docker exec agy-agent-sandbox tmux list-sessions -F '#{session_name}' 2>/dev/null \
      | tr -d '\r' || true
  fi
}

#######################################
# Restore previously active background remote-control tmux sessions.
# Arguments:
#   Newline-delimited list of session names.
#######################################
restore_active_sessions() {
  local active_sessions="${1:-}"
  [[ -n "${active_sessions}" ]] || return 0
  local s_name
  while read -r s_name; do
    [[ -n "${s_name}" ]] || continue
    if [[ "${s_name}" == agy-* ]]; then
      local rname="${s_name#agy-}"
      local workdir="/workspaces/${rname}"
      info "Restoring background session '${s_name}' for ${workdir}..."
      start_headless_tmux_session "${rname}" "${workdir}"
      sleep 1
    fi
  done <<< "${active_sessions}"
}

#######################################
# Check if the sandbox pod containers are actively running with workspace mounts.
# Returns:
#   0 if running, 1 otherwise.
#######################################
is_pod_running() {
  docker inspect -f '{{.State.Running}}' agy-egress-proxy 2>/dev/null | grep -q "true" \
    && docker inspect -f '{{.State.Running}}' agy-agent-sandbox 2>/dev/null | grep -q "true" \
    && docker inspect agy-agent-sandbox 2>/dev/null | grep -q '"/workspaces'
}

#######################################
# Execute docker compose command with base and overlay compose configurations.
# Globals:
#   COMPOSE_FILE
#   ENV_FILE
#   OVERLAYS_COMPOSE_FILE
# Arguments:
#   Docker compose subcommands and arguments.
#######################################
compose_cmd() {
  docker compose -f "${COMPOSE_FILE}" -f "${OVERLAYS_COMPOSE_FILE}" \
    --env-file "${ENV_FILE}" "$@"
}

#######################################
# Launch a headless background tmux session running agy --remote-control.
# Arguments:
#   Repository name, and optional container workspace directory.
#######################################
start_headless_tmux_session() {
  local rname="$1"
  local workdir="${2:-/workspaces/${rname}}"
  local session_name
  session_name="$(session_name_for_repo "${rname}")"
  if ! docker exec agy-agent-sandbox tmux has-session -t "${session_name}" 2>/dev/null; then
    docker exec -w "${workdir}" agy-agent-sandbox \
      tmux new-session -d -s "${session_name}" \
      "agy --project '${rname}' --remote-control --sandbox=false; echo ''; echo '[Session exited. Run agy-sandbox auth to sign in or re-authenticate]'; sleep 60"
  fi
}

#######################################
# Verify whether TRUSTED_REPO is actively mounted in the agent container.
# Globals:
#   TRUSTED_REPO
# Returns:
#   0 if mounted, 1 otherwise.
#######################################
is_repo_mounted_in_container() {
  [[ -n "${TRUSTED_REPO:-}" ]] || return 0
  docker inspect agy-agent-sandbox 2>/dev/null | grep -qF "\"${TRUSTED_REPO}\""
}

#######################################
# Extract active remote-control session URL via container agy-url helper.
# Arguments:
#   Repository name.
# Outputs:
#   Remote URL if available.
#######################################
extract_remote_url() {
  local rname="${1:-}"
  docker exec agy-agent-sandbox agy-url "${rname}" 2>/dev/null || true
}

#######################################
# Open a chromeless standalone Chrome app window for a specific URL.
# Cleans up lingering SingletonLock from previous sessions if needed.
# Arguments:
#   Target URL and path to Chrome dedicated user-data-dir profile.
#######################################
open_chrome_app_window() {
  local url="$1"
  local app_profile_dir="$2"
  mkdir -p "${app_profile_dir}"

  # Cleanly stop any lingering Chrome process holding SingletonLock for this
  # dedicated app profile before launching.
  if [[ -L "${app_profile_dir}/SingletonLock" ]]; then
    local lock_target
    lock_target="$(readlink "${app_profile_dir}/SingletonLock" 2>/dev/null || true)"
    local lock_pid="${lock_target##*-}"
    if [[ "${lock_pid}" =~ ^[0-9]+$ ]] && kill -0 "${lock_pid}" 2>/dev/null; then
      kill -TERM "${lock_pid}" 2>/dev/null || true
      local -i wait_ticks=0
      while kill -0 "${lock_pid}" 2>/dev/null && (( wait_ticks < 20 )); do
        sleep 0.1
        (( wait_ticks += 1 ))
      done
    fi
    rm -f "${app_profile_dir}/SingletonLock" \
      "${app_profile_dir}/SingletonSocket" \
      "${app_profile_dir}/SingletonCookie"
  fi

  open -na "Google Chrome" --args \
    --user-data-dir="${app_profile_dir}" \
    --no-first-run \
    --no-default-browser-check \
    --hide-crash-restore-bubble \
    --app="${url}" 2>/dev/null || open "${url}"
}

#######################################
# Open a URL in a chromeless Chrome app window or the default host browser.
# Globals:
#   AGY_NO_BROWSER
# Arguments:
#   Target URL, app mode ("true" or "false"), and Chrome profile directory.
#######################################
open_ui_url() {
  local url="$1"
  local app_mode="$2"
  local app_profile_dir="$3"
  if command -v open &>/dev/null && [[ "${AGY_NO_BROWSER:-false}" != "true" ]]; then
    if [[ "${app_mode}" == "true" ]]; then
      open_chrome_app_window "${url}" "${app_profile_dir}"
    else
      open "${url}"
    fi
  fi
}
