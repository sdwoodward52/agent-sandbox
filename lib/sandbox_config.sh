#!/bin/bash
#
# Global environment paths, layout definitions, and container configuration
# generators for Antigravity Sandbox.

[[ -n "${_AGY_SANDBOX_CONFIG_LOADED:-}" ]] && return 0
_AGY_SANDBOX_CONFIG_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/logging.sh"

SANDBOX_ROOT="${SANDBOX_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"
SANDBOX_HOME="${AGY_SANDBOX_HOME:-${HOME:-/tmp}/.antigravity-sandbox}"
SKILLS_DEFAULT="${AGY_SKILLS_DIR:-${HOME}/antigravity_workspace/agents/skills}"
COMPOSE_FILE="${SANDBOX_ROOT}/docker-compose.yml"

declare -a PROTECTED_REPO_DIRS=(
  ".github"
  ".circleci"
  ".buildkite"
  ".husky"
  ".vscode"
  ".idea"
  ".agents"
  ".agent"
)
readonly PROTECTED_REPO_DIRS

declare -a PROTECTED_REPO_FILES=(
  ".gitlab-ci.yml"
  ".gitlab-ci.yaml"
  "Jenkinsfile"
  "azure-pipelines.yml"
  ".travis.yml"
  "cloudbuild.yaml"
  "bitbucket-pipelines.yml"
  ".gitattributes"
  ".gitmodules"
  ".gitconfig"
  ".pre-commit-config.yaml"
  ".envrc"
  ".mise.toml"
  ".continuerules"
  "hooks.json"
  "mcp_config.json"
  "config.worktree"
)
readonly PROTECTED_REPO_FILES

#######################################
# Format a sanitized tmux session name for a repository.
# Arguments:
#   Repository name string.
# Outputs:
#   Sanitized session name (e.g., agy-my_repo).
#######################################
session_name_for_repo() {
  printf 'agy-%s' "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_')"
}

#######################################
# Verify that a named Docker container is running; exit with error if not.
# Arguments:
#   Container name (defaults to agy-agent-sandbox).
#######################################
require_running_container() {
  local cname="${1:-agy-agent-sandbox}"
  if ! docker inspect -f '{{.State.Running}}' "${cname}" 2>/dev/null | grep -q "true"; then
    err "Container '${cname}' is not running. Start the pod with 'agy-sandbox up' or 'agy-workflow start' first."
  fi
}

#######################################
# Resolve the container working directory (/workspaces/<repo>) for an argument.
# Globals:
#   SANDBOX_HOME
# Arguments:
#   Optional target argument.
# Outputs:
#   Resolved container workspace directory path.
#######################################
resolve_container_workdir() {
  local target_arg="${1:-}"
  if [[ -n "${target_arg}" ]]; then
    echo "/workspaces/$(basename "${target_arg}")"
    return 0
  fi
  if git rev-parse --show-toplevel &>/dev/null; then
    local top
    top="$(git rev-parse --show-toplevel)"
    local rname
    rname="$(basename "${top}")"
    if [[ -f "${SANDBOX_HOME}/registry/${rname}.json" ]]; then
      echo "/workspaces/${rname}"
      return 0
    fi
  fi
  echo "/workspaces"
}

