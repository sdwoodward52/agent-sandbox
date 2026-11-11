#!/bin/bash
#
# Pod lifecycle and container management command handlers for Antigravity Sandbox.

[[ -n "${_AGY_CMD_SANDBOX_LOADED:-}" ]] && return 0
_AGY_CMD_SANDBOX_LOADED=1

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${LIB_DIR}/sandbox_config.sh"
source "${LIB_DIR}/sandbox_lib.sh"
source "${LIB_DIR}/source_control_lib.sh"

#######################################
# List all registered repositories, container mount paths, and URLs.
# Globals:
#   CODE_SERVER_PORT
#   REGISTRY_DIR
# Outputs:
#   Formatted repository inventory to stdout.
#######################################
cmd_list() {
  ensure_sandbox_layout
  echo "=== Registered Sandbox Repositories (${REGISTRY_DIR}) ==="
  local port="${CODE_SERVER_PORT:-8443}"
  local -i found=0
  local meta
  for meta in "${REGISTRY_DIR}"/*.json; do
    [[ -f "${meta}" ]] || continue
    (( found += 1 ))
    local rname
    rname="$(basename "${meta}" .json)"
    local host_repo
    host_repo="$(sed -n 's/.*"host_repo":[[:space:]]*"\([^"]*\)".*/\1/p' "${meta}")"
    local remote_url
    remote_url="$(extract_remote_url "${rname}")"
    echo "  - ${rname}"
    echo "      Host Repo      : ${host_repo}"
    echo "      Container Path : /workspaces/${rname}"
    echo "      Web IDE URL    : http://127.0.0.1:${port}/?folder=/workspaces/${rname}"
    if [[ -n "${remote_url}" ]]; then
      echo "      Chat Web URL   : ${remote_url}"
    fi
  done
  if (( found == 0 )); then
    echo "  (none yet — run 'agy-workflow start <dir>' to add a repository)"
  fi
}

#######################################
# Open an interactive bash shell inside agy-agent-sandbox as unprivileged UID 1000.
# Arguments:
#   Optional target directory path to resolve container workdir.
#######################################
cmd_shell() {
  require_running_container agy-agent-sandbox
  local workdir
  workdir="$(resolve_container_workdir "${1:-}")"
  info "Opening unprivileged shell inside agy-agent-sandbox at ${workdir} (UID 1000)..."
  docker exec -it -w "${workdir}" agy-agent-sandbox /bin/bash
}

#######################################
# Ensure sandbox pod containers are running with current mount configuration.
# Arguments:
#   Flags (--rebuild) and optional target directory.
#######################################
cmd_up() {
  local force_rebuild="false"
  local target_dir=""

  while (( $# > 0 )); do
    case "$1" in
      --rebuild)
        force_rebuild="true"
        shift
        ;;
      -*)
        err "Unknown flag for up: $1"
        ;;
      *)
        target_dir="$1"
        shift
        ;;
    esac
  done

  if [[ -n "${target_dir}" ]]; then
    mkdir -p "${target_dir}"
    cd "${target_dir}"
  fi

  ensure_sandbox_layout

  if [[ -n "${target_dir}" ]] || git rev-parse --show-toplevel &>/dev/null; then
    register_sandbox_repo "${target_dir}"
  fi

  if [[ "${force_rebuild}" != "true" ]] && is_pod_running && is_repo_mounted_in_container; then
    ok "Sandbox Pod is already running (existing sessions preserved)."
  else
    local active_sessions
    active_sessions="$(capture_active_sessions)"
    info "Starting Antigravity Sandbox Pod (egress-proxy + agent-sandbox with Read-Only Metadata Guards)..."
    if [[ "${force_rebuild}" == "true" ]]; then
      compose_cmd up -d --build
    else
      compose_cmd up -d
    fi
    restore_active_sessions "${active_sessions}"
    ok "Sandbox pod is running."
  fi
}

