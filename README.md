# tekton

IBM Cloud Tekton pipeline that logs a string parameter delivered via a webhook trigger.

## Structure

```
.tekton/
├── task-log-message.yaml     # Tekton Task — echoes the message param
├── pipeline-log-message.yaml # Tekton Pipeline — wires the task
├── tekton-pipeline.yaml      # TriggerBinding + TriggerTemplate + EventListener
├── toolchain.yaml            # IBM Cloud Continuous Delivery toolchain definition
└── deploy.sh                 # Deploy + trigger script using ibmcloud CLI

examples/
└── pipeline-run-log-message.yaml  # Manual PipelineRun for local ad-hoc testing
                                   # (kept outside .tekton/ — IBM Cloud rejects
                                   #  PipelineRun objects in the definition path)
```

## Prerequisites

```bash
# 1. Install the IBM Cloud CLI
#    https://cloud.ibm.com/docs/cli

# 2. Install the 'dev' plugin (provides toolchain-get, tekton-trigger, etc.)
ibmcloud plugin install dev

# 3. Install jq (used by deploy.sh for JSON parsing)
#    macOS:  brew install jq
#    Linux:  apt-get install jq  /  yum install jq
```

> **Note:** `toolchain-create` was removed from the `dev` plugin in v3+. `deploy.sh` now
> creates toolchains directly via the [Toolchain REST API](https://cloud.ibm.com/apidocs/toolchain).
> The `continuous-delivery` plugin is no longer available in the IBM Cloud plugin repository.

## Deploy

```bash
export IBMCLOUD_API_KEY="provide your api key"
export IBMCLOUD_REGION=us-south          # change to your region
export RESOURCE_GROUP=Default            # exact name, case-sensitive — run: ibmcloud resource groups
export REPO_URL=https://github.com/rodrabe/tekton
export WEBHOOK_SECRET=changeme           # token validated in X-Webhook-Token header

chmod +x .tekton/deploy.sh
./.tekton/deploy.sh
```

## Trigger the webhook

```bash
# Re-run with a custom message (skips resource creation if already deployed)
MESSAGE="my custom string" ./.tekton/deploy.sh

# Or fire the webhook directly
curl -X POST "<WEBHOOK_URL>" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Token: changeme" \
  -d '{"message": "hello world"}'
```

The resulting `PipelineRun` will log the string in the `log-message` step.