#######################################
# Generate Continue autocomplete configuration, secrets, and fallback proxy.
# Globals:
#   AGY_AUTOCOMPLETE_FALLBACK_MODELS
#   AGY_AUTOCOMPLETE_MODEL
#   ENV_FILE
#   GEMINI_API_KEY
#   SANDBOX_ROOT
#   STATE_DIR
#######################################
ensure_continue_config() {
  local continue_dir="${STATE_DIR}/continue"
  local continue_cfg="${continue_dir}/config.yaml"
  local continue_env="${continue_dir}/.env"
  local fallback_script="${continue_dir}/agy-gemini-fallback.py"
  local autocomplete_model="${AGY_AUTOCOMPLETE_MODEL:-gemini-flash-lite-latest}"
  local fallback_chain="${AGY_AUTOCOMPLETE_FALLBACK_MODELS:-gemini-3.1-flash-lite,gemini-2.5-flash,${autocomplete_model},gemini-3.6-flash,gemini-3.5-flash,gemini-flash-latest}"
  local resolved_key="${GEMINI_API_KEY:-}"

  mkdir -p "${continue_dir}"

  if [[ -z "${resolved_key}" && -f "${ENV_FILE}" ]]; then
    resolved_key="$(sed -n 's/^GEMINI_API_KEY="\(.*\)"$/\1/p' "${ENV_FILE}" | head -n 1 || true)"
  fi
  if [[ -z "${resolved_key}" && -f "${continue_env}" ]]; then
    resolved_key="$(sed -n 's/^GEMINI_API_KEY=\(.*\)$/\1/p' "${continue_env}" | head -n 1 || true)"
  fi

  cat > "${continue_env}" <<EOF
GEMINI_API_KEY=${resolved_key}
EOF

  cp -p "${SANDBOX_ROOT}/resources/fallback.py" "${fallback_script}"
  chmod 0755 "${fallback_script}"

  if [[ -n "${resolved_key}" ]]; then
    sed -e "s|__FALLBACK_CHAIN__|${fallback_chain}|g" \
        -e "s|__AUTOCOMPLETE_MODEL__|${autocomplete_model}|g" \
        "${SANDBOX_ROOT}/resources/continue-config.yaml" > "${continue_cfg}"
  else
    cp -p "${SANDBOX_ROOT}/resources/continue-empty.yaml" "${continue_cfg}"
  fi

  if command -v docker &>/dev/null && docker inspect -f '{{.State.Running}}' agy-agent-sandbox 2>/dev/null | grep -q "true"; then
    docker exec -d -e "AGY_AUTOCOMPLETE_FALLBACK_MODELS=${fallback_chain}" agy-agent-sandbox \
      python3 /home/agent/.continue/agy-gemini-fallback.py 2>/dev/null || true
  fi
}

#######################################
# Ensure in-sandbox Antigravity is configured with Turbo permission preset.
# Modifies ONLY sandbox state (${STATE_DIR}/gemini); never touches host ~/.gemini.
# Globals:
#   STATE_DIR
#######################################
ensure_sandbox_gemini_settings() {
  local cli_settings="${STATE_DIR}/gemini/antigravity-cli/settings.json"
  local app_config="${STATE_DIR}/gemini/config/config.json"
  mkdir -p "${STATE_DIR}/gemini/antigravity-cli" "${STATE_DIR}/gemini/config"

  if command -v python3 &>/dev/null; then
    python3 -c '
import json, os, sys
for path in sys.argv[1:]:
    data = {}
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = {}
    data["permissionPreset"] = "Turbo"
    if "antigravity-cli" in path:
        data.setdefault("agentMode", "auto")
    if "config.json" in path:
        user_settings = data.setdefault("userSettings", {})
        if isinstance(user_settings, dict):
            user_settings["permissionPreset"] = "AGENT_PERMISSION_PRESET_TURBO"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
' "${cli_settings}" "${app_config}" 2>/dev/null || true
  else
    if [[ ! -f "${cli_settings}" ]]; then
      cat > "${cli_settings}" <<EOF
{
  "permissionPreset": "Turbo",
  "agentMode": "auto"
}
EOF
    fi
    if [[ ! -f "${app_config}" ]]; then
      cat > "${app_config}" <<EOF
{
  "permissionPreset": "Turbo",
  "userSettings": {
    "permissionPreset": "AGENT_PERMISSION_PRESET_TURBO"
  }
}
EOF
    fi
  fi
}

#######################################
# Create or update an Antigravity project configuration file for a repo.
# Globals:
#   SANDBOX_ROOT
#   STATE_DIR
# Arguments:
#   Repository name string.
#######################################
ensure_agy_project_config() {
  local rname="${1:-}"
  [[ -n "${rname}" ]] || return 0
  local proj_file="${STATE_DIR}/gemini/config/projects/${rname}.json"
  mkdir -p "${STATE_DIR}/gemini/config/projects"
  sed "s|__PROJECT_NAME__|${rname}|g" "${SANDBOX_ROOT}/resources/project.json" > "${proj_file}"
}

