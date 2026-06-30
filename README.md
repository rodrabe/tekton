# tekton

IBM Cloud Tekton pipeline that logs a string parameter delivered via a webhook trigger.

## Structure

```
.tekton/
├── task-log-message.yaml          # Tekton Task — echoes the message param
├── pipeline-log-message.yaml      # Tekton Pipeline — wires the task
├── tekton-pipeline.yaml           # TriggerBinding + TriggerTemplate + EventListener
├── toolchain.yaml                 # IBM Cloud Continuous Delivery toolchain definition
├── pipeline-run-log-message.yaml  # Manual PipelineRun for ad-hoc testing
└── deploy.sh                      # Deploy + trigger script using ibmcloud CLI
```

## Prerequisites

```bash
# Install the IBM Cloud CLI
# https://cloud.ibm.com/docs/cli

ibmcloud plugin install continuous-delivery
ibmcloud plugin install dev
```

## Deploy

```bash
export IBMCLOUD_API_KEY=<your-api-key>
export IBMCLOUD_REGION=us-south          # change to your region
export RESOURCE_GROUP=default
export REPO_URL=https://github.com/<org>/tekton

chmod +x .tekton/deploy.sh
./.tekton/deploy.sh
```

## Trigger the webhook

```bash
# With a custom message
MESSAGE="my custom string" ./.tekton/deploy.sh

# Or fire the webhook directly once you have the URL
curl -X POST "<WEBHOOK_URL>" \
  -H "Content-Type: application/json" \
  -d '{"message": "hello world"}'
```

The resulting `PipelineRun` will log the string in the `log-message` step.
