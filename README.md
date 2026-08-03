# tekton

IBM Cloud Tekton pipeline that logs a string parameter and builds a Packer image, delivered via a webhook trigger.

## Structure

```
.tekton/
├── task-log-message.yaml     # Tekton Task — runs packer build and logs message
├── pipeline-log-message.yaml # Tekton Pipeline — defines task orchestration
├── tekton-pipeline.yaml      # TriggerBinding + TriggerTemplate + EventListener
├── toolchain.yaml            # IBM Cloud Continuous Delivery toolchain definition
└── deploy.sh                 # Deploy + trigger orchestration script

examples/
└── pipeline-run-log-message.yaml  # Manual PipelineRun for local ad-hoc testing
```

## Prerequisites

```bash
# 1. Install the IBM Cloud CLI
#    https://cloud.ibm.com/docs/cli

# 2. Install the 'dev' plugin (provides toolchain and pipeline APIs)
ibmcloud plugin install dev

# 3. Install jq (used by deploy.sh for JSON parsing)
#    macOS:  brew install jq
#    Linux:  apt-get install jq  /  yum install jq

# 4. Install curl (for downloading files)
```

> **Note:** The deploy script uses the [Toolchain REST API](https://cloud.ibm.com/apidocs/toolchain) 
> and [Pipeline REST API](https://cloud.ibm.com/apidocs/pipeline-api) directly rather than 
> the `continuous-delivery` plugin, which is no longer available in the IBM Cloud registry.

## Deploy Script (`deploy.sh`)

The `deploy.sh` script fully orchestrates the setup and triggering of the Tekton pipeline 
on IBM Cloud. It is idempotent — running it multiple times is safe; it finds or creates 
resources as needed.

### What it does:

1. **Authenticate** to IBM Cloud using the API key and select the region/resource group
2. **Resolve resource group ID** needed for VPC operations in Packer builds
3. **Generate Packer HCL** template dynamically with credentials and VPC config
4. **Create or find the toolchain** (Continuous Delivery container)
5. **Create or find the pipeline tool** inside the toolchain
6. **Connect the git repository** to the pipeline (must be done manually in the IBM Cloud 
   Console on first run — see below)
7. **Create or find the pipeline definition** that links to this repository's `.tekton/` folder
8. **Create or find the webhook trigger** that will fire the pipeline
9. **Fire the webhook** with the message and Packer config as parameters
10. **Print the console URL** to view the running PipelineRun

### Required environment variables:

```bash
export IBMCLOUD_API_KEY="..."              # IBM Cloud API key (found in your account)
export IBMCLOUD_REGION="us-south"          # Region where resources are deployed
export RESOURCE_GROUP="Default"            # Exact resource group name (case-sensitive)
export REPO_URL="https://github.com/..."   # HTTPS URL of this git repository
```

### Optional environment variables:

```bash
# Pipeline naming
TOOLCHAIN_NAME="log-message-toolchain"     # Toolchain name (default: shown)
PIPELINE_NAME="log-message-pipeline"       # Pipeline name (default: shown)
WEBHOOK_SECRET="changeme"                  # Token validated in X-Webhook-Token header

# Git config
REPO_BRANCH="main"                         # Git branch (default: shown)
TEKTON_PATH=".tekton"                      # Path to Tekton YAML inside repo (default: shown)

# Packer image config
PKR_IMAGE_NAME="ibmcloud-cli"              # Base image name; timestamp appended (default: shown)
PKR_IMAGE_TAG="latest"                     # Image tag (default: shown)
PKR_REGISTRY=""                            # Optional registry prefix (e.g. stg.icr.io/user)
PKR_SUBNET_ID="0726-610dd897-..."          # VPC subnet ID for Packer VSI (preset to staging)

# COS (Cloud Object Storage) — for stage-to-cos task (if re-added)
COS_REGION="us-south"                      # COS region (defaults to IBMCLOUD_REGION)
COS_BUCKET="ibmcloud-cli-..."              # COS bucket (defaults to timestamped image name)

# Staging/testing endpoints
IBMCLOUD_API_ENDPOINT="https://test.cloud.ibm.com"                              # IBM Cloud endpoint (staging)
COS_API_ENDPOINT="https://s3.us-west.cloud-object-storage.test.appdomain.cloud" # COS endpoint (staging)
COS_INSTANCE_CRN="crn:v1:staging:public:..."                                   # COS instance CRN (staging)

# Packer version
PACKER_IBM_VERSION="3.6.0"                 # IBM Cloud Packer plugin version (default: 3.6.0)
```

### First-time setup:

On the first run, the script will:
1. Create the toolchain
2. Create the pipeline tool
3. **Fail** at the pipeline definition step if the repository is not yet connected

**Action required:**
```
==> Looking for git tool integration for 'https://github.com/rodrabe/tekton'...

============================================================
  ACTION REQUIRED: Connect the git repository
============================================================
  1. Open the toolchain in the IBM Cloud Console:
     https://test.cloud.ibm.com/devops/toolchains/<TOOLCHAIN_ID>...

  2. Click 'Add tool' → select your git provider
     (GitHub, GitHub Enterprise, GitLab, etc.)

  3. Authorise and link: https://github.com/rodrabe/tekton

  4. Re-run this script.
============================================================
```

Once the repository is linked as a tool in the toolchain, re-run the script and it will 
create the pipeline definition and fire the first webhook.

### Usage:

```bash
chmod +x .tekton/deploy.sh

export IBMCLOUD_API_KEY="..."
export IBMCLOUD_REGION="us-south"
export RESOURCE_GROUP="Default"
export REPO_URL="https://github.com/rodrabe/tekton"

# Deploy and trigger
./.tekton/deploy.sh

# Re-trigger with a custom message
MESSAGE="My custom message" ./.tekton/deploy.sh

# View the running pipeline in IBM Cloud Console
# URL printed at end: https://test.cloud.ibm.com/devops/pipelines/tekton/<PIPELINE_ID>
```

## Pipeline structure

### Task: `log-message` (task-log-message.yaml)

Runs inside a Packer container (`hashicorp/packer:1.15.4`):

1. Installs the IBM Cloud Packer plugin (v3.6.0)
2. Decodes and writes the SSH private key and Packer HCL config from base64
3. Runs `packer validate` on the HCL
4. Runs `packer build` to create a VPC image on IBM Cloud:
   - Provisions a temporary VPC, security group, floating IP
   - SSH connects to the VSI
   - Runs shell provisioner: apt-get update, installs curl/jq/ca-certs, downloads IBM Cloud CLI
5. Logs the message string and counts its characters
6. Writes Tekton results: `message`, `character-count`, `image-name`

**Outputs** (Tekton results):
- `message` — The webhook message
- `character-count` — Character count of the message
- `image-name` — Name of the Packer image built

### Pipeline: `log-message-pipeline` (pipeline-log-message.yaml)

Wires the task with parameters from the webhook trigger payload:

```yaml
tasks:
  - name: log-message
    params:
      - message: from webhook
      - image-name: generated by deploy.sh (timestamped)
      - packer-hcl-b64: base64-encoded Packer template
      - packer-key-b64: base64-encoded SSH private key
```

### Webhook trigger (tekton-pipeline.yaml)

Defines:
- **TriggerBinding** — maps webhook body fields to pipeline parameters
- **EventListener** — HTTP endpoint that receives webhooks
- **TriggerTemplate** — creates a PipelineRun when a webhook arrives

The webhook expects a JSON POST:

```json
{
  "message": "Hello from IBM Cloud webhook trigger",
  "image_name": "ibmcloud-cli-20260803163823",
  "cos_bucket": "ibmcloud-cli-20260803163823",
  "cos_region": "us-south",
  "ibmcloud_api_key": "...",
  "cos_instance_crn": "crn:v1:staging:...",
  "ibmcloud_api_endpoint": "https://test.cloud.ibm.com",
  "cos_api_endpoint": "https://s3.us-west.cloud-object-storage.test.appdomain.cloud",
  "packer_hcl_b64": "...",
  "packer_key_b64": "..."
}
```

The `deploy.sh` script generates this payload automatically and sends it to the webhook URL.

## Viewing pipeline runs

The console URL is printed at the end of `deploy.sh`:

```
https://test.cloud.ibm.com/devops/pipelines/tekton/<PIPELINE_ID>?env_id=ibm:yp:us-south
```

Click any `PipelineRun` to view task logs, including:
- Packer version, plugin install
- VPC resource creation (instance, SSH key, floating IP, security group)
- SSH connection and provisioning output
- Message logging and character count

## Notes on staging vs. production

This pipeline is configured to use **staging** IBM Cloud endpoints:
- API: `https://test.cloud.ibm.com`
- COS: `https://s3.us-west.cloud-object-storage.test.appdomain.cloud`

To switch to production, set:
```bash
export IBMCLOUD_API_ENDPOINT="https://cloud.ibm.com"
export COS_API_ENDPOINT=""  # Production COS auto-endpoint
export COS_INSTANCE_CRN="crn:v1:public:cloud-object-storage:global:..."
```

## Troubleshooting

**Pipeline run fails: "Could not read from input: EOF"**
- This is expected if you run `ibmcloud plugin install --dry-run`; use `-f` flag instead

**"The git repository must be connected to the toolchain..."**
- This is the first-time setup step; see "First-time setup" above

**Packer build timeout (30m)**
- The VSI provisioning shell script may take time to download/install packages
- Check `ibmcloud login`, API endpoint connectivity, and VPC quota

**COS upload fails: "bucket was not found"**
- The `store-to-cos` task is currently removed from the pipeline
- Re-add it if needed by restoring from commit history

## Git commits

Recent commits show the evolution:
- `889876c` — Removed store-to-cos task (simplified to log-message only)
- `1cbb8af` — Added full task 1 output upload to COS via workspace
- `58df45e` — Fixed COS plugin download from IBM Cloud CDN (not registry)
- `e4dbfb6` — Initial working pipeline structure
