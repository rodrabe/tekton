#!/usr/bin/env bash
# deploy.sh — create and trigger the IBM Cloud Tekton pipeline
#
# Prerequisites:
#   ibmcloud CLI  https://cloud.ibm.com/docs/cli
#   ibmcloud plugin install dev
#   curl, jq
#
# Required environment variables:
#   IBMCLOUD_API_KEY    — IBM Cloud API key
#   IBMCLOUD_REGION     — e.g. us-south
#   RESOURCE_GROUP      — exact resource group name (case-sensitive)
#   REPO_URL            — HTTPS URL of this git repository
#
# Optional environment variables:
#   TOOLCHAIN_NAME      — defaults to pipeline-image-builder-toolchain
#   PIPELINE_NAME       — defaults to pipeline-image-builder
#   WEBHOOK_SECRET      — token sent in X-Webhook-Token header (defaults to "changeme")
#   REPO_BRANCH         — git branch for the pipeline definition (defaults to "main")
#   TEKTON_PATH         — path inside repo containing Tekton YAML (defaults to ".tekton")
#   COS_REGION          — COS region (defaults to IBMCLOUD_REGION)
#   PKR_REGISTRY        — registry for the packer HCL (e.g. stg.icr.io/rodrabe)
#   PKR_IMAGE_NAME      — base image name (timestamp appended automatically, default: ibmcloud-cli)
#   PKR_IMAGE_TAG       — image tag for the packer HCL (default: latest)
#   COS_BUCKET          — COS bucket name (defaults to the timestamped image name)
#
# One-time manual prerequisite (cannot be scripted):
#   The git repository must be connected to the toolchain as a tool integration via
#   the IBM Cloud Console before this script can register a pipeline definition.
#   Steps:
#     1. Open: https://cloud.ibm.com/devops/toolchains/<TOOLCHAIN_ID>
#     2. Click "Add tool" → choose your git provider (GitHub, GitHub Enterprise, etc.)
#     3. Authorise and link the repository
#   On subsequent runs the script finds the existing integration automatically.
#
# Usage:
#   chmod +x .tekton/deploy.sh
#   export IBMCLOUD_API_KEY=...  IBMCLOUD_REGION=us-south  RESOURCE_GROUP=Default  REPO_URL=https://...
#   ./.tekton/deploy.sh

set -euo pipefail

: "${IBMCLOUD_API_KEY:?Must set IBMCLOUD_API_KEY}"
: "${IBMCLOUD_REGION:?Must set IBMCLOUD_REGION}"
: "${RESOURCE_GROUP:?Must set RESOURCE_GROUP}"
: "${REPO_URL:?Must set REPO_URL}"

TOOLCHAIN_NAME="${TOOLCHAIN_NAME:-pipeline-image-builder-toolchain}"
PIPELINE_NAME="${PIPELINE_NAME:-pipeline-image-builder}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-changeme}"
REPO_BRANCH="${REPO_BRANCH:-main}"
TEKTON_PATH="${TEKTON_PATH:-.tekton}"
COS_REGION="${COS_REGION:-${IBMCLOUD_REGION}}"
PKR_REGISTRY="${PKR_REGISTRY:-}"
# Append a UTC timestamp to the image name so each build produces a unique image.
# Override PKR_IMAGE_NAME to use a fixed name (e.g. for idempotent rebuilds).
PKR_TIMESTAMP="$(date -u +%Y%m%d%H%M%S)"
PKR_IMAGE_NAME="${PKR_IMAGE_NAME:-ibmcloud-cli}-${PKR_TIMESTAMP}"

# Generate a throwaway ed25519 SSH key pair for this packer run.
# The public key is injected into the HCL template; the private key is
# base64-encoded and sent to the pipeline so packer can SSH into the VSI.
PKR_SSH_KEY_DIR=$(mktemp -d)
ssh-keygen -t ed25519 -N "" -f "${PKR_SSH_KEY_DIR}/packer_id_rsa" -C "packer-build-${PKR_TIMESTAMP}" -q
PKR_KEY_B64=$(base64 < "${PKR_SSH_KEY_DIR}/packer_id_rsa" | tr -d '\n')
PKR_PUB_KEY=$(cat "${PKR_SSH_KEY_DIR}/packer_id_rsa.pub")
rm -rf "${PKR_SSH_KEY_DIR}"
echo "    SSH key pair generated for this build."
# Use the image name as the COS bucket name (override with COS_BUCKET if needed).
COS_BUCKET="${COS_BUCKET:-${PKR_IMAGE_NAME}}"
PKR_IMAGE_TAG="${PKR_IMAGE_TAG:-latest}"
PKR_SUBNET_ID="${PKR_SUBNET_ID:-0726-a80a8b2f-4823-4083-b844-83b15d0fd3c6}"

