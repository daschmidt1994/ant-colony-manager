# syntax=docker/dockerfile:1
# Ant Colony Manager – server image (API + embedded web app).
# Multi-arch: Go is cross-compiled on the build machine, so building
# linux/arm64 on amd64 (and vice versa) needs no emulation.
#
#   docker buildx build --platform linux/amd64,linux/arm64 -f server/Dockerfile .

ARG GO_VERSION=1.26

# Phase 5 adds a Flutter stage here that builds the web app into
# server/internal/webui/dist (until then the placeholder page is embedded).

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build
ARG TARGETOS=linux
ARG TARGETARCH
ARG VERSION=dev
WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY server/ ./
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/acm ./cmd/acm \
 && mkdir -p /out/data/uploads /out/data/backups

FROM gcr.io/distroless/static-debian12:nonroot
LABEL org.opencontainers.image.title="Ant Colony Manager" \
      org.opencontainers.image.description="Self-hosted ant colony management – API and web app" \
      org.opencontainers.image.source="https://github.com/daschmidt1994/ant-colony-manager"
COPY --from=build /out/acm /acm
COPY --from=build --chown=65532:65532 /out/data /data
ENV STORAGE_PATH=/data/uploads BACKUP_STATUS_DIR=/data/backups LISTEN_ADDR=:8080
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD ["/acm", "healthcheck"]
ENTRYPOINT ["/acm"]
CMD ["serve"]
