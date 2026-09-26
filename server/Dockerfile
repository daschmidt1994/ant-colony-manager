# syntax=docker/dockerfile:1
# Ant Colony Manager – server image (API + embedded web app).
# Multi-arch: Go is cross-compiled on the build machine, so building
# linux/arm64 on amd64 (and vice versa) needs no emulation.
#
#   docker buildx build --platform linux/amd64,linux/arm64 -f server/Dockerfile .

ARG GO_VERSION=1.26
# Web app source: flutter (build here, default) | prebuilt (app/build/web from
# the build context, used by CI) | placeholder (no Flutter, for low-memory hosts
# and quick tests – serves a simple status page instead of the web app).
ARG WEB_BUILD=flutter
ARG FLUTTER_IMAGE=ghcr.io/cirruslabs/flutter:3.44.0

FROM --platform=$BUILDPLATFORM ${FLUTTER_IMAGE} AS web-flutter
WORKDIR /src/app
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter config --no-analytics >/dev/null && flutter pub get
COPY app/ ./
RUN ./tool/fetch_web_assets.sh \
 && flutter build web --release --wasm --no-web-resources-cdn --no-source-maps \
 && mv build/web /web

FROM scratch AS web-prebuilt
COPY app/build/web /web

FROM scratch AS web-placeholder
COPY server/internal/webui/dist /web

FROM web-${WEB_BUILD} AS web

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build
ARG TARGETOS=linux
ARG TARGETARCH
ARG VERSION=dev
WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY server/ ./
COPY --from=web /web ./internal/webui/dist
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
