# TODO (§9.6): pin by manifest-list digest at publish time, e.g.
#   FROM debian:bookworm-slim@sha256:<digest>
# Get the current digest with:
#   docker buildx imagetools inspect debian:bookworm-slim
FROM debian:bookworm-slim AS base

LABEL org.opencontainers.image.title="HashGG" \
      org.opencontainers.image.description="Sovereign hash routing for Datum Gateway — expose your stratum port to the internet via playit.gg or a VPS SSH tunnel." \
      org.opencontainers.image.source="https://github.com/paulscode/hashgg" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl ca-certificates netcat-traditional socat nodejs jq procps openssh-client && \
    rm -rf /var/lib/apt/lists/*

# Install yq (same approach as datum-gateway-startos)
ENV yq_sha256_amd64=c0eb42f6fbf928f0413422967983dcdf9806cc4dedc9394edc60c0dfb4a98529
ENV yq_sha256_arm64=4ab0b301059348d671fc1833e99903c1fecc7ca287ac131f72dca0eb9a6ba87a

ARG ARCH
ARG PLATFORM
ARG TARGETARCH
# Use PLATFORM if provided (0.3.5.1 build), otherwise derive from TARGETARCH (0.4.0 build)
RUN PLAT="${PLATFORM:-${TARGETARCH}}"; \
    curl -sLo /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.46.1/yq_linux_${PLAT} && \
    eval echo "\${yq_sha256_${PLAT}} */usr/local/bin/yq" | sha256sum -c && \
    chmod +x /usr/local/bin/yq

# Install playit daemon binary (v1.0.0-rc17 playitd)
ENV PLAYIT_VERSION=1.0.0-rc17
RUN PLAT="${PLATFORM:-${TARGETARCH}}"; \
    if [ "$PLAT" = "amd64" ]; then \
      curl -sLo /tmp/playit.deb https://github.com/playit-cloud/playit-agent/releases/download/v${PLAYIT_VERSION}/playit_amd64.deb; \
    elif [ "$PLAT" = "arm64" ]; then \
      curl -sLo /tmp/playit.deb https://github.com/playit-cloud/playit-agent/releases/download/v${PLAYIT_VERSION}/playit_arm64.deb; \
    fi && \
    dpkg -x /tmp/playit.deb /tmp/playit-extract && \
    cp /tmp/playit-extract/opt/playit/playitd /usr/local/bin/playitd && \
    chmod +x /usr/local/bin/playitd && \
    rm -rf /tmp/playit.deb /tmp/playit-extract

WORKDIR /root

# Copy backend application
ADD ./app/backend /usr/local/lib/hashgg/backend
ADD ./app/frontend /usr/local/lib/hashgg/frontend

# Copy entrypoint and health checks
ADD ./docker_entrypoint.sh /usr/local/bin/docker_entrypoint.sh
RUN chmod a+x /usr/local/bin/docker_entrypoint.sh
ADD ./check-tunnel.sh /usr/local/bin/check-tunnel.sh
RUN chmod a+x /usr/local/bin/check-tunnel.sh
ADD ./check-datum.sh /usr/local/bin/check-datum.sh
RUN chmod a+x /usr/local/bin/check-datum.sh

# Informational — the entrypoint binds here; docker-compose / `docker run -p`
# decide how it's published on the host.
EXPOSE 3000

# Plain-Docker entrypoint. StartOS ignores this and uses manifest.yaml's
# `main.entrypoint` instead, so the StartOS build is unaffected.
ENTRYPOINT ["/usr/local/bin/docker_entrypoint.sh"]
