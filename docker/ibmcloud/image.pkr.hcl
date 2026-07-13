packer {
  required_plugins {
    docker = {
      source  = "github.com/hashicorp/docker"
      version = ">= 1.0.0"
    }
  }
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "image_name" {
  type    = string
  default = "ibmcloud-cli"
}

variable "registry" {
  type    = string
  default = ""
  # e.g. "us.icr.io/my-namespace"  — leave empty to keep image local only
}

locals {
  full_image = var.registry != "" ? "${var.registry}/${var.image_name}:${var.image_tag}" : "${var.image_name}:${var.image_tag}"
}

source "docker" "ibmcloud" {
  image  = "alpine:3.19"
  commit = true
  changes = [
    "LABEL org.opencontainers.image.description=Alpine with ibmcloud CLI and dev plugin",
    "ENTRYPOINT [\"/bin/sh\"]",
  ]
}

build {
  sources = ["source.docker.ibmcloud"]

  provisioner "shell" {
    inline = [
      # Install runtime dependencies
      "apk add --no-cache bash curl jq ca-certificates",

      # Install the ibmcloud CLI
      "curl -fsSL https://clis.cloud.ibm.com/install/linux | bash",

      # Install the dev plugin (provides tekton-trigger, toolchain-get, etc.)
      "ibmcloud plugin install dev -f",

      # Smoke-test
      "ibmcloud version",
      "ibmcloud plugin list",
    ]
  }

  post-processor "docker-tag" {
    repository = local.full_image
    only       = ["docker.ibmcloud"]
  }
}
