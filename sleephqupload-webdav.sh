#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Script Name:    webdavsleephq.sh
# Version:        1.3.7
# Author:         hypascend
# Last Modified:  2025-01-05
#
# Description:
#   Downloads data from WebDAV location and uploads to SleepHQ.
#------------------------------------------------------------------------------

# Safety settings: stop on error, treat unset variables as errors, disable filename expansion
set -euo pipefail
IFS=$'\n\t'

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.3.7"
readonly SCRIPT_AUTHOR="hypascend"
readonly SCRIPT_LAST_MODIFIED="2025-01-05"

# API URL
readonly BASE_URL="https://sleephq.com"
readonly TOKEN_URL="${BASE_URL}/oauth/token"
readonly API_URL="${BASE_URL}/api/v1"

# Default exit codes
readonly E_SUCCESS=0
readonly E_FAILURE=1
readonly E_CONFIG_MISSING=2
readonly E_PERMISSIONS=3
readonly E_MISSING_TOOLS=4
readonly E_RCLONE_CONFIG=5
readonly E_RCLONE_CONNECTION=6
readonly E_DATE_ERROR=7
readonly E_TOKEN_ERROR=8

# Config directory can be set here or it will default to a config file where the script is run from
CONFIG_DIR="/mnt/user/cpap/config"

# Tools required by this script
readonly REQUIRED_TOOLS=(
  "curl"
  "jq"
  "rclone"
  "zip"
  "md5sum"
  "find"
  "stat"
  "chmod"
  "date"
)

# Initialize log file once we know LOG_DIR
LOG_FILE=""

#------------------------------------------------------------------------------
# Function: log
# Purpose:
#   Logs messages with a timestamp in both console and a log file (if available).
#------------------------------------------------------------------------------
log() {
  local level="$1"
  shift
  local message="[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [${level}] $*"
  echo "${message}"
								 
  [[ -n "${LOG_FILE}" ]] && echo "${message}" >> "${LOG_FILE}" || echo "Failed to write to log file"
	
}

#------------------------------------------------------------------------------
# Function: handle_error
# Purpose:
#   Log an error message, then exit with a specified exit code.
#------------------------------------------------------------------------------
handle_error() {
  log "ERROR" "$1"
  exit "${2:-${E_FAILURE}}"
}

#------------------------------------------------------------------------------
# Function: check_required_tools
# Purpose:
#   Verify that all required tools are installed on the system.
#------------------------------------------------------------------------------
check_required_tools() {
  for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "${tool}" &>/dev/null || handle_error "Required tool not found: ${tool}" "${E_MISSING_TOOLS}"
  done
}

#------------------------------------------------------------------------------
# Function: load_configuration
# Purpose:
#   Load and validate the configuration including credentials.
#------------------------------------------------------------------------------
load_configuration() {
  local default_settings_file="./settings.conf"
  local custom_settings_file="${CONFIG_DIR}/settings.conf"
  local settings_file="${custom_settings_file}"

  [[ ! -f "${settings_file}" ]] && settings_file="${default_settings_file}"
  [[ ! -f "${settings_file}" ]] && handle_error "Settings file not found at ${settings_file}" "${E_CONFIG_MISSING}"

  source "${settings_file}" || handle_error "Failed to load settings file" "${E_FAILURE}"

  local required_vars=("BASE_DIR" "CLIENT_ID" "CLIENT_SECRET" "WEBDAV_NAME")
  for var in "${required_vars[@]}"; do
								 
    [[ -z "${!var:-}" ]] && handle_error "Missing required config: $var" "${E_CONFIG_MISSING}"
	  
    if [[ "${var}" =~ ^(CLIENT_ID|CLIENT_SECRET)$ ]] && [[ "${!var}" =~ ^[[:space:]]*$ ]]; then
      handle_error "Invalid $var: cannot be whitespace only" "${E_CONFIG_MISSING}"
    fi
  done

  CONFIG_DIR="${BASE_DIR}/config"
  readonly DATA_DIR="${BASE_DIR}/data"
  readonly ZIPS_DIR="${BASE_DIR}/zips"
  readonly LOG_DIR="${BASE_DIR}/logs"
  readonly MY_CREDS="${CONFIG_DIR}/.creds"
  LOG_FILE="${LOG_DIR}/script_$(date -u '+%Y%m%d').log"
}

#------------------------------------------------------------------------------
# Function: create_and_check_dir
# Purpose:
#   Create directory if it doesn't exist and check permissions.
#------------------------------------------------------------------------------
create_and_check_dir() {
  local dir="$1"
  mkdir -p "${dir}" || handle_error "Failed to create directory ${dir}" "${E_PERMISSIONS}"
  [[ ! -r "${dir}" ]] && handle_error "No read permission for ${dir}" "${E_PERMISSIONS}"
  if [[ "${2:-true}" == "true" && ! -w "${dir}" ]]; then
    handle_error "No write permission for ${dir}" "${E_PERMISSIONS}"
  fi
}

