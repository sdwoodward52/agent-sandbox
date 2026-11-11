#!/bin/bash
#
# Logging utilities for Antigravity host CLI and sandbox tools.

[[ -n "${_AGY_LOGGING_LOADED:-}" ]] && return 0
_AGY_LOGGING_LOADED=1

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

#######################################
# Print an informational message.
# Globals:
#   AGY_CLI_NAME
#   BLUE
#   NC
# Arguments:
#   Message string(s).
# Outputs:
#   Writes formatted message to stdout.
#######################################
info() {
  echo -e "${BLUE}[${AGY_CLI_NAME:-agy-sandbox}]${NC} $*"
}

#######################################
# Print a success confirmation message.
# Globals:
#   GREEN
#   NC
# Arguments:
#   Message string(s).
# Outputs:
#   Writes formatted message to stdout.
#######################################
ok() {
  echo -e "${GREEN}[OK]${NC} $*"
}

#######################################
# Print a warning message.
# Globals:
#   YELLOW
#   NC
# Arguments:
#   Message string(s).
# Outputs:
#   Writes formatted message to stdout.
#######################################
warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

#######################################
# Print an error message to stderr and terminate.
# Globals:
#   RED
#   NC
# Arguments:
#   Error message string(s).
# Outputs:
#   Writes formatted message to stderr.
# Returns:
#   Exits with status 1.
#######################################
err() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}