TOOLCHAIN_API="https://api.${IBMCLOUD_REGION}.devops.dev.cloud.ibm.com/toolchain/v2"
PIPELINE_API="https://api.${IBMCLOUD_REGION}.devops.dev.cloud.ibm.com/pipeline/v2"
# Staging IBM Cloud and COS config passed into the store-to-cos task
IBMCLOUD_API_ENDPOINT="${IBMCLOUD_API_ENDPOINT:-https://test.cloud.ibm.com}"
COS_API_ENDPOINT="${COS_API_ENDPOINT:-https://s3.us-west.cloud-object-storage.test.appdomain.cloud}"
COS_INSTANCE_CRN="${COS_INSTANCE_CRN:-crn:v1:staging:public:cloud-object-storage:global:a/af6443f619a949c9919c1eb1625d6cc5:6e1a5f52-058f-4452-bad2-d2ccc1e741b0::}"

# ---------------------------------------------------------------------------
# 1. Authenticate
# ---------------------------------------------------------------------------
echo "==> Logging in to IBM Cloud..."
ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -r "${IBMCLOUD_REGION}" -a "${IBMCLOUD_API_ENDPOINT}" -q

echo "==> Targeting resource group '${RESOURCE_GROUP}'..."
ibmcloud target -g "${RESOURCE_GROUP}"

echo "==> Obtaining IAM token..."
IAM_TOKEN=$(ibmcloud iam oauth-tokens --output json 2>/dev/null | jq -r '.iam_token')

# ---------------------------------------------------------------------------
# 2. Resolve resource group ID
# ---------------------------------------------------------------------------
echo "==> Resolving resource group ID for '${RESOURCE_GROUP}'..."
RESOURCE_GROUP_ID=$(ibmcloud resource group "${RESOURCE_GROUP}" --output json \
  | jq -r '.[0].id // .id')
echo "    Resource Group ID: ${RESOURCE_GROUP_ID}"

# ---------------------------------------------------------------------------
# 2b. Generate ibmcloud.pkr.hcl (needs RESOURCE_GROUP_ID from step 2)
# ---------------------------------------------------------------------------
echo "==> Generating ibmcloud.pkr.hcl..."
# Quote the heredoc delimiter (<<'PKHCL') to prevent bash from expanding ${}
# inside the Packer HCL template — variables are substituted via sed below.
PKR_HCL=$(cat <<'PKHCL'
packer {
  required_plugins {
    ibmcloud = {
      source  = "github.com/IBM/ibmcloud"
      version = ">= 3.6.0"
    }
  }
}

variable "ibmcloud_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "region" {
  type    = string
  default = "TMPL_REGION"
}

variable "resource_group_id" {
  type    = string
  default = "TMPL_RESOURCE_GROUP_ID"
}

variable "image_name" {
  type    = string
  default = "TMPL_IMAGE_NAME"
}

variable "image_tag" {
  type    = string
  default = "TMPL_IMAGE_TAG"
}

variable "registry" {
  type    = string
  default = "TMPL_REGISTRY"
}

locals {
  full_image = var.image_name
}

variable "subnet_id" {
  type    = string
  default = "TMPL_SUBNET_ID"
}

source "ibmcloud-vpc" "base" {
  api_key           = var.ibmcloud_api_key
  region            = var.region
  resource_group_id = var.resource_group_id
  subnet_id         = var.subnet_id

  iam_url           = "https://iam.test.cloud.ibm.com"
  vpc_endpoint_url  = "https://us-south-stage01.iaasdev.cloud.ibm.com/v1"
  rc_endpoint_url   = "https://resource-controller.test.cloud.ibm.com"

  vsi_base_image_name = "ibm-ubuntu-22-04-5-minimal-amd64-16"
  vsi_profile         = "bx2-2x8"
  vsi_interface       = "public"
  image_name          = local.full_image

  communicator         = "ssh"
  ssh_username         = "ubuntu"
  ssh_timeout          = "15m"
  ssh_key_type         = "ed25519"
  timeout              = "30m"
}