#######################################
# Ensure .git/info/exclude ignores secret mask mount targets (e.g. .env, .env.local).
# Arguments:
#   Host repository path.
#######################################
ensure_git_exclude_entries() {
  local host_repo="$1"
  local exclude_file="${host_repo}/.git/info/exclude"
  [[ -d "${host_repo}/.git" ]] || return 0
  mkdir -p "${host_repo}/.git/info"
  touch "${exclude_file}"
  local pattern
  for pattern in "/.env" "/.env.local"; do
    if ! grep -qxF "${pattern}" "${exclude_file}" 2>/dev/null; then
      echo "${pattern}" >> "${exclude_file}"
    fi
  done
}

#######################################
# Generate docker-compose.overlays.yml with :rw source mounts & :ro metadata shadows.
# Globals:
#   EMPTY_HOOKS_DIR
#   OVERLAYS_COMPOSE_FILE
#   OVERLAYS_DIR
#   PROTECTED_REPO_DIRS
#   PROTECTED_REPO_FILES
#   REGISTRY_DIR
#   WORKSPACES_DIR
#######################################
generate_overlay_compose_override() {
  cat > "${OVERLAYS_COMPOSE_FILE}" <<EOF
services:
  agent-sandbox:
    volumes:
      - "${EMPTY_HOOKS_DIR}:/home/agent/.gemini/empty-hooks:ro"
EOF

  local meta
  for meta in "${REGISTRY_DIR}"/*.json; do
    [[ -f "${meta}" ]] || continue
    local rname
    rname="$(basename "${meta}" .json)"
    local host_repo
    host_repo="$(sed -n 's/.*"host_repo":[[:space:]]*"\([^"]*\)".*/\1/p' "${meta}")"
    [[ -n "${host_repo}" && -d "${host_repo}" ]] || continue

    local masks_dir="${OVERLAYS_DIR}/${rname}/masks"
    local ws_dir="${WORKSPACES_DIR}/${rname}"
    mkdir -p "${masks_dir}" "${ws_dir}"

    ensure_git_exclude_entries "${host_repo}"

    cat >> "${OVERLAYS_COMPOSE_FILE}" <<EOF
      - "${host_repo}:/workspaces/${rname}:rw"
EOF

    if [[ -d "${host_repo}/.git" ]]; then
      cat >> "${OVERLAYS_COMPOSE_FILE}" <<EOF
      - "${host_repo}/.git:/workspaces/${rname}/.git:ro"
EOF
      if [[ -d "${host_repo}/.git/hooks" ]]; then
        cat >> "${OVERLAYS_COMPOSE_FILE}" <<EOF
      - "${EMPTY_HOOKS_DIR}:/workspaces/${rname}/.git/hooks:ro"
EOF
      fi
    fi

    # Populate masks layer for .env and .env.local secrets if they exist on the host.
    # Non-existent files must NOT be mounted to avoid VirtioFS mountpoint creation failures.
    local env_base
    for env_base in ".env" ".env.local"; do
      if [[ -f "${host_repo}/${env_base}" ]]; then
        touch "${masks_dir}/${env_base}"
        chmod 0444 "${masks_dir}/${env_base}" 2>/dev/null || true
        cat >> "${OVERLAYS_COMPOSE_FILE}" <<EOF
      - "${masks_dir}/${env_base}:/workspaces/${rname}/${env_base}:ro"
EOF
      fi
    done

    local env_path
    for env_path in "${host_repo}"/.env.*; do
      [[ -f "${env_path}" ]] || continue
      local env_base
      env_base="$(basename "${env_path}")"
      case "${env_base}" in
        .env.local|.env.example|.env.sample|.env.template|.env.dist)
          continue
          ;;
      esac
      touch "${masks_dir}/${env_base}"
      chmod 0444 "${masks_dir}/${env_base}" 2>/dev/null || true
      cat >> "${OVERLAYS_COMPOSE_FILE}" <<EOF
      - "${masks_dir}/${env_base}:/workspaces/${rname}/${env_base}:ro"
