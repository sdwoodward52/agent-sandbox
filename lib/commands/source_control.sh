#!/bin/bash
#
# Source control and workspace status command handlers for Antigravity Sandbox.

[[ -n "${_AGY_CMD_SOURCE_CONTROL_LOADED:-}" ]] && return 0
_AGY_CMD_SOURCE_CONTROL_LOADED=1

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${LIB_DIR}/sandbox_config.sh"
source "${LIB_DIR}/sandbox_lib.sh"
source "${LIB_DIR}/source_control_lib.sh"

#######################################
# Initialize and register a host repository with direct source mounts.
# Arguments:
#   Optional path to target repository directory.
#######################################
cmd_init() {
  register_sandbox_repo "$@"
}

#######################################
# Display workspace and sandbox status for the active repository.
# Globals:
#   AGY_AUTOCOMPLETE_MODEL
#   CODE_SERVER_PORT
#   REPO_NAME
#   STATE_DIR
#   TRUSTED_REPO
# Arguments:
#   Optional flags (--compact, -c).
# Outputs:
#   Writes status information to stdout.
#######################################
cmd_status() {
  local compact="false"
  while (( $# > 0 )); do
    case "$1" in
      --compact|-c)
        compact="true"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  require_trusted_repo "false"
  local port="${CODE_SERVER_PORT:-8443}"

  if [[ "${compact}" == "true" ]]; then
    echo "=== Antigravity Workspace (/workspaces/${REPO_NAME}) ==="
    local short_st
    short_st="$(git_in_repo "${TRUSTED_REPO}" status -s)"
    if [[ -z "${short_st}" ]]; then
      echo "  (clean - no uncommitted modifications)"
    else
      echo "${short_st}" | sed 's/^/  /'
    fi
    return 0
  fi

  local remote_url
  remote_url="$(extract_remote_url "${REPO_NAME}")"

  echo "=== Antigravity Sandbox Status (${REPO_NAME}) ==="
  echo "  Trusted Repo     : ${TRUSTED_REPO} (:rw source mount at /workspaces/${REPO_NAME})"
  echo "  Read-Only Guards : .git:ro, .git/hooks:ro, .github:ro, .vscode:ro, .env*:ro"
  echo "  Repo Web IDE URL : http://127.0.0.1:${port}/?folder=/workspaces/${REPO_NAME}"
  if [[ -n "${remote_url}" ]]; then
    echo "  Chat Web URL     : ${remote_url}"
  fi
  if [[ -f "${STATE_DIR}/continue/.env" ]] \
      && grep -q '^GEMINI_API_KEY=.\+' "${STATE_DIR}/continue/.env" 2>/dev/null; then
    echo "  AI Autocomplete  : enabled (${AGY_AUTOCOMPLETE_MODEL:-gemini-flash-lite-latest} + auto-fallback)"
  else
    echo "  AI Autocomplete  : disabled (run 'agy-sandbox auth --api-key <GEMINI_API_KEY>' to enable)"
  fi

  if command -v docker &>/dev/null; then
    local proxy_running
    proxy_running="$(docker inspect -f '{{.State.Running}}' agy-egress-proxy 2>/dev/null || echo "false")"
    local agent_running
    agent_running="$(docker inspect -f '{{.State.Running}}' agy-agent-sandbox 2>/dev/null || echo "false")"
    echo "  Egress Proxy     : running=${proxy_running}"
    echo "  Agent Container  : running=${agent_running}"
  fi

  echo ""
  echo "--- Git Status (${TRUSTED_REPO}) ---"
  git_in_repo "${TRUSTED_REPO}" status -sb | sed 's/^/  /'
}
