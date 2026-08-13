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

# Download the packer IBM Cloud plugin locally and upload it to COS once.
# The Tekton step downloads it from COS (reachable from staging) instead of GitHub (blocked).
PKR_PLUGIN_VERSION="${PKR_PLUGIN_VERSION:-3.6.0}"
PKR_PLUGIN_BINARY="packer-plugin-ibmcloud_v${PKR_PLUGIN_VERSION}_x5.0_linux_amd64"
PKR_PLUGIN_URL="https://github.com/IBM/packer-plugin-ibmcloud/releases/download/v${PKR_PLUGIN_VERSION}/${PKR_PLUGIN_BINARY}.zip"
PKR_PLUGIN_CACHE="${HOME}/.cache/packer-plugin-ibmcloud-${PKR_PLUGIN_VERSION}"
if [[ ! -f "${PKR_PLUGIN_CACHE}" ]]; then
  echo "==> Downloading packer-plugin-ibmcloud v${PKR_PLUGIN_VERSION}..."
  TMP_ZIP=$(mktemp)
  curl -fsSL "${PKR_PLUGIN_URL}" -o "${TMP_ZIP}"
  unzip -p "${TMP_ZIP}" "${PKR_PLUGIN_BINARY}" > "${PKR_PLUGIN_CACHE}"
  rm -f "${TMP_ZIP}"
  echo "    Cached to ${PKR_PLUGIN_CACHE}"
else
  echo "==> Using cached packer-plugin-ibmcloud v${PKR_PLUGIN_VERSION}"
fi
# COS upload happens after auth — deferred to step 4d below.
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
# 4d. Upload the packer plugin binary to COS so the Tekton step can fetch it.
#     Uses a fixed object key (not per-run) so subsequent deploys reuse it.
# ---------------------------------------------------------------------------
PKR_PLUGIN_COS_BUCKET="${PKR_PLUGIN_COS_BUCKET:-pipeline-assets}"
PKR_PLUGIN_COS_KEY="packer-plugins/${PKR_PLUGIN_BINARY}"
PKR_PLUGIN_COS_URL="${COS_API_ENDPOINT}/${PKR_PLUGIN_COS_BUCKET}/${PKR_PLUGIN_COS_KEY}"
COS_INSTANCE_ID="$(echo "${COS_INSTANCE_CRN}" | awk -F: '{print $8}')"
echo "==> Uploading packer plugin to COS (${PKR_PLUGIN_COS_URL})..."
# Use HEAD to check existence; --max-time guards against partial-response hangs
PLUGIN_HEAD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X HEAD "${PKR_PLUGIN_COS_URL}" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "ibm-service-instance-id: ${COS_INSTANCE_ID}" || echo "000")
if [[ "${PLUGIN_HEAD_STATUS}" == "200" ]]; then
  echo "    Plugin already in COS — skipping upload."
else
  echo "    HEAD status: ${PLUGIN_HEAD_STATUS} — creating bucket and uploading..."
  # Ensure bucket exists (ignore errors — bucket may already exist)
  curl -s -o /dev/null -X PUT "${COS_API_ENDPOINT}/${PKR_PLUGIN_COS_BUCKET}" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "ibm-service-instance-id: ${COS_INSTANCE_ID}" \
    -H "ibm-cos-bucket-location-constraint: ${COS_REGION}-standard" || true
  # Upload the binary
  UPLOAD_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "${PKR_PLUGIN_COS_URL}" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "ibm-service-instance-id: ${COS_INSTANCE_ID}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${PKR_PLUGIN_CACHE}")
  if [[ "${UPLOAD_STATUS}" == "200" ]]; then
    echo "    Uploaded: ${PKR_PLUGIN_COS_URL}"
  else
    echo "ERROR: COS upload returned HTTP ${UPLOAD_STATUS}."
    exit 1
  fi
