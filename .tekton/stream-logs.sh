#!/usr/bin/env bash
# stream-logs.sh — poll IBM Cloud Tekton pipeline run logs in near-real-time.
#
# IBM Cloud Tekton does not support HTTP log streaming (text/event-stream).
# This script polls each step's log endpoint every POLL_INTERVAL seconds,
# printing only newly-appended lines since the last poll.
#
# Usage:
#   chmod +x .tekton/stream-logs.sh
#   export IBMCLOUD_API_KEY=...  IBMCLOUD_REGION=us-south
#   ./.tekton/stream-logs.sh <PIPELINE_ID> <RUN_ID>
#
# Or wait for the latest run automatically:
#   ./.tekton/stream-logs.sh <PIPELINE_ID>

set -euo pipefail

: "${IBMCLOUD_API_KEY:?Must set IBMCLOUD_API_KEY}"
: "${IBMCLOUD_REGION:?Must set IBMCLOUD_REGION}"

PIPELINE_ID="${1:?Usage: $0 <PIPELINE_ID> [RUN_ID]}"
RUN_ID="${2:-}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
PIPELINE_API="https://api.${IBMCLOUD_REGION}.devops.dev.cloud.ibm.com/pipeline/v2"

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
echo "[stream-logs] Obtaining IAM token..."
IAM_TOKEN=$(ibmcloud iam oauth-tokens --output json 2>/dev/null | jq -r '.iam_token')

api() { curl -sS "$1" -H "Authorization: ${IAM_TOKEN}" -H "Accept: application/json"; }

# ---------------------------------------------------------------------------
# If no RUN_ID given, wait for the latest pending/running run
# ---------------------------------------------------------------------------
if [[ -z "${RUN_ID}" ]]; then
  echo "[stream-logs] Waiting for a running pipeline run..."
  while true; do
    RUN_ID=$(api "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/pipeline_runs" \
      | jq -r '[.pipeline_runs[] | select(.status == "running" or .status == "pending")] | sort_by(.created_at) | last | .id // empty')
    [[ -n "${RUN_ID}" ]] && break
    sleep "${POLL_INTERVAL}"
  done
fi

echo "[stream-logs] Pipeline: ${PIPELINE_ID}"
echo "[stream-logs] Run:      ${RUN_ID}"
echo "[stream-logs] Console:  https://dev.console.test.cloud.ibm.com/devops/pipelines/tekton/${PIPELINE_ID}/runs/${RUN_ID}?env_id=ibm:ys1:us-south"
echo "[stream-logs] Polling every ${POLL_INTERVAL}s..."
echo "---"

# ---------------------------------------------------------------------------
# Poll loop — track byte offset per log ID to print only new content
# ---------------------------------------------------------------------------
declare -A LOG_OFFSET   # log_id -> bytes already printed
declare -A LOG_SEEN     # log_id -> 1 once we have printed its header

while true; do
  # Refresh IAM token every ~45 min (token TTL is 60 min)
  TOKEN_AGE=$(( $(date +%s) - ${TOKEN_TS:-0} ))
  if (( TOKEN_AGE > 2700 )); then
    IAM_TOKEN=$(ibmcloud iam oauth-tokens --output json 2>/dev/null | jq -r '.iam_token')
    TOKEN_TS=$(date +%s)
  fi

  # Get current run status and log list
  RUN_JSON=$(api "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/pipeline_runs/${RUN_ID}")
  STATUS=$(echo "${RUN_JSON}" | jq -r '.status')

  LOGS_JSON=$(api "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/pipeline_runs/${RUN_ID}/logs" 2>/dev/null || echo '{"logs":[]}')

  while IFS= read -r log_entry; do
    LOG_ID=$(echo "${log_entry}"   | jq -r '.id')
    LOG_NAME=$(echo "${log_entry}" | jq -r '.name')
    TASK=$(echo "${LOG_NAME}" | sed 's|.*/\([^/]*\)-pod/.*|\1|')
    STEP=$(echo "${LOG_NAME}" | sed 's|.*/||')

    # Print a header the first time we see this log
    if [[ -z "${LOG_SEEN[$LOG_ID]:-}" ]]; then
      echo ""
      echo "=== task: ${TASK}  step: ${STEP} ==="
      LOG_SEEN[$LOG_ID]=1
      LOG_OFFSET[$LOG_ID]=0
    fi

    # Fetch the log snapshot, skip already-printed bytes
    DATA=$(api "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/pipeline_runs/${RUN_ID}/logs/${LOG_ID}" \
      | jq -r '.data // ""')

    OFFSET=${LOG_OFFSET[$LOG_ID]:-0}
    NEW_CONTENT="${DATA:${OFFSET}}"
    if [[ -n "${NEW_CONTENT}" ]]; then
      printf '%s' "${NEW_CONTENT}"
      LOG_OFFSET[$LOG_ID]=${#DATA}
    fi
  done < <(echo "${LOGS_JSON}" | jq -c '.logs[]')

  # Exit when run is terminal
  case "${STATUS}" in
    succeeded)
      echo ""
      echo "--- [stream-logs] Run ${STATUS}. ---"
      exit 0
      ;;
    failed|error|cancelled)
      echo ""
      echo "--- [stream-logs] Run ${STATUS}. ---"
      exit 1
      ;;
  esac

  sleep "${POLL_INTERVAL}"
done
