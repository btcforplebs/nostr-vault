# syntax=docker/dockerfile:1
# nv-mesh for linux/arm64 (Pi 4) and linux/amd64. Build from the repo root:
#   docker buildx build -f linux/mesh/Dockerfile --platform linux/arm64,linux/amd64 .
# The nostr-vault-linux image takes the binary from the `build` stage
# (/out/nv-mesh) and the runtime libraries listed in `runtime`.

FROM rust:1.94.1-bookworm AS build
# fips on glibc Linux links nftables (rustables, through bindgen: libclang and
# headers) and BlueZ over D-Bus (bluer).
RUN apt-get update \
 && apt-get install -y --no-install-recommends clang libclang-dev libnftnl-dev libmnl-dev libdbus-1-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# Only what the build reads (see Dockerfile.dockerignore).
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

# Stand-alone mesh image, for testing the engine without havend.
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends libnftnl11 libmnl0 libdbus-1-3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/nv-mesh /usr/local/bin/nv-mesh
ENV NV_DATA_DIR=/data NV_PORT=8080
VOLUME /data
ENTRYPOINT ["/usr/local/bin/nv-mesh"]