fi

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
# 6. Find or create the manual trigger
# ---------------------------------------------------------------------------
echo "==> Finding or creating manual trigger..."
TRIGGER_ID=$(curl -sS -X GET \
  "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/triggers" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Accept: application/json" \
  | jq -r '.triggers[] | select(.name == "manual-trigger" and .type == "manual") | .id // empty' \
  | head -1)

if [[ -n "${TRIGGER_ID}" ]]; then
  echo "    Found existing manual trigger: ${TRIGGER_ID}"
else
  echo "==> Creating manual trigger..."
  TRIGGER_ID=$(curl -sS -X POST \
    "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/triggers" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{
      \"type\": \"manual\",
      \"name\": \"manual-trigger\",
      \"event_listener\": \"pipeline-image-builder-listener\",
      \"enabled\": true
    }" \
    | jq -r '.id // empty')
  echo "    Created manual trigger: ${TRIGGER_ID}"
fi

# ---------------------------------------------------------------------------
# 7. Trigger a pipeline run via the API
# ---------------------------------------------------------------------------
echo "==> Triggering pipeline run..."
echo "    Image name:  ${PKR_IMAGE_NAME}"
echo "    COS bucket:  ${COS_BUCKET}"
echo "    IBM Cloud:   ${IBMCLOUD_API_ENDPOINT}"
echo "    COS endpoint:${COS_API_ENDPOINT}"
echo "    COS CRN:     ${COS_INSTANCE_CRN}"

# Upload HCL to COS so it doesn't hit API body size limits
PKR_HCL_COS_KEY="pipeline-runs/${PKR_IMAGE_NAME}/ibmcloud.pkr.hcl.b64"
PKR_HCL_COS_URL="${COS_API_ENDPOINT}/${PKR_PLUGIN_COS_BUCKET}/${PKR_HCL_COS_KEY}"
echo "==> Uploading HCL to COS..."
_TMP_HCL=$(mktemp); printf '%s' "${PKR_HCL_B64}" > "${_TMP_HCL}"
HCL_UPLOAD_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "${PKR_HCL_COS_URL}" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "ibm-service-instance-id: ${COS_INSTANCE_ID}" \
  -H "Content-Type: text/plain" \
  --data-binary "@${_TMP_HCL}")
rm -f "${_TMP_HCL}"
if [[ "${HCL_UPLOAD_STATUS}" != "200" ]]; then
  echo "ERROR: HCL upload to COS returned HTTP ${HCL_UPLOAD_STATUS}."
  exit 1
fi
echo "    HCL uploaded: ${PKR_HCL_COS_URL}"

# Build trigger_properties — pass all params directly; key and COS URLs are small enough
_TMP_KEY=$(mktemp); printf '%s' "${PKR_KEY_B64}" > "${_TMP_KEY}"
_TMP_BODY=$(mktemp)
jq -n \
  --arg trigger_id            "${TRIGGER_ID}" \
  --arg image_name            "${PKR_IMAGE_NAME}" \
  --arg cos_bucket            "${COS_BUCKET}" \
  --arg cos_region            "${COS_REGION}" \
  --arg cos_instance_crn      "${COS_INSTANCE_CRN}" \
  --arg ibmcloud_api_endpoint "${IBMCLOUD_API_ENDPOINT}" \
  --arg cos_api_endpoint      "${COS_API_ENDPOINT}" \
  --arg packer_plugin_cos_url "${PKR_PLUGIN_COS_URL}" \
  --arg packer_hcl_cos_url    "${PKR_HCL_COS_URL}" \
  --rawfile key               "${_TMP_KEY}" \
  '{
    "trigger": {"id": $trigger_id},
    "trigger_properties": [
      {"name": "image-name",            "value": $image_name,            "type": "text"},
      {"name": "cos-bucket",            "value": $cos_bucket,            "type": "text"},
      {"name": "cos-region",            "value": $cos_region,            "type": "text"},
      {"name": "cos-instance-crn",      "value": $cos_instance_crn,      "type": "text"},
      {"name": "ibmcloud-api-endpoint", "value": $ibmcloud_api_endpoint, "type": "text"},
      {"name": "cos-api-endpoint",      "value": $cos_api_endpoint,      "type": "text"},
      {"name": "packer-plugin-cos-url", "value": $packer_plugin_cos_url, "type": "text"},
      {"name": "packer-hcl-cos-url",    "value": $packer_hcl_cos_url,    "type": "text"},
      {"name": "packer-key-b64",        "value": $key,                   "type": "text"}
    ]
  }' > "${_TMP_BODY}"
rm -f "${_TMP_KEY}"

echo "==> Request body:"; cat "${_TMP_BODY}" | jq .
_TMP_RESP=$(mktemp)
HTTP_STATUS=$(curl -sS -o "${_TMP_RESP}" -w "%{http_code}" -X POST \
  "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/pipeline_runs" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  --data-binary "@${_TMP_BODY}")
rm -f "${_TMP_BODY}"
RESP_BODY=$(cat "${_TMP_RESP}"); rm -f "${_TMP_RESP}"
echo "    HTTP status: ${HTTP_STATUS}"
[[ -n "${RESP_BODY}" && "${RESP_BODY}" != "{}" ]] && echo "    Response: ${RESP_BODY}"

if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "201" && "${HTTP_STATUS}" != "202" ]]; then
  echo "ERROR: Pipeline run API returned HTTP ${HTTP_STATUS}."
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
RUN_ID=$(echo "${RESP_BODY}" | jq -r '.id // empty')

