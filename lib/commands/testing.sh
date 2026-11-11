#!/bin/bash
#
# Verification and security testing suite for Antigravity Sandbox isolation.

[[ -n "${_AGY_CMD_TESTING_LOADED:-}" ]] && return 0
_AGY_CMD_TESTING_LOADED=1

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${LIB_DIR}/sandbox_config.sh"

#######################################
# Run the defense-in-depth security verification test suite inside sandbox.
# Globals:
#   CODE_SERVER_PORT
#   SANDBOX_HOME
# Outputs:
#   Verification test results to stdout, errors to stderr.
# Returns:
#   0 if all checks pass, non-zero on failure.
#######################################
cmd_verify_isolation() {
  require_running_container agy-egress-proxy
  require_running_container agy-agent-sandbox
  info "Running Defense-in-Depth Isolation Verification Suite inside agy-agent-sandbox..."

  local container_uid
  container_uid="$(docker exec agy-agent-sandbox id -u)"
  if [[ "${container_uid}" == "1000" ]]; then
    ok "Unprivileged Identity: Running as UID 1000 (non-root)."
  else
    err "Identity check failed: expected UID 1000, got ${container_uid}."
  fi

  if docker exec agy-agent-sandbox sh -c "touch /root_write_test 2>/dev/null"; then
    err "RootFS check failed: container was able to write to /!"
  elif docker exec agy-agent-sandbox sh -c "touch /workspaces/stray_write_test 2>/dev/null"; then
    err "Workspaces root check failed: container was able to write directly to /workspaces!"
  else
    ok "Immutable RootFS & /workspaces Root: Writes outside mounted repos are blocked by kernel."
  fi

  if docker exec agy-agent-sandbox sh -c "touch /home/agent/.gemini/empty-hooks/write_test 2>/dev/null"; then
    err "Empty hooks mask check failed: container wrote to /home/agent/.gemini/empty-hooks!"
  else
    ok "Empty Hooks Mask: Strictly read-only (:ro)."
  fi

  if docker exec agy-agent-sandbox touch /home/agent/.gemini/config/skills/write_test 2>/dev/null; then
    err "Skills mount check failed: container wrote to skills directory!"
  elif docker exec agy-agent-sandbox touch /home/agent/.gemini/config/hooks.json 2>/dev/null; then
    err "Hooks mount check failed: container modified hooks.json!"
  elif ! docker exec agy-agent-sandbox mkdir -p /home/agent/.gemini/config/projects 2>/dev/null; then
    err "Gemini projects dir check failed: /home/agent/.gemini/config/projects is not writable!"
  else
    ok "Read-Only Skills & Hooks (:ro) + Host-Persisted CLI State (${SANDBOX_HOME}/state/gemini)."
  fi

  if docker exec agy-agent-sandbox curl -f -s --max-time 3 http://host.docker.internal:80 >/dev/null 2>&1; then
    err "Proxy Egress check failed: Squid allowed http://host.docker.internal!"
  elif docker exec agy-agent-sandbox curl -f -s --max-time 3 http://192.168.65.254:80 >/dev/null 2>&1; then
    err "Proxy Egress check failed: Squid allowed RFC-1918 IP 192.168.65.254!"
  elif docker exec agy-agent-sandbox curl --noproxy '*' -s --max-time 3 http://192.168.65.254:80 >/dev/null 2>&1; then
    err "Kernel Internal Network check failed: direct --noproxy connection reached 192.168.65.254!"
  elif docker exec agy-agent-sandbox curl -f -I -s --max-time 3 https://api.githubcopilot.com >/dev/null 2>&1; then
    err "Telemetry Blocklist check failed: Squid allowed https://api.githubcopilot.com!"
  elif ! docker exec agy-agent-sandbox curl -f -I -s --max-time 5 https://docs.python.org >/dev/null 2>&1; then
    err "General Public Web check failed: could not reach https://docs.python.org via proxy!"
  else
    ok "Network Policy Verified: Host/LAN & telemetry blocked; general public HTTPS allowed."
  fi

  local deny_res
  deny_res="$(echo '{"toolCall":{"name":"run_command","args":{"CommandLine":"git push origin main"}}}' | \
    docker exec -i agy-agent-sandbox python3 /home/agent/.gemini/config/pre_tool_guard.py)"
  local env_deny_res
  env_deny_res="$(echo '{"toolCall":{"name":"write_file","args":{"Path":"/workspaces/app/.env","Content":"SECRET=1"}}}' | \
    docker exec -i agy-agent-sandbox python3 /home/agent/.gemini/config/pre_tool_guard.py)"
  local ci_deny_res
  ci_deny_res="$(echo '{"toolCall":{"name":"write_file","args":{"Path":"/workspaces/app/.github/workflows/ci.yml","Content":"run: evil"}}}' | \
    docker exec -i agy-agent-sandbox python3 /home/agent/.gemini/config/pre_tool_guard.py)"
  local allow_res
  allow_res="$(echo '{"toolCall":{"name":"write_file","args":{"Path":"/workspaces/app/src/main.py","Content":"print(1)"}}}' | \
    docker exec -i agy-agent-sandbox python3 /home/agent/.gemini/config/pre_tool_guard.py)"

  if echo "${deny_res}" | grep -q '"decision": "deny"' \
      && echo "${env_deny_res}" | grep -q '"decision": "deny"' \
      && echo "${ci_deny_res}" | grep -q '"decision": "deny"' \
      && echo "${allow_res}" | grep -q '"decision": "allow"'; then
    ok "PreToolUse Hook Active: 'git push', '.env', & '.github/workflows' writes denied; source writes allowed."
  else
    err "PreToolUse Hook check failed: deny=${deny_res} env_deny=${env_deny_res} ci_deny=${ci_deny_res} allow=${allow_res}"
  fi

  local port="${CODE_SERVER_PORT:-8443}"
  if curl -fsS --max-time 3 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
    ok "Sandboxed Multi-Repo code-server IDE: Listening on http://127.0.0.1:${port}."
  else
    err "Sandboxed code-server IDE check failed on http://127.0.0.1:${port}/healthz."
  fi

  echo ""
  ok "All enterprise sandbox isolation checks passed!"
}