build {
  sources = ["source.ibmcloud-vpc.base"]

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "apt-get update -y -o APT::Update::Post-Invoke-Success:='true' 2>&1 || true",
      "apt-get install -y software-properties-common",
      "add-apt-repository universe -y",
      "apt-get update -y -o APT::Update::Post-Invoke-Success:='true' 2>&1 || true",
      "apt-get install -y curl jq ca-certificates",
      "curl -fsSL https://clis.cloud.ibm.com/install/linux | bash",
      "ibmcloud plugin install dev -f",
      "ibmcloud version",
      "curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin v1.18.1",
      "syft / -o cyclonedx-json=/tmp/sbom.json",
      "chmod 644 /tmp/sbom.json",
    ]
  }

  # Copy the SBOM out of the VM to the shared Tekton workspace
  provisioner "file" {
    source      = "/tmp/sbom.json"
    destination = "/workspace/shared/sbom.json"
    direction   = "download"
  }

  # Clean up syft binary and SBOM from the VM image after capture
  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "rm -f /usr/local/bin/syft /tmp/sbom.json",
    ]
  }
}
PKHCL
)

# Now substitute the template placeholders with the real values
PKR_HCL=$(printf '%s' "${PKR_HCL}" \
  | sed \
      -e "s|TMPL_REGION|${IBMCLOUD_REGION}|g" \
      -e "s|TMPL_RESOURCE_GROUP_ID|${RESOURCE_GROUP_ID}|g" \
      -e "s|TMPL_IMAGE_NAME|${PKR_IMAGE_NAME}|g" \
      -e "s|TMPL_IMAGE_TAG|${PKR_IMAGE_TAG}|g" \
      -e "s|TMPL_REGISTRY|${PKR_REGISTRY}|g" \
      -e "s|TMPL_SUBNET_ID|${PKR_SUBNET_ID}|g")

PKR_HCL_B64=$(printf '%s' "${PKR_HCL}" | base64 | tr -d '\n')
echo "    HCL generated (${#PKR_HCL} bytes), encoded."

