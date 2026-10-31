# syntax=docker/dockerfile:1
# Nostr Vault for Linux: one container, "nostr-vault-linux", for arm64 (Raspberry Pi and the like) and amd64.
#   docker buildx build --platform linux/arm64,linux/amd64 -f linux/Dockerfile .      (from the repo root)
# Inside: havend (the vault: relay, Blossom, the owner-only /api/box/, the web app, all on NV_PORT), the mesh
# process, and one supervisor (linux/supervise.sh) that starts either again when it exits. Data lives in /data
# (NV_DATA_DIR), the host path the owner picked in install.sh. The box never holds the owner's nsec.
#
# Until havend (haven-go/cmd/havend, Tal) and the mesh process (linux/mesh/, Tim) land, linux/stubs/ stand in for
# them: the same names, the same port, nothing kept. The web app is built with NV_BOX=1 (Tom's box mode).
# Every build step runs on the build machine's own arch; only the runtime stage's apt-get runs per platform.

FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS go

# The web app, once: its output is the same for every platform.
FROM --platform=$BUILDPLATFORM node:24-alpine AS web
COPY --from=go /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH
ARG NV_COMMIT=
WORKDIR /src
COPY haven-go ./haven-go
COPY web-relay ./web-relay
COPY web-vault ./web-vault
RUN web-relay/tools/build-haven-wasm.sh \
 && (cd web-relay && npm ci --ignore-scripts --no-audit --no-fund) \
 && cd web-vault && npm ci --ignore-scripts --no-audit --no-fund \
 && NV_BOX=1 NV_COMMIT=$NV_COMMIT npm run build \
 && test -s dist/index.html

# The box's programs, cross-compiled for the target.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS bin
ARG TARGETOS TARGETARCH
ENV CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH
WORKDIR /src
COPY linux/stubs ./stubs
RUN mkdir -p /out \
 && go build -trimpath -ldflags "-s -w" -o /out/havend ./stubs/havend/main.go \
 && go build -trimpath -ldflags "-s -w" -o /out/nv-mesh ./stubs/nv-mesh/main.go

FROM debian:bookworm-slim
ARG NV_COMMIT=
LABEL org.opencontainers.image.title="nostr-vault-linux" \
      org.opencontainers.image.source="https://github.com/btcforplebs/nostr-vault" \
      org.opencontainers.image.revision="$NV_COMMIT"
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin vault \
 && install -d -o vault -g vault -m 700 /data
COPY --from=bin /out/ /app/bin/
COPY --from=web /src/web-vault/dist /app/web
COPY --chmod=755 linux/supervise.sh /app/bin/supervise
ENV NV_DATA_DIR=/data NV_PORT=8080 NV_WEB_DIR=/app/web NV_BIN=/app/bin NV_VERSION=$NV_COMMIT
USER vault
VOLUME /data
EXPOSE 8080
# Any HTTP answer on the port means havend is up (the stub and the real one answer / differently).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NV_PORT}/")" != "000"
ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/supervise"]
