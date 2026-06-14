#!/usr/bin/env bash
#
# dsb.sh - Automated Docker services backup using restic.
#
# This script identifies Docker containers with a specific label, stops them,
# performs a restic backup of a specified directory (default: /services),
# and restarts the containers. It acts as a thin orchestrator for restic.

set -o errexit
set -o nounset
set -o pipefail

# Default configuration
readonly DSB_VERSION="0.2.0"
readonly DEFAULT_BACKUP_PATH="/services"
readonly DEFAULT_STOP_LABEL="dsb.stop.required=true"

# Globals for configuration (set via flags or environment)
DSB_BACKUP_PATH="${DSB_BACKUP_PATH:-$DEFAULT_BACKUP_PATH}"
DSB_STOP_LABEL="${DSB_STOP_LABEL:-$DEFAULT_STOP_LABEL}"
DSB_RESTIC_TAGS="${DSB_RESTIC_TAGS:-$(hostname)}"

# Array to hold custom restic options
declare -a DSB_RESTIC_OPTIONS=()

#######################################
# Builds the restic command array based on current configuration.
# Globals:
#   DSB_RESTIC_OPTIONS
#   RESTIC_CMD
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0
#######################################
build_restic_cmd() {
  RESTIC_CMD=(restic)

  for opt in "${DSB_RESTIC_OPTIONS[@]}"; do
    RESTIC_CMD+=("-o" "${opt}")
  done
}

# Global array for the restic command
declare -a RESTIC_CMD=()

#######################################
# Wraps text in ANSI color codes for terminal output.
# Globals:
#   None
# Arguments:
#   1: Color name (e.g., red, green)
#   2: Text string to format
# Outputs:
#   Writes colorized string to stdout.
# Returns:
#   0
#######################################
colorize() {
  local color="$1"
  local text="$2"
  local code

  case "${color}" in
    red)    code='\033[0;31m' ;;
    green)  code='\033[0;32m' ;;
    yellow) code='\033[0;33m' ;;
    blue)   code='\033[0;34m' ;;
    *)      code='\033[0m'    ;;
  esac
  printf "%b%s\033[0m" "${code}" "${text}"
}

#######################################
# Unified logging function.
# Globals:
#   None
# Arguments:
#   1: Log level (info, success, warn, error)
#   2: Message string
# Outputs:
#   Writes formatted log messages to stdout or stderr.
# Returns:
#   0
#######################################
log() {
  local level="$1"
  local msg="$2"

  case "${level}" in
    info)    printf "%s %s\n" "$(colorize blue "INFO:")" "${msg}" ;;
    success) printf "%s %s\n" "$(colorize green "SUCCESS:")" "${msg}" ;;
    warn)    printf "%s %s\n" "$(colorize yellow "WARN:")" "${msg}" ;;
    error)   printf "%s %s\n" "$(colorize red "ERROR:")" "${msg}" >&2 ;;
    *)       printf "%s\n" "${msg}" ;;
  esac
}

#######################################
# Gets the application name for display, handling Nix wrappers.
# Globals:
#   0
# Arguments:
#   None
# Outputs:
#   Writes the script name or 'dsb' if wrapped.
# Returns:
#   0
#######################################
get_app_name() {
  local name="$0"
  if [[ "${name}" == *".dsb-wrapped" ]]; then
    echo "dsb"
  else
    basename "${name}"
  fi
}

#######################################
# Displays usage information.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes usage instructions to stdout.
# Returns:
#   0
#######################################
usage() {
  local b
  b=$(colorize green "$(get_app_name)")

  cat <<EOF
Usage: ${b} [options] <command> [args...]

$(colorize blue "Commands:")
  $(colorize green "backup")    Perform the backup process.
  $(colorize green "check")     Verify the integrity of the restic repository.
  $(colorize green "prune")     Remove old snapshots according to policy.
  $(colorize green "list")      List snapshots in the repository.
  $(colorize green "restic")    Pass all subsequent args directly to restic.

$(colorize blue "Options:")
  -p, --path PATH           Backup source path (default: ${DEFAULT_BACKUP_PATH})
  -l, --label LABEL         Docker label to filter (default: ${DEFAULT_STOP_LABEL})
  -r, --repo REPO           Restic repo URL (sets RESTIC_REPOSITORY)
  -R, --repo-file FILE      File with repo URL (sets RESTIC_REPOSITORY_FILE)
  -w, --password-file FILE  Restic password file (sets RESTIC_PASSWORD_FILE)
  -o, --option OPTION       Custom option for restic (e.g., sftp.args="...")
  -t, --tags TAGS           Comma-separated tags (default: ${DSB_RESTIC_TAGS})
  -v, --version             Show version information
  -h, --help                Show this help message

$(colorize blue "Environment Variables:")
  [Core Config]
    $(colorize yellow "DSB_BACKUP_PATH")      Backup source path
    $(colorize yellow "DSB_STOP_LABEL")       Docker label to stop containers
    $(colorize yellow "DSB_RESTIC_TAGS")      Tags for the backup snapshot

  [Restic Config]
    $(colorize yellow "RESTIC_REPOSITORY")      Restic repository URL
    $(colorize yellow "RESTIC_REPOSITORY_FILE") File with restic repo URL
    $(colorize yellow "RESTIC_PASSWORD_FILE")   Path to restic password file
    $(colorize yellow "RESTIC_PASSWORD")        Raw password (alternative to file)

$(colorize blue "Examples:")
  1. Standard backup to S3:
     ${b} -r s3:s3.amazonaws.com/bucket -w /path/to/pass backup

  2. Automated SFTP backup preventing hangs:
     ${b} -r sftp:user@host:/dir -o sftp.args="-o BatchMode=yes" backup

  3. Restore latest backup using the pass-through command:
     ${b} -r /local/backups restic restore latest --target /tmp
EOF
}

