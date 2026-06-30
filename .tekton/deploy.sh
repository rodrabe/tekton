#!/usr/bin/env bash
# deploy.sh — create and trigger the IBM Cloud Tekton pipeline using ibmcloud CLI
#
# Prerequisites:
#   ibmcloud CLI  https://cloud.ibm.com/docs/cli
#   ibmcloud plugin install continuous-delivery
#   ibmcloud plugin install dev  (optional – for local tekton testing)
#
# Required environment variables:
#   IBMCLOUD_API_KEY   — IBM Cloud API key
#   IBMCLOUD_REGION    — e.g. us-south
#   RESOURCE_GROUP     — e.g. default
#   REPO_URL           — HTTPS URL of this git repository
#
# Usage:
#   chmod +x .tekton/deploy.sh
#   export IBMCLOUD_API_KEY=...  IBMCLOUD_REGION=us-south  RESOURCE_GROUP=default  REPO_URL=https://...
#   ./.tekton/deploy.sh

set -euo pipefail

: "${IBMCLOUD_API_KEY:?Must set IBMCLOUD_API_KEY}"
: "${IBMCLOUD_REGION:?Must set IBMCLOUD_REGION}"
: "${RESOURCE_GROUP:?Must set RESOURCE_GROUP}"
: "${REPO_URL:?Must set REPO_URL}"

TOOLCHAIN_NAME="${TOOLCHAIN_NAME:-log-message-toolchain}"
PIPELINE_NAME="${PIPELINE_NAME:-log-message-pipeline}"

# ---------------------------------------------------------------------------
# 1. Authenticate
# ---------------------------------------------------------------------------
echo "==> Logging in to IBM Cloud..."
ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -r "${IBMCLOUD_REGION}" -g "${RESOURCE_GROUP}" -q

# ---------------------------------------------------------------------------
# 2. Create (or locate) the Continuous Delivery toolchain
# ---------------------------------------------------------------------------
echo "==> Looking for existing toolchain '${TOOLCHAIN_NAME}'..."
TOOLCHAIN_ID=$(ibmcloud dev toolchain-get "${TOOLCHAIN_NAME}" --output json 2>/dev/null \
  | grep '"toolchain_id"' | head -1 | awk -F'"' '{print $4}' || true)

if [[ -z "${TOOLCHAIN_ID}" ]]; then
  echo "==> Creating toolchain from .tekton/toolchain.yaml ..."
  ibmcloud dev toolchain-create \
    --file ".tekton/toolchain.yaml" \
    --env "REPO_URL=${REPO_URL}" \
    --name "${TOOLCHAIN_NAME}"

  TOOLCHAIN_ID=$(ibmcloud dev toolchain-get "${TOOLCHAIN_NAME}" --output json \
    | grep '"toolchain_id"' | head -1 | awk -F'"' '{print $4}')
fi
echo "    Toolchain ID: ${TOOLCHAIN_ID}"

# ---------------------------------------------------------------------------
# 3. Get the Tekton pipeline ID
# ---------------------------------------------------------------------------
echo "==> Fetching Tekton pipeline '${PIPELINE_NAME}'..."
PIPELINE_ID=$(ibmcloud dev tekton-pipeline-get "${PIPELINE_NAME}" \
  --toolchain-id "${TOOLCHAIN_ID}" --output json \
  | grep '"id"' | head -1 | awk -F'"' '{print $4}')
echo "    Pipeline ID: ${PIPELINE_ID}"

# ---------------------------------------------------------------------------
# 4. Get the webhook URL for the generic trigger
# ---------------------------------------------------------------------------
echo "==> Fetching webhook URL for trigger 'webhook-trigger'..."
WEBHOOK_URL=$(ibmcloud dev tekton-pipeline trigger-url \
  --pipeline-id "${PIPELINE_ID}" \
  --trigger-name webhook-trigger \
  --output json \
  | grep '"webhook_url"' | head -1 | awk -F'"' '{print $4}')
echo "    Webhook URL: ${WEBHOOK_URL}"

# ---------------------------------------------------------------------------
# 5. Fire the webhook — override MESSAGE env var or use the default
# ---------------------------------------------------------------------------
MESSAGE="${MESSAGE:-Hello from IBM Cloud webhook trigger}"
echo "==> Sending webhook with message: '${MESSAGE}'"
curl -sS -X POST "${WEBHOOK_URL}" \
  -H "Content-Type: application/json" \
  -d "{\"message\": \"${MESSAGE}\"}"
echo ""

echo "==> Done! Check the PipelineRun logs in the IBM Cloud Console:"
echo "    https://cloud.ibm.com/devops/pipelines/tekton/${PIPELINE_ID}?env_id=ibm:yp:${IBMCLOUD_REGION}"
