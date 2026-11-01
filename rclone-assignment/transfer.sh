#!/usr/bin/env bash
# ==============================================================================
# Script Name: transfer.sh
# Description: Reusable, configuration-free rclone file transfer & sync script.
# Usage:       ./transfer.sh <copy|sync> <source> <destination> [extra_flags]
# ==============================================================================

set -euo pipefail

# Enforce configuration-free execution by default
export RCLONE_CONFIG="${RCLONE_CONFIG:-/dev/null}"

# Tunable operational parameters via environment variables
LOG_FILE="${RCLONE_LOG_FILE:-./transfer.log}"
TRANSFERS="${RCLONE_TRANSFERS:-4}"
CHECKERS="${RCLONE_CHECKERS:-8}"
RETRIES="${RCLONE_RETRIES:-3}"
LOW_LEVEL_RETRIES="${RCLONE_LOW_LEVEL_RETRIES:-10}"
BWLIMIT="${RCLONE_BWLIMIT:-0}"

usage() {
    cat <<USAGE
Usage: $0 <copy|sync> <source> <destination> [extra_rclone_flags...]

Examples:
  ./transfer.sh copy ./storage_local_a ./storage_local_b
  ./transfer.sh copy ./storage_local_a :s3:tpstreams-raw
  ./transfer.sh sync ./storage_local_a :s3:tpstreams-raw --dry-run
USAGE
    exit 2
}

if [[ $# -lt 3 ]]; then
    echo "[ERROR] Missing required arguments." >&2
    usage
fi

OPERATION="$1"
SOURCE="$2"
DESTINATION="$3"
shift 3
EXTRA_FLAGS=("$@")

if [[ "$OPERATION" != "copy" && "$OPERATION" != "sync" ]]; then
    echo "[ERROR] Unsupported operation '$OPERATION'. Allowed: 'copy' or 'sync'." >&2
    usage
fi

# Validate S3 environment credentials when on-the-fly ':s3:' syntax is used
if [[ "$SOURCE" == :s3:* || "$DESTINATION" == :s3:* ]]; then
    if [[ -z "${RCLONE_S3_ENDPOINT:-}" || -z "${RCLONE_S3_ACCESS_KEY_ID:-}" || -z "${RCLONE_S3_SECRET_ACCESS_KEY:-}" ]]; then
        echo "[ERROR] ':s3:' path detected, but RCLONE_S3_ENDPOINT, RCLONE_S3_ACCESS_KEY_ID, or RCLONE_S3_SECRET_ACCESS_KEY is missing." >&2
        exit 3
    fi
    export RCLONE_S3_PROVIDER="${RCLONE_S3_PROVIDER:-Minio}"
    export RCLONE_S3_ENV_AUTH="false"
fi

START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "------------------------------------------------------------------" | tee -a "$LOG_FILE"
echo "[$START_TIME] [INFO] Starting rclone $OPERATION: '$SOURCE' -> '$DESTINATION'" | tee -a "$LOG_FILE"

set +e
rclone "$OPERATION" "$SOURCE" "$DESTINATION" \
    --config "$RCLONE_CONFIG" \
    --transfers "$TRANSFERS" \
    --checkers "$CHECKERS" \
    --retries "$RETRIES" \
    --low-level-retries "$LOW_LEVEL_RETRIES" \
    --bwlimit "$BWLIMIT" \
    --progress \
    --stats 5s \
    --log-file "$LOG_FILE" \
    --log-level INFO \
    "${EXTRA_FLAGS[@]}"
EXIT_CODE=$?
set -e

END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "[$END_TIME] [SUCCESS] rclone $OPERATION completed successfully." | tee -a "$LOG_FILE"
    exit 0
else
    echo "[$END_TIME] [ERROR] rclone $OPERATION failed with exit code $EXIT_CODE. Inspect $LOG_FILE." | tee -a "$LOG_FILE" >&2
    exit "$EXIT_CODE"
fi