#------------------------------------------------------------------------------
# Function: get_date
# Purpose:
#   Returns the date in the specified format. Supports 'now' and 'yesterday'.
#------------------------------------------------------------------------------
get_date() {
  local format="$1"
  local date_type="${2:-now}"
  local date_result

  if [[ "${date_type}" == "now" ]]; then
    date_result=$(date -u +"${format}") || handle_error "Failed to get current date with format: ${format}" "${E_DATE_ERROR}"
  elif [[ "${date_type}" == "yesterday" ]]; then
    date_result=$(date -u -d "yesterday" +"${format}") || handle_error "Failed to get yesterday's date with format: ${format}" "${E_DATE_ERROR}"
  else
    handle_error "Invalid date type specified: ${date_type}" "${E_DATE_ERROR}"
  fi

  echo "${date_result}"
}

#------------------------------------------------------------------------------
# Function: get_access_token
# Purpose:
#   Retrieve or reuse an access token for API authentication.
#------------------------------------------------------------------------------
get_access_token() {
  local time_now
  time_now=$(date +%s)

  if [[ -s "${MY_CREDS}" ]]; then
    source "${MY_CREDS}"
    [[ "${time_now}" -lt "${expires_at:-0}" ]] && log "INFO" "Using existing valid access token" && return 0
  fi

  log "INFO" "Requesting new access token"
  local auth_result
  auth_result=$(
    curl -s -X POST "${TOKEN_URL}" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password" \
      -d "client_id=${CLIENT_ID}" \
      -d "client_secret=${CLIENT_SECRET}" \
      -d "scope=read write delete"
  )

  local access_token
  access_token=$(jq -r '.access_token' <<<"${auth_result}")
  local expires_in
  expires_in=$(jq -r '.expires_in' <<<"${auth_result}")
  local expires_at=$((time_now + expires_in - 60))

  [[ -z "${access_token}" || -z "${expires_at}" || "${access_token}" == "null" ]] && handle_error "Failed to retrieve valid access token" "${E_TOKEN_ERROR}"

  {
    echo "access_token=${access_token}"
    echo "expires_at=${expires_at}"
  } >"${MY_CREDS}"

  chmod 600 "${MY_CREDS}"
  log "INFO" "New access token obtained."
}

#------------------------------------------------------------------------------
# Function: verify_rclone_config
# Purpose:
#   Verify if rclone is configured properly and check if WEBDAV_NAME is configured.
#------------------------------------------------------------------------------
verify_rclone_config() {
#  rclone config file &>/dev/null || handle_error "rclone configuration is invalid or inaccessible" "${E_RCLONE_CONFIG}"

  if ! rclone listremotes | grep -q "^${WEBDAV_NAME}:$"; then
    log "INFO" "WEBDAV_NAME '${WEBDAV_NAME}' is not configured in rclone, creating configuration..."
    rclone config create "${WEBDAV_NAME}" webdav url=http://${WEBDAV_ADDR} vendor=other || handle_error "Failed to create rclone configuration for ${WEBDAV_NAME}" "${E_RCLONE_CONFIG}"
  else
    log "INFO" "WEBDAV_NAME '${WEBDAV_NAME}' is already configured in rclone"
  fi
}

#------------------------------------------------------------------------------
# Function: check_and_create_zip
# Purpose:
#   Check if a new zip file is needed, then create it if required.
#------------------------------------------------------------------------------
check_and_create_zip() {
  local yesterday
  yesterday=$(get_date '%Y%m%d' 'yesterday')
  local zipname="data_${yesterday}.zip"

  log "INFO" "Checking and creating zip..."

  cd "${DATA_DIR}" || handle_error "Failed to enter directory ${DATA_DIR}"

  local zip_exists=false
  [[ -f "../zips/$zipname" ]] && zip_exists=true || log "INFO" "No existing zip for yesterday found; checking for new data."

  local rclone_output
  rclone_output=$(rclone -v copy "${WEBDAV_NAME}:" "${DATA_DIR}" 2>&1)
  local new_data_detected=false
  ! echo "$rclone_output" | grep -q "There was nothing to transfer" && new_data_detected=true && log "INFO" "New data detected."

  if [[ "$zip_exists" == false ]] || [[ "$new_data_detected" == true ]]; then
    log "INFO" "No existing zip for yesterday or new data detected."

    if [[ -z "$(find ../zips -maxdepth 1 -type f -name "*.zip" | head -n 1)" && -n "$(find DATALOG -type f | head -n 1)" ]]; then
      log "INFO" "Creating full zip."
      zip -r "../zips/$zipname" *.* SETTINGS DATALOG || handle_error "Failed to create full zip."
    elif [[ -d "DATALOG/$yesterday" ]]; then
      log "INFO" "Creating zip for yesterday's data."
      zip -r "../zips/$zipname" *.* SETTINGS "DATALOG/$yesterday" || handle_error "Failed to create yesterday's zip."
    else
      log "INFO" "No new data to zip; skipping zip creation."
      return 1
    fi

    log "INFO" "Zip created successfully."
    return 0
  fi

  log "INFO" "No changes detected; no zip created."
  return 1
}

