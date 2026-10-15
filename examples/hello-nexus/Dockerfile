# tiny test image, the smoke test pushes this to nexus
FROM busybox:1.38

LABEL org.opencontainers.image.title="hello-nexus" \
      org.opencontainers.image.description="Sample artifact published to a private Nexus Docker registry"

ARG VERSION=dev
ENV APP_VERSION=${VERSION}

USER 65534:65534
CMD ["sh", "-c", "echo \"Hello from Nexus! version=${APP_VERSION}\""]