#######################################
# Checks if required tools are installed.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes error messages to stderr if tools are missing.
# Returns:
#   0 if all tools found, 1 otherwise.
#######################################
check_dependencies() {
  local tools=("docker" "restic")
  local missing=0

  for tool in "${tools[@]}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      log "error" "Required tool '${tool}' is not installed."
      missing=1
    fi
  done

  return "${missing}"
}

#######################################
# Identifies containers that need to be stopped.
# Globals:
#   DSB_STOP_LABEL
# Arguments:
#   None
# Outputs:
#   Writes container IDs to stdout.
# Returns:
#   0
#######################################
get_labeled_containers() {
  docker ps --filter "label=${DSB_STOP_LABEL}" --filter "status=running" \
    --format "{{.ID}}:{{.Names}}"
}

#######################################
# Stops a list of Docker containers.
# Globals:
#   None
# Arguments:
#   1: Space-separated list of container IDs
# Outputs:
#   Writes progress logs to stdout.
# Returns:
#   0 if all stopped successfully, 1 if any failed.
#######################################
stop_containers() {
  local containers
  read -ra containers <<< "$1"
  local status=0

  if [[ ${#containers[@]} -eq 0 ]]; then
    log "info" "No containers to stop."
    return 0
  fi

  log "info" "Stopping labeled containers..."
  for entry in "${containers[@]}"; do
    local id="${entry%%:*}"
    local name="${entry#*:}"
    log "info" "Stopping container: ${name} (${id})"
    if ! docker stop "${id}" >/dev/null; then
      log "error" "Failed to stop container: ${name} (${id})"
      status=1
    fi
  done
  return "${status}"
}

#######################################
# Starts a list of Docker containers.
# Globals:
#   None
# Arguments:
#   1: Space-separated list of container IDs
# Outputs:
#   Writes progress logs to stdout.
# Returns:
#   0
#######################################
start_containers() {
  local containers
  read -ra containers <<< "$1"

  if [[ ${#containers[@]} -eq 0 ]]; then
    return 0
  fi

  log "info" "Starting containers back up..."
  for entry in "${containers[@]}"; do
    local id="${entry%%:*}"
    local name="${entry#*:}"
    log "info" "Starting container: ${name} (${id})"
    if ! docker start "${id}" >/dev/null; then
      log "error" "Failed to start container: ${name} (${id})"
    fi
  done
}

#######################################
# Verifies that specific containers are fully stopped.
# Globals:
#   None
# Arguments:
#   1: Space-separated list of container IDs
# Outputs:
#   Writes progress logs to stdout.
# Returns:
#   0 if all stopped, 1 if any are still running.
#######################################
verify_containers_stopped() {
  local containers
  read -ra containers <<< "$1"
  local status=0

  if [[ ${#containers[@]} -eq 0 ]]; then
    return 0
  fi

  log "info" "Verifying containers are stopped..."
  for entry in "${containers[@]}"; do
    local id="${entry%%:*}"
    local name="${entry#*:}"
    local is_running
    is_running=$(docker inspect -f '{{.State.Running}}' "${id}" \
      2>/dev/null || echo "false")
    if [[ "${is_running}" == "true" ]]; then
      log "error" "Container ${name} (${id}) is still running!"
      status=1
    fi
  done
  return "${status}"
}

#######################################
# Runs the restic backup command.
# Globals:
#   DSB_BACKUP_PATH
#   DSB_RESTIC_TAGS
#   RESTIC_CMD
# Arguments:
#   None
# Outputs:
#   Writes restic output and logs to stdout.
# Returns:
#   Status code of the restic command.
#######################################
run_restic_backup() {
  log "info" "Starting restic backup of ${DSB_BACKUP_PATH}..."

  # Ensure repository is initialized
  # Restic init returns error if already initialized, we ignore it.
  "${RESTIC_CMD[@]}" init >/dev/null 2>&1 || true

  "${RESTIC_CMD[@]}" backup \
    --tag "${DSB_RESTIC_TAGS}" \
    "${DSB_BACKUP_PATH}"
}

#######################################
# Executes the full backup workflow.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes workflow logs to stdout.
# Returns:
#   0 if successful, non-zero otherwise.
#######################################
do_backup() {
  local containers
  local status=0

  containers=$(get_labeled_containers)

  # Guarantee containers start on script exit, error, or interrupt
  if [[ -n "${containers}" ]]; then
    trap 'start_containers "${containers}"' EXIT
  fi

  if ! stop_containers "${containers}"; then
    log "error" "Failed to stop all required containers. Aborting backup."
    status=1
  elif ! verify_containers_stopped "${containers}"; then
    log "error" "Verification failed: containers still running."
    status=1
  elif ! run_restic_backup; then
    log "error" "Backup failed!"
    status=1
  else
    log "success" "Backup completed successfully."
  fi

  # Clear trap and start manually to avoid starting twice
  if [[ -n "${containers}" ]]; then
    trap - EXIT
    start_containers "${containers}"
  fi

  return "${status}"
}

#######################################
# Validates the restic repository.
# Globals:
#   RESTIC_CMD
# Arguments:
#   None
# Outputs:
#   Writes restic check output to stdout.
# Returns:
#   Status code of restic check.
#######################################
do_check() {
  log "info" "Checking restic repository integrity..."
  "${RESTIC_CMD[@]}" check
}

#######################################
# Prunes old snapshots.
# Globals:
#   DSB_RESTIC_TAGS
#   RESTIC_CMD
# Arguments:
#   None
# Outputs:
#   Writes restic forget/prune output to stdout.
# Returns:
#   Status code of restic command.
#######################################
do_prune() {
  log "info" "Pruning old snapshots for tag ${DSB_RESTIC_TAGS}..."
  "${RESTIC_CMD[@]}" forget \
    --tag "${DSB_RESTIC_TAGS}" \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune
}

#######################################
# Main script entry point.
# Globals:
#   All configuration globals.
# Arguments:
#   Script arguments ($@)
# Outputs:
#   Standard script output.
# Returns:
#   0 on success, exit code on failure.
#######################################
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p | --path)          DSB_BACKUP_PATH="$2"; shift 2 ;;
      -l | --label)         DSB_STOP_LABEL="$2"; shift 2 ;;
      -r | --repo)          export RESTIC_REPOSITORY="$2"; shift 2 ;;
      -R | --repo-file)     export RESTIC_REPOSITORY_FILE="$2"; shift 2 ;;
      -w | --password-file) export RESTIC_PASSWORD_FILE="$2"; shift 2 ;;
      -o | --option)        DSB_RESTIC_OPTIONS+=("$2"); shift 2 ;;
      -t | --tags)          DSB_RESTIC_TAGS="$2"; shift 2 ;;
      -v | --version)       echo "dsb version ${DSB_VERSION}"; return 0 ;;
      -h | --help)          usage; return 0 ;;
      -*)                   log "error" "Unknown option $1"; usage; return 1 ;;
      *)                    break ;; # First positional argument (command)
    esac
  done

  local command="${1:-}"
  shift || true # Remove command to leave any subsequent args for pass-through

  if [[ -z "${command}" ]]; then
    log "error" "No command specified."
    usage
    return 1
  fi

  if ! check_dependencies; then
    return 1
  fi

  build_restic_cmd

  # Validate essential config for restic
  if [[ -z "${RESTIC_REPOSITORY:-}" ]] && \
     [[ -z "${RESTIC_REPOSITORY_FILE:-}" ]]; then
    log "error" "RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE must be set."
    return 1
  fi
  if [[ -z "${RESTIC_PASSWORD_FILE:-}" ]] && \
     [[ -z "${RESTIC_PASSWORD:-}" ]]; then
    log "error" "RESTIC_PASSWORD or RESTIC_PASSWORD_FILE must be set."
    return 1
  fi

  case "${command}" in
    backup) do_backup ;;
    check)  do_check ;;
    prune)  do_prune ;;
    list)   "${RESTIC_CMD[@]}" snapshots ;;
    restic) "${RESTIC_CMD[@]}" "$@" ;;
    *)
      log "error" "Unknown command: ${command}"
      usage
      return 1
      ;;
  esac
}

# Execute main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
  exit $?
fi