#------------------------------------------------------------------------------
# Function: upload_and_process
# Purpose:
#   Upload the zip file to the API and request processing.
#------------------------------------------------------------------------------
upload_and_process() {
  log "INFO" "Uploading and processing zip file..."
  get_access_token || handle_error "Failed to get access token"

  source "${MY_CREDS}"
  [[ -z "${access_token:-}" ]] && handle_error "No access token available" "${E_TOKEN_ERROR}"

  local teamsid
  teamsid=$(curl -s -X GET "${API_URL}/me" \
    -H "accept: application/vnd.api+json" \
    -H "authorization: Bearer ${access_token}" | jq -r '.data.current_team_id')

  [[ -z "${teamsid}" || "${teamsid}" == "null" ]] && handle_error "Failed to retrieve team ID"

  log "INFO" "Team ID: ${teamsid}"

  local importid
  importid=$(curl -s -X POST "${API_URL}/teams/${teamsid}/imports" \
    -H "accept: application/vnd.api+json" \
    -H "authorization: Bearer ${access_token}" \
    -d '' | jq -r '.data.attributes.id')

  [[ -z "${importid}" || "${importid}" == "null" ]] && handle_error "Failed to retrieve import ID"

  log "INFO" "Import ID: ${importid}"

  local zipname="data_${yesterday}.zip"
  local file_path="${ZIPS_DIR}/${zipname}"

  local contenthash
  contenthash=$(md5sum "${file_path}" | awk '{print $1}')

  log "INFO" "Uploading zip file..."
  local upload_response
  upload_response=$(curl -s -w "%{http_code}" -X POST "${API_URL}/imports/${importid}/files" \
    -H "accept: application/vnd.api+json" \
    -H "authorization: Bearer ${access_token}" \
    -H "Content-Type: multipart/form-data" \
    -F "name=${zipname}" \
    -F "path=${file_path}" \
    -F "file=@${file_path};type=application/x-zip-compressed" \
    -F "content_hash=${contenthash}")
  http_code=${upload_response: -3}
  response_body=${upload_response::-3}
  [[ $http_code -ge 400 ]] && handle_error "Upload failed with HTTP $http_code: $response_body"

  log "INFO" "Processing uploaded files..."
  local process_response
  process_response=$(curl -s -w "%{http_code}" -X POST "${API_URL}/imports/${importid}/process_files" \
    -H "accept: application/vnd.api+json" \
    -H "authorization: Bearer ${access_token}" \
    -d '')
  http_code=${process_response: -3}
  response_body=${process_response::-3}
  [[ $http_code -ge 400 ]] && handle_error "Process files failed with HTTP $http_code: $response_body"

  log "INFO" "Successfully uploaded and processed data from ${zipname}"
}

#------------------------------------------------------------------------------
# Function: init
# Purpose:
#   Initialize the script: check tools, load config, verify rclone, etc.
#------------------------------------------------------------------------------
init() {
  log "INFO" "Initializing script..."
  check_required_tools || exit $?
  load_configuration || exit $?
  verify_rclone_config || exit $?

  create_and_check_dir "${DATA_DIR}"
  create_and_check_dir "${ZIPS_DIR}"
  create_and_check_dir "${LOG_DIR}"
  create_and_check_dir "${CONFIG_DIR}"

  yesterday=$(get_date '%Y%m%d' 'yesterday')
  current_time=$(get_date '%Y-%m-%d %H:%M:%S UTC' 'now')

  log "INFO" "=== Script Start ==="
  log "INFO" "Script: ${SCRIPT_NAME} (v${SCRIPT_VERSION})"
  log "INFO" "User: ${SCRIPT_AUTHOR}"
  log "INFO" "Start Time: ${current_time}"
  log "INFO" "Yesterday's date: ${yesterday}"
}

#------------------------------------------------------------------------------
# Function: cleanup
# Purpose:
#   Cleanup actions that run on script exit (trap).
#------------------------------------------------------------------------------
cleanup() {
  local exit_code=$?
  log "INFO" "=== Script End ==="
  log "INFO" "End Time: $(get_date '%Y-%m-%d %H:%M:%S UTC' 'now')"
  log "INFO" "Exit Code: ${exit_code}"
  exit "${exit_code}"
}

# Trap cleanup on exit
trap cleanup EXIT

# Execute main logic
init
if check_and_create_zip; then
  upload_and_process
fi
