# syntax=docker/dockerfile:1
# Nostr Vault for Linux: one container, "nostr-vault-linux", for arm64 (Raspberry Pi and the like) and amd64.
#   docker buildx build --platform linux/arm64,linux/amd64 -f linux/Dockerfile .      (from the repo root)
# Inside, under one supervisor (linux/supervise.sh, run by tini as root only to set up /data and drop privileges):
#   havend + haven-engine (haven-go/cmd/havend, Tal) as uid 10002 "vault": the relay, Blossom, the owner-only
#     /api/box/ and the web app, all on NV_PORT; the engine itself on 127.0.0.1:NV_ENGINE_PORT;
#   nv-mesh (linux/mesh, Tim) as uid 10001 "nvmesh": the box's mesh key is its alone (linux/mesh/README.md);
#   the web app built with NV_BOX=1 (web-vault/src/box, Tom), served at the box's root.
# The box never holds the owner's nsec. The Go programs and the web app build on the build machine's own arch; the
# Rust mesh process builds for each target (under emulation for the foreign one: slow, but cached).

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

# havend and the vault engine, pure Go (-tags nolmdb: Badger only, as libhaven on the Mac), cross-compiled.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS havend
ARG TARGETOS TARGETARCH NV_COMMIT=
ENV CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH
WORKDIR /src/haven-go
COPY haven-go ./
RUN --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    mkdir -p /out \
 && go build -trimpath -ldflags "-s -w -X main.version=$NV_COMMIT" -o /out/havend ./cmd/havend \
 && go build -trimpath -ldflags "-s -w" -tags nolmdb -o /out/haven-engine .

# nv-mesh: the same steps as linux/mesh/Dockerfile's build stage (keep the two in step).
FROM rust:1.94.1-bookworm AS mesh
RUN apt-get update \
 && apt-get install -y --no-install-recommends clang libclang-dev libnftnl-dev libmnl-dev libdbus-1-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY fips-v2/src/stack.rs fips-v2/src/stack.rs
COPY web-relay-vault web-relay-vault
COPY fips-v2-android fips-v2-android
COPY linux/mesh linux/mesh
WORKDIR /src/linux/mesh
ARG TARGETPLATFORM
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/linux/mesh/target,id=nv-mesh-target-${TARGETPLATFORM} \
    cargo build --release --locked \
 && mkdir -p /out && cp target/release/nv-mesh /out/nv-mesh

FROM debian:bookworm-slim
ARG NV_COMMIT=
LABEL org.opencontainers.image.title="nostr-vault-linux" \
      org.opencontainers.image.source="https://github.com/btcforplebs/nostr-vault" \
      org.opencontainers.image.revision="$NV_COMMIT"
# nv-mesh's runtime libraries (linux/mesh/README.md); setpriv (util-linux) drops each program to its uid.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini ca-certificates curl libnftnl11 libmnl0 libdbus-1-3 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin nvmesh \
 && useradd --system --uid 10002 --no-create-home --shell /usr/sbin/nologin vault \
 && install -d -m 711 -o vault -g vault /data
COPY --from=havend /out/havend /app/bin/havend
COPY --from=havend /out/haven-engine /usr/local/bin/haven-engine
COPY --from=mesh /out/nv-mesh /app/bin/nv-mesh
COPY --from=web /src/web-vault/dist /app/web
COPY --chmod=755 linux/supervise.sh /app/bin/supervise
ENV NV_DATA_DIR=/data NV_PORT=8080 NV_MESH_DOOR_PORT=8081 HAVEN_MESH_PLAIN_PORT=8081 NV_WEB_DIR=/app/web \
    NV_BIN=/app/bin NV_ENGINE_BIN=/usr/local/bin/haven-engine NV_VERSION=$NV_COMMIT
VOLUME /data
EXPOSE 8080
# Any HTTP answer on the port means havend is up.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NV_PORT}/")" != "000"
ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/supervise"]