echo ""
echo "==> Done! Pipeline run started."
[[ -n "${RUN_ID}" ]] && echo "    Run ID: ${RUN_ID}"
echo "    https://test.cloud.ibm.com/devops/pipelines/tekton/${PIPELINE_ID}?env_id=ibm:yp:${IBMCLOUD_REGION}"
# Write a ready-to-run re-trigger script to disk so all values are baked in.
# Only the SSH key and image timestamp need to be regenerated per run.
RETRIGGER_SCRIPT="$(mktemp -t retrigger).sh"
cat > "${RETRIGGER_SCRIPT}" <<RETRIGGER
#!/usr/bin/env bash
set -euo pipefail
PKR_TIMESTAMP="\$(date -u +%Y%m%d%H%M%S)"
PKR_IMAGE_NAME="ibmcloud-cli-\${PKR_TIMESTAMP}"
PKR_SSH_KEY_DIR=\$(mktemp -d)
ssh-keygen -t ed25519 -N "" -f "\${PKR_SSH_KEY_DIR}/packer_id_rsa" -C "packer-build-\${PKR_TIMESTAMP}" -q
PKR_KEY_B64=\$(base64 < "\${PKR_SSH_KEY_DIR}/packer_id_rsa" | tr -d '\n')
rm -rf "\${PKR_SSH_KEY_DIR}"
# Re-encode HCL with the new image name substituted in and upload to COS
PKR_HCL_B64=\$(printf '%s' '${PKR_HCL_B64}' | base64 -d \
  | sed "s|${PKR_IMAGE_NAME}|\${PKR_IMAGE_NAME}|g" \
  | base64 | tr -d '\n')
IAM_TOKEN=\$(ibmcloud iam oauth-tokens --output json | jq -r '.iam_token')
PKR_HCL_COS_URL="${COS_API_ENDPOINT}/${PKR_PLUGIN_COS_BUCKET}/pipeline-runs/\${PKR_IMAGE_NAME}/ibmcloud.pkr.hcl.b64"
_TMP_HCL=\$(mktemp); printf '%s' "\${PKR_HCL_B64}" > "\${_TMP_HCL}"
curl -sS -o /dev/null -X PUT "\${PKR_HCL_COS_URL}" \\
  -H "Authorization: \${IAM_TOKEN}" \\
  -H "ibm-service-instance-id: $(echo "${COS_INSTANCE_CRN}" | awk -F: '{print $8}')" \\
  -H "Content-Type: text/plain" \\
  --data-binary "@\${_TMP_HCL}"
rm -f "\${_TMP_HCL}"
_TMP_KEY=\$(mktemp); printf '%s' "\${PKR_KEY_B64}" > "\${_TMP_KEY}"
_TMP_BODY=\$(mktemp)
jq -n \\
  --arg trigger_id            "${TRIGGER_ID}" \\
  --arg image_name            "\${PKR_IMAGE_NAME}" \\
  --arg cos_bucket            "\${PKR_IMAGE_NAME}" \\
  --arg cos_region            "${COS_REGION}" \\
  --arg cos_instance_crn      "${COS_INSTANCE_CRN}" \\
  --arg ibmcloud_api_endpoint "${IBMCLOUD_API_ENDPOINT}" \\
  --arg cos_api_endpoint      "${COS_API_ENDPOINT}" \\
  --arg packer_plugin_cos_url "${PKR_PLUGIN_COS_URL}" \\
  --arg packer_hcl_cos_url    "\${PKR_HCL_COS_URL}" \\
  --rawfile key               "\${_TMP_KEY}" \\
  '{"trigger":{"id":$trigger_id},"trigger_properties":[
    {"name":"image-name",            "value":$image_name,            "type":"text"},
    {"name":"cos-bucket",            "value":$cos_bucket,            "type":"text"},
    {"name":"cos-region",            "value":$cos_region,            "type":"text"},
    {"name":"cos-instance-crn",      "value":$cos_instance_crn,      "type":"text"},
    {"name":"ibmcloud-api-endpoint", "value":$ibmcloud_api_endpoint, "type":"text"},
    {"name":"cos-api-endpoint",      "value":$cos_api_endpoint,      "type":"text"},
    {"name":"packer-plugin-cos-url", "value":$packer_plugin_cos_url, "type":"text"},
    {"name":"packer-hcl-cos-url",    "value":$packer_hcl_cos_url,    "type":"text"},
    {"name":"packer-key-b64",        "value":$key,                   "type":"text"}
  ]}' > "\${_TMP_BODY}"
rm -f "\${_TMP_KEY}"
curl -sS -X POST "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/pipeline_runs" \\
  -H "Authorization: \${IAM_TOKEN}" \\
  -H "Content-Type: application/json" \\
  -H "Accept: application/json" \\
  --data-binary "@\${_TMP_BODY}" | jq '{id,status,html_url}'
rm -f "\${_TMP_BODY}"
RETRIGGER
chmod +x "${RETRIGGER_SCRIPT}"
echo ""
echo "==> To kick off a new pipeline run:"
echo "    ${RETRIGGER_SCRIPT}"