#######################################
# All-in-one command: register repo, launch pod, open IDE, and launch chat.
# Globals:
#   AGY_WORKFLOW_BIN
#   SANDBOX_ROOT
# Arguments:
#   Options and flags for start, ide, and chat, plus optional target directory.
#######################################
cmd_start() {
  local open_remote="true"
  local detach_remote="true"
  local force_rebuild="false"
  local ide_flag=""
  local remote_app_flag=""
  local target_dir=""

  while (( $# > 0 )); do
    case "$1" in
      --no-remote)
        open_remote="false"
        shift
        ;;
      -t|--tui|--attach)
        detach_remote="false"
        shift
        ;;
      -d|--detach|--headless)
        detach_remote="true"
        shift
        ;;
      --rebuild)
        force_rebuild="true"
        shift
        ;;
      --app)
        ide_flag="--app"
        remote_app_flag="--app"
        shift
        ;;
      --native)
        ide_flag="--native"
        shift
        ;;
      --browser)
        ide_flag="--browser"
        remote_app_flag="--browser"
        shift
        ;;
      -*)
        err "Unknown flag for start: $1"
        ;;
      *)
        target_dir="$1"
        shift
        ;;
    esac
  done

  if [[ "${force_rebuild}" == "true" ]]; then
    if [[ -n "${target_dir}" ]]; then
      cmd_up --rebuild "${target_dir}"
    else
      cmd_up --rebuild
    fi
  else
    if [[ -n "${target_dir}" ]]; then
      cmd_up "${target_dir}"
    else
      cmd_up
    fi
  fi

  local wf_bin="${AGY_WORKFLOW_BIN:-${SANDBOX_ROOT}/bin/agy-workflow}"

  local -a ide_args=()
  if [[ -n "${ide_flag}" ]]; then
    ide_args+=("${ide_flag}")
  fi
  if [[ -n "${target_dir}" ]]; then
    ide_args+=("${target_dir}")
  fi
  "${wf_bin}" ide ${ide_args[@]+"${ide_args[@]}"}

  if [[ "${open_remote}" == "true" ]]; then
    local -a chat_args=()
    if [[ "${detach_remote}" != "true" ]]; then
      chat_args+=("--tui")
    fi
    if [[ -n "${remote_app_flag}" ]]; then
      chat_args+=("${remote_app_flag}")
    fi
    if [[ -n "${target_dir}" ]]; then
      chat_args+=("${target_dir}")
    fi
    "${wf_bin}" chat ${chat_args[@]+"${chat_args[@]}"}
  fi
}

#######################################
# Stop the sandbox pod and related services cleanly.
#######################################
cmd_down() {
  ensure_sandbox_layout
  info "Stopping Antigravity Sandbox Pod..."
  compose_cmd down
  ok "Sandbox pod stopped."
}

#######################################
# Fast-update the Antigravity CLI binary inside the sandbox with cached layers.
# Globals:
#   AGY_CACHEBUST
#   AGY_WORKFLOW_BIN
#   REGISTRY_DIR
#   SANDBOX_ROOT
#######################################
cmd_update() {
  ensure_sandbox_layout

  local old_version="not running"
  local active_sessions=""
  if docker inspect -f '{{.State.Running}}' agy-agent-sandbox 2>/dev/null | grep -q "true"; then
    old_version="$(docker exec agy-agent-sandbox sh -c "agy --version 2>/dev/null || echo 'unknown'" | tr -d '\r')"
    active_sessions="$(capture_active_sessions)"
  fi

  info "Current sandbox 'agy' CLI version: ${old_version}"
  info "Rebuilding ONLY the Antigravity CLI layer in agy-agent-sandbox (OS & code-server layers remain cached)..."

  local cachebust
  cachebust="$(date +%s)"
  AGY_CACHEBUST="${cachebust}" compose_cmd build \
    --build-arg "AGY_CACHEBUST=${cachebust}" agent-sandbox

  info "Recreating agy-agent-sandbox with updated 'agy' binary (workspaces & Gemini history preserved)..."
  AGY_CACHEBUST="${cachebust}" compose_cmd up -d

  local new_version
  new_version="$(docker exec agy-agent-sandbox sh -c "agy --version 2>/dev/null || echo 'unknown'" | tr -d '\r')"
  ok "Updated sandbox 'agy' CLI: ${old_version} -> ${new_version}"

  if [[ -n "${active_sessions}" ]]; then
    restore_active_sessions "${active_sessions}"
    ok "Restored active background remote-control session(s)."
  elif git rev-parse --show-toplevel &>/dev/null; then
    local top_dir
    top_dir="$(git rev-parse --show-toplevel)"
    local rname
    rname="$(basename "${top_dir}")"
    if [[ -f "${REGISTRY_DIR}/${rname}.json" ]]; then
      local wf_bin="${AGY_WORKFLOW_BIN:-${SANDBOX_ROOT}/bin/agy-workflow}"
      "${wf_bin}" chat "${top_dir}"
    fi
  fi
}
