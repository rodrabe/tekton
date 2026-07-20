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
#   TOOLCHAIN_NAME      — defaults to log-message-toolchain
#   PIPELINE_NAME       — defaults to log-message-pipeline
#   WEBHOOK_SECRET      — token sent in X-Webhook-Token header (defaults to "changeme")
#   MESSAGE             — payload message (defaults to "Hello from IBM Cloud webhook trigger")
#   REPO_BRANCH         — git branch for the pipeline definition (defaults to "master")
#   TEKTON_PATH         — path inside repo containing Tekton YAML (defaults to ".tekton")
#   PKR_REGISTRY        — registry for the packer HCL (e.g. stg.icr.io/rodrabe)
#   PKR_IMAGE_NAME      — image name for the packer HCL (default: ibmcloud-cli)
#   PKR_IMAGE_TAG       — image tag for the packer HCL (default: latest)
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

TOOLCHAIN_NAME="${TOOLCHAIN_NAME:-log-message-toolchain}"
PIPELINE_NAME="${PIPELINE_NAME:-log-message-pipeline}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-changeme}"
REPO_BRANCH="${REPO_BRANCH:-main}"
TEKTON_PATH="${TEKTON_PATH:-.tekton}"
PKR_REGISTRY="${PKR_REGISTRY:-}"
# Append a UTC timestamp to the image name so each build produces a unique image.
# Override PKR_IMAGE_NAME to use a fixed name (e.g. for idempotent rebuilds).
PKR_TIMESTAMP="$(date -u +%Y%m%d%H%M%S)"
PKR_IMAGE_NAME="${PKR_IMAGE_NAME:-ibmcloud-cli}-${PKR_TIMESTAMP}"
PKR_IMAGE_TAG="${PKR_IMAGE_TAG:-latest}"
PKR_SUBNET_ID="${PKR_SUBNET_ID:-0726-610dd897-188d-4c68-8a7d-f756f556f0c9}"

TOOLCHAIN_API="https://api.${IBMCLOUD_REGION}.devops.test.cloud.ibm.com/toolchain/v2"
PIPELINE_API="https://api.${IBMCLOUD_REGION}.devops.test.cloud.ibm.com/pipeline/v2"

# ---------------------------------------------------------------------------
# 1. Authenticate
# ---------------------------------------------------------------------------
echo "==> Logging in to IBM Cloud..."
ibmcloud login --apikey "${IBMCLOUD_API_KEY}" -r "${IBMCLOUD_REGION}" -a "https://test.cloud.ibm.com" -q

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
  default   = "TMPL_API_KEY"
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
      "apt-get update -y",
      "apt-get install -y software-properties-common",
      "add-apt-repository universe -y",
      "apt-get update -y",
      "apt-get install -y curl jq ca-certificates",
      "curl -fsSL https://clis.cloud.ibm.com/install/linux | bash",
      "ibmcloud plugin install dev -f",
      "ibmcloud version",
    ]
  }
}
PKHCL
)

# Now substitute the template placeholders with the real values
PKR_HCL=$(printf '%s' "${PKR_HCL}" \
  | sed \
      -e "s|TMPL_API_KEY|${IBMCLOUD_API_KEY}|g" \
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
# 5. Find or create the pipeline definition (links pipeline to git source)
#
# NOTE: The pipeline definition requires the repository to be connected as a
#       tool integration in the toolchain. This OAuth/PAT authorisation cannot
#       be done via the REST API — it must be done once in the IBM Cloud Console.
# ---------------------------------------------------------------------------
echo "==> Checking pipeline definitions..."
DEFINITION_ID=$(curl -sS -X GET \
  "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/definitions" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Accept: application/json" \
  | jq -r --arg url "${REPO_URL%.git}" \
    '.definitions[] | select((.source.properties.url // "" | rtrimstr(".git")) == $url) | .id // empty' \
  | head -1)

if [[ -z "${DEFINITION_ID}" ]]; then
  # Find the repo tool integration ID in the toolchain
  echo "==> Looking for git tool integration for '${REPO_URL}'..."
  # Normalise both sides: strip trailing .git before comparing
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

  echo "==> Creating pipeline definition..."
  DEFINITION_ID=$(curl -sS -X POST \
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
    }" \
    | jq -r '.id')
  echo "    Created definition ID: ${DEFINITION_ID}"
else
  echo "    Found existing definition ID: ${DEFINITION_ID}"
fi

# ---------------------------------------------------------------------------
# 6. Find or create the generic webhook trigger
# ---------------------------------------------------------------------------
echo "==> Looking for existing trigger 'webhook-trigger'..."
TRIGGER=$(curl -sS -X GET \
  "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/triggers" \
  -H "Authorization: ${IAM_TOKEN}" \
  -H "Accept: application/json" \
  | jq -r '.triggers[] | select(.name == "webhook-trigger") | {id, webhook_url} | @base64' \
  | head -1)

if [[ -z "${TRIGGER}" ]]; then
  echo "==> Creating generic webhook trigger..."
  TRIGGER=$(curl -sS -X POST \
    "${PIPELINE_API}/tekton_pipelines/${PIPELINE_ID}/triggers" \
    -H "Authorization: ${IAM_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{
      \"type\": \"generic\",
      \"name\": \"webhook-trigger\",
      \"event_listener\": \"log-message-listener\",
      \"enabled\": true,
      \"secret\": {
        \"type\": \"token_matches\",
        \"source\": \"header\",
        \"key_name\": \"X-Webhook-Token\",
        \"algorithm\": \"plain\",
        \"value\": \"${WEBHOOK_SECRET}\"
      }
    }" \
    | jq -r '{id, webhook_url} | @base64')
  echo "    Created trigger."
else
  echo "    Found existing trigger."
fi

TRIGGER_ID=$(echo "${TRIGGER}"  | base64 -d | jq -r '.id')
WEBHOOK_URL=$(echo "${TRIGGER}" | base64 -d | jq -r '.webhook_url')
echo "    Trigger ID:  ${TRIGGER_ID}"
echo "    Webhook URL: ${WEBHOOK_URL}"

# ---------------------------------------------------------------------------
# 7. Fire the webhook — include PKR_HCL_B64 in the body so TriggerBinding picks it up
# ---------------------------------------------------------------------------
MESSAGE="${MESSAGE:-Hello from IBM Cloud webhook trigger}"
echo "==> Sending webhook with message: '${MESSAGE}'"
WEBHOOK_BODY=$(jq -n \
  --arg message "${MESSAGE}" \
  --arg hcl "${PKR_HCL_B64}" \
  '{"message": $message, "packer_hcl_b64": $hcl}')
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
  exit 1
fi

echo ""
echo "==> Done! Check the PipelineRun logs in the IBM Cloud Console:"
echo "    https://test.cloud.ibm.com/devops/pipelines/tekton/${PIPELINE_ID}?env_id=ibm:yp:${IBMCLOUD_REGION}"