# ---------------------------------------------------------------------------
# 3. Find or create the toolchain
# ---------------------------------------------------------------------------
echo "==> Looking for existing toolchain '${TOOLCHAIN_NAME}'..."
TOOLCHAIN_ID=$(curl -sS -X GET \
  "${TOOLCHAIN_API}/toolchains?resource_group_id=${RESOURCE_GROUP_ID}&name=${TOOLCHAIN_NAME}" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Accept: application/json" \
  | jq -r '.toolchains[0].id // empty')

if [[ -z "${TOOLCHAIN_ID}" ]]; then
  echo "==> Creating toolchain '${TOOLCHAIN_NAME}'..."
  TOOLCHAIN_ID=$(curl -sS -X POST \
    "${TOOLCHAIN_API}/toolchains" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{
      \"name\": \"${TOOLCHAIN_NAME}\",
      \"description\": \"Tekton pipeline that logs a string parameter via a webhook trigger.\",
      \"resource_group_id\": \"${RESOURCE_GROUP_ID}\"
    }" \
    | jq -r '.id')
  echo "    Created toolchain ID: ${TOOLCHAIN_ID}"
else
  echo "    Found existing toolchain ID: ${TOOLCHAIN_ID}"
fi

# ---------------------------------------------------------------------------
# 4. Find or create the pipeline tool inside the toolchain
# ---------------------------------------------------------------------------
echo "==> Looking for existing pipeline tool '${PIPELINE_NAME}'..."
PIPELINE_ID=$(curl -sS -X GET \
  "${TOOLCHAIN_API}/toolchains/${TOOLCHAIN_ID}/tools" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Accept: application/json" \
  | jq -r --arg name "${PIPELINE_NAME}" \
    '.tools[] | select(.name == $name and .tool_type_id == "pipeline") | .id // empty' \
  | head -1)

if [[ -z "${PIPELINE_ID}" ]]; then
  echo "==> Adding pipeline tool '${PIPELINE_NAME}' to toolchain..."
  PIPELINE_ID=$(curl -sS -X POST \
    "${TOOLCHAIN_API}/toolchains/${TOOLCHAIN_ID}/tools" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{
      \"tool_type_id\": \"pipeline\",
      \"name\": \"${PIPELINE_NAME}\",
      \"parameters\": {
        \"type\": \"tekton\",
        \"name\": \"${PIPELINE_NAME}\",
        \"ui_pipeline\": true
      }
    }" \
    | jq -r '.id')
  echo "    Created pipeline tool ID: ${PIPELINE_ID}"

  echo "==> Initialising Tekton pipeline engine..."
  curl -sS -X POST \
    "${PIPELINE_API}/tekton_pipelines" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{\"id\": \"${PIPELINE_ID}\"}" \
    | jq -r '"    Status: \(.status)"'
else
  echo "    Found existing pipeline tool ID: ${PIPELINE_ID}"
fi

# ---------------------------------------------------------------------------
# 4b. Set the IBM Cloud API key as a secure pipeline environment property.
#     POST creates it; if it already exists (409 conflict) fall back to PUT.
# ---------------------------------------------------------------------------
echo "==> Setting secure pipeline property 'ibmcloud-api-key'..."
PROP_PAYLOAD="{\"name\":\"ibmcloud-api-key\",\"value\":\"${IBMCLOUD_API_KEY}\",\"type\":\"secure\"}"
PROP_RESP=$(curl -sS -w "\n%{http_code}" -X POST \
  "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/properties" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d "${PROP_PAYLOAD}")
PROP_STATUS=$(echo "${PROP_RESP}" | tail -1)
PROP_BODY=$(echo "${PROP_RESP}" | head -1)
if [[ "${PROP_STATUS}" == "409" ]]; then
  echo "    Property exists — updating via PUT..."
  curl -sS -X PUT \
    "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/properties/ibmcloud-api-key" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "${PROP_PAYLOAD}" | jq -r '"    Updated: \(.name) (\(.type))"'
elif [[ "${PROP_STATUS}" == "201" || "${PROP_STATUS}" == "200" ]]; then
  echo "    Created: ibmcloud-api-key (secure)"
else
  echo "    WARNING: Unexpected status ${PROP_STATUS} setting pipeline property."
  echo "    Raw response: ${PROP_BODY}"
  # Retry with type=text in case the staging API rejects 'secure'
  echo "    Retrying with type=text..."
  PROP_PAYLOAD_TEXT="{\"name\":\"ibmcloud-api-key\",\"value\":\"${IBMCLOUD_API_KEY}\",\"type\":\"text\"}"
  RETRY_RESP=$(curl -sS -w "\n%{http_code}" -X POST \
    "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/properties" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "${PROP_PAYLOAD_TEXT}")
  RETRY_STATUS=$(echo "${RETRY_RESP}" | tail -1)
  RETRY_BODY=$(echo "${RETRY_RESP}" | head -1)
  echo "    Retry status: ${RETRY_STATUS}"
  [[ -n "${RETRY_BODY}" ]] && echo "    Retry response: ${RETRY_BODY}"
fi

# ---------------------------------------------------------------------------
# 4c. Assign the IBM Managed worker to the pipeline
#     "public" is the worker ID for the IBM Managed shared infrastructure.
#     This is required — without a worker the pipeline returns 400 on webhook.
# ---------------------------------------------------------------------------
echo "==> Assigning IBM Managed worker to pipeline..."
curl -sS -X PATCH \
  "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"worker": {"id": "public"}}' \
  | jq -r '"    Worker: \(.worker.id) (\(.worker.type // "managed"))"'

# ---------------------------------------------------------------------------
# 5. Find or create the pipeline definition (links pipeline to git source)
#
# NOTE: The pipeline definition requires the repository to be connected as a
#       tool integration in the toolchain. This OAuth/PAT authorisation cannot
#       be done via the REST API — it must be done once in the IBM Cloud Console.
# ---------------------------------------------------------------------------
echo "==> Resolving git tool integration for '${REPO_URL}'..."
REPO_TOOL_ID=$(curl -sS -X GET \
  "${TOOLCHAIN_API}/toolchains/${TOOLCHAIN_ID}/tools" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Accept: application/json" \
  | jq -r --arg url "${REPO_URL%.git}" \
    '.tools[] | select(
      (.tool_type_id | test("git|github|gitlab|hostedgit|bitbucket"; "i")) and
      (
        ((.parameters.repo_url        // "") | rtrimstr(".git")) == $url or
        ((.parameters.source_repo_url // "") | rtrimstr(".git")) == $url
      )
    ) | .id // empty' \
  | head -1)

if [[ -z "${REPO_TOOL_ID}" ]]; then
  echo ""
  echo "=========================================================="
  echo "  ACTION REQUIRED: Connect the git repository"
  echo "=========================================================="
  echo "  The pipeline definition requires the repository to be"
  echo "  added as a tool integration in the toolchain."
  echo ""
  echo "  1. Open the toolchain in the IBM Cloud Console:"
  echo "     https://test.cloud.ibm.com/devops/toolchains/${TOOLCHAIN_ID}?env_id=ibm:yp:${IBMCLOUD_REGION}"
  echo ""
  echo "  2. Click 'Add tool' → select your git provider"
  echo "     (GitHub, GitHub Enterprise, GitLab, etc.)"
  echo ""
  echo "  3. Authorise and link: ${REPO_URL}"
  echo ""
  echo "  4. Re-run this script."
  echo "=========================================================="
  exit 1
fi
echo "    Repo tool ID: ${REPO_TOOL_ID}"

echo "==> Checking for existing pipeline definition (${REPO_URL} @ ${REPO_BRANCH} ${TEKTON_PATH})..."
DEFINITION_ID=$(curl -sS -X GET \
  "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/definitions" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Accept: application/json" \
  | jq -r --arg url "${REPO_URL}" --arg branch "${REPO_BRANCH}" --arg path "${TEKTON_PATH}" \
    '.definitions[] | select(
      (.source.properties.url   == $url   or (.source.properties.url   | rtrimstr(".git")) == ($url | rtrimstr(".git"))) and
      .source.properties.branch == $branch and
      .source.properties.path   == $path
    ) | .id' \
  | head -1)

if [[ -n "${DEFINITION_ID}" ]]; then
  echo "    Found existing definition: ${DEFINITION_ID} — skipping create."
else
  echo "==> Creating pipeline definition..."
  echo "    URL:    ${REPO_URL}"
  echo "    Branch: ${REPO_BRANCH}"
  echo "    Path:   ${TEKTON_PATH}"
  DEFINITION_RESP=$(curl -sS -X POST \
    "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/definitions" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{
      \"source\": {
        \"type\": \"git\",
        \"properties\": {
          \"url\": \"${REPO_URL}\",
          \"branch\": \"${REPO_BRANCH}\",
          \"path\": \"${TEKTON_PATH}\",
          \"tool\": {\"id\": \"${REPO_TOOL_ID}\"}
        }
      }
    }")
  echo "    API response: ${DEFINITION_RESP}"
  DEFINITION_ID=$(echo "${DEFINITION_RESP}" | jq -r '.id // empty')
  if [[ -z "${DEFINITION_ID}" ]]; then
    echo "ERROR: Failed to create pipeline definition."
    echo "       Check that REPO_URL points to the tekton sub-repo and the"
    echo "       git tool integration is connected in the toolchain."
    exit 1
  fi
  echo "    Definition ID: ${DEFINITION_ID}"
fi

# Give IBM Cloud time to read the YAML from git before firing the webhook.
# The staging API does not expose a definition status field so we wait a
# fixed interval rather than polling.
echo "==> Waiting 15s for IBM Cloud to read the pipeline definition from git..."
sleep 15

# ---------------------------------------------------------------------------
# 6. Find or create the generic webhook trigger
# ---------------------------------------------------------------------------
DESIRED_LISTENER="pipeline-image-builder-listener"

echo "==> Deleting existing 'webhook-trigger' (ensures secret algorithm is always current)..."
EXISTING_TRIGGER_ID=$(curl -sS -X GET \
  "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/triggers" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Accept: application/json" \
  | jq -r '.triggers[] | select(.name == "webhook-trigger") | .id // empty' \
  | head -1)
if [[ -n "${EXISTING_TRIGGER_ID}" ]]; then
  curl -sS -X DELETE \
    "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/triggers/${EXISTING_TRIGGER_ID}" \
    -H "Authorization: ${IAM_TOKEN}" > /dev/null
  echo "    Deleted trigger: ${EXISTING_TRIGGER_ID}"
fi

echo "==> Creating generic webhook trigger (sha256)..."
TRIGGER_RAW=$(curl -sS -X POST \
  "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/triggers" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d "{
    \"type\": \"generic\",
    \"name\": \"webhook-trigger\",
    \"event_listener\": \"${DESIRED_LISTENER}\",
    \"enabled\": true,
    \"secret\": {
      \"type\": \"token_matches\",
      \"source\": \"header\",
      \"key_name\": \"X-Webhook-Token\",
      \"algorithm\": \"plain\",
      \"value\": \"${WEBHOOK_SECRET}\"
    }
  }" \
  | jq -r '{id, webhook_url, event_listener} | @base64')
echo "    Created trigger."

TRIGGER="${TRIGGER_RAW}"

TRIGGER_ID=$(echo "${TRIGGER}" | base64 -d | jq -r '.id')
WEBHOOK_URL=$(echo "${TRIGGER}" | base64 -d | jq -r '.webhook_url')
echo "    Trigger ID:  ${TRIGGER_ID}"
echo "    Webhook URL: ${WEBHOOK_URL}"

# ---------------------------------------------------------------------------
# 7. Fire the webhook
# ---------------------------------------------------------------------------
echo "==> Sending webhook..."
echo "    Image name:  ${PKR_IMAGE_NAME}"
echo "    COS bucket:  ${COS_BUCKET}"
echo "    IBM Cloud:   ${IBMCLOUD_API_ENDPOINT}"
echo "    COS endpoint:${COS_API_ENDPOINT}"
echo "    COS CRN:     ${COS_INSTANCE_CRN}"
WEBHOOK_BODY=$(jq -n \
  --arg image_name           "${PKR_IMAGE_NAME}" \
  --arg cos_bucket           "${COS_BUCKET}" \
  --arg cos_region           "${COS_REGION}" \
  --arg cos_instance_crn     "${COS_INSTANCE_CRN}" \
  --arg ibmcloud_api_endpoint "${IBMCLOUD_API_ENDPOINT}" \
  --arg cos_api_endpoint     "${COS_API_ENDPOINT}" \
  --arg hcl                  "${PKR_HCL_B64}" \
  --arg key                  "${PKR_KEY_B64}" \
  '{
    "image_name":            $image_name,
    "cos_bucket":            $cos_bucket,
    "cos_region":            $cos_region,
    "cos_instance_crn":      $cos_instance_crn,
    "ibmcloud_api_endpoint": $ibmcloud_api_endpoint,
    "cos_api_endpoint":      $cos_api_endpoint,
    "packer_hcl_b64":        $hcl,
    "packer_key_b64":        $key
  }')
# Brief pause so IBM Cloud can finish registering the trigger before we fire
sleep 3

RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "${WEBHOOK_URL}" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Token: ${WEBHOOK_SECRET}" \
  -d "${WEBHOOK_BODY}")
HTTP_STATUS=$(echo "${RESPONSE}" | tail -1)
RESP_BODY=$(echo "${RESPONSE}" | head -1)
echo "    HTTP status: ${HTTP_STATUS}"
[[ -n "${RESP_BODY}" && "${RESP_BODY}" != "{}" ]] && echo "    Response: ${RESP_BODY}"

if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "201" && "${HTTP_STATUS}" != "202" ]]; then
  echo "ERROR: Webhook returned HTTP ${HTTP_STATUS}."
  echo ""
  echo "==> Fetching pipeline state for diagnostics..."
  curl -sS -X GET \
    "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "Accept: application/json" \
    | jq '{status, worker, runs_url}'
  echo ""
  echo "==> Last pipeline run (if any)..."
  curl -sS -X GET \
    "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/pipeline_runs?count=1" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "Accept: application/json" \
    | jq '.pipeline_runs[0] | {id, status, trigger_name, error_message: .run_summary}'
  exit 1
fi

echo ""
echo "==> Done! Check the PipelineRun logs in the IBM Cloud Console:"
echo "    https://test.cloud.ibm.com/devops/pipelines/tekton/${PIPELINE_ID}?env_id=ibm:yp:${IBMCLOUD_REGION}"
