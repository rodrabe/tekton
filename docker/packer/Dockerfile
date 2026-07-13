FROM alpine:3.19

ARG PACKER_VERSION=1.11.2
ARG PACKER_IBM_VERSION=3.6.0

# Runtime dependencies
RUN apk add --no-cache bash curl jq ca-certificates unzip

# Install Packer — resolve arch at build time
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -fsSL "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${ARCH}.zip" \
      -o /tmp/packer.zip && \
    unzip /tmp/packer.zip -d /usr/local/bin && \
    rm /tmp/packer.zip && \
    packer version

# Install the IBM Cloud Packer plugin
# https://github.com/IBM/packer-plugin-ibmcloud
RUN packer plugins install github.com/IBM/ibmcloud "${PACKER_IBM_VERSION}"

ENTRYPOINT ["/bin/sh"]