EOF
    done

    local d
    for d in "${PROTECTED_REPO_DIRS[@]}"; do
      if [[ -d "${host_repo}/${d}" ]] && [[ -n "$(ls -A "${host_repo}/${d}" 2>/dev/null)" ]]; then
        cat >> "${OVERLAYS_COMPOSE_FILE}" <<EOF
      - "${host_repo}/${d}:/workspaces/${rname}/${d}:ro"
EOF
      fi
    done

    local f
    for f in "${PROTECTED_REPO_FILES[@]}"; do
      if [[ -e "${host_repo}/${f}" ]]; then
        cat >> "${OVERLAYS_COMPOSE_FILE}" <<EOF
      - "${host_repo}/${f}:/workspaces/${rname}/${f}:ro"
EOF
      fi
    done
  done
}

#######################################
# Initialize directories, environment files, and settings for the sandbox pod.
# Globals:
#   CANONICAL_SHOME
#   EMPTY_HOOKS_DIR
#   ENV_FILE
#   GEMINI_API_KEY
#   OVERLAYS_COMPOSE_FILE
#   OVERLAYS_DIR
#   REGISTRY_DIR
#   SANDBOX_HOME
#   SANDBOX_ROOT
#   SKILLS_DEFAULT
#   STATE_DIR
#   WORKSPACES_DIR
#######################################
ensure_sandbox_layout() {
  mkdir -p "${SANDBOX_HOME}"
  CANONICAL_SHOME="$(cd "${SANDBOX_HOME}" && pwd -P)"
  WORKSPACES_DIR="${CANONICAL_SHOME}/workspaces"
  OVERLAYS_DIR="${CANONICAL_SHOME}/overlays"
  REGISTRY_DIR="${CANONICAL_SHOME}/registry"
  STATE_DIR="${CANONICAL_SHOME}/state"
  EMPTY_HOOKS_DIR="${STATE_DIR}/empty-hooks"
  ENV_FILE="${STATE_DIR}/pod.env"
  OVERLAYS_COMPOSE_FILE="${STATE_DIR}/docker-compose.overlays.yml"

  mkdir -p \
    "${WORKSPACES_DIR}" \
    "${OVERLAYS_DIR}" \
    "${REGISTRY_DIR}" \
    "${EMPTY_HOOKS_DIR}" \
    "${STATE_DIR}/gemini/config/projects" \
    "${STATE_DIR}/gemini/config/skills" \
    "${STATE_DIR}/gemini/antigravity/brain" \
    "${STATE_DIR}/gemini/antigravity-cli" \
    "${STATE_DIR}/code-server/User" \
    "${STATE_DIR}/continue"

  if [[ ! -f "${STATE_DIR}/code-server/User/settings.json" ]] \
      || ! grep -q "autoForwardPorts" "${STATE_DIR}/code-server/User/settings.json" 2>/dev/null; then
    cp -p "${SANDBOX_ROOT}/resources/settings.json" "${STATE_DIR}/code-server/User/settings.json"
  fi

  if [[ ! -d "${SKILLS_DEFAULT}" ]]; then
    mkdir -p "${SKILLS_DEFAULT}"
  fi

  local resolved_gemini_key="${GEMINI_API_KEY:-}"
  if [[ -z "${resolved_gemini_key}" && -f "${ENV_FILE}" ]]; then
    resolved_key="$(sed -n 's/^GEMINI_API_KEY="\(.*\)"$/\1/p' "${ENV_FILE}" | head -n 1 || true)"
    if [[ -n "${resolved_key}" ]]; then
      resolved_gemini_key="${resolved_key}"
    fi
  fi

  cat > "${ENV_FILE}" <<EOF
SANDBOX_STATE_DIR="${STATE_DIR}"
SKILLS_DIR="${SKILLS_DEFAULT}"
GEMINI_API_KEY="${resolved_gemini_key}"
EOF

  ensure_sandbox_gemini_settings
  ensure_continue_config

  local meta
  for meta in "${REGISTRY_DIR}"/*.json; do
    [[ -f "${meta}" ]] || continue
    local rname
    rname="$(basename "${meta}" .json)"
    ensure_agy_project_config "${rname}"
  done

  generate_overlay_compose_override
}
