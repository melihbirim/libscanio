# Simulates an AWS Lambda-style memory-constrained environment via
# `docker run --memory=`. Build once from the REPO ROOT (not this
# directory — needs src/include/python/build.zig as build context):
#   docker build -f bench/lambda/Dockerfile -t libscanio-lambda-bench .
# then run bench_lambda_tiers.sh to sweep tiers. bench_lambda_tiers.sh
# does both steps for you.
#
# Architecture auto-detected via Docker's own TARGETARCH build arg
# (set automatically from the build's --platform, defaulting to the
# host's native arch when --platform is omitted) — NOT hardcoded.
# Hardcoding one arch here once caused a real incident: an earlier
# version of this file hardcoded an x86_64 Zig binary, which forced
# QEMU emulation on an Apple Silicon host, and the emulated build
# segfaulted (`qemu: uncaught target signal 11`) — which in turn left
# Docker Desktop's own backend/watchdog in a bad state, spawning a
# dozen zombie processes at ~90% CPU each until force-killed. Building
# natively (this Dockerfile's default, no --platform flag needed) is
# not just faster, it avoids that whole failure class outright. Native
# arm64 also happens to match AWS Graviton Lambda's real architecture.
FROM python:3.12-slim
ARG TARGETARCH

RUN apt-get update && apt-get install -y curl xz-utils && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
        arm64) ZIG_ARCH=aarch64 ;; \
        amd64) ZIG_ARCH=x86_64 ;; \
        *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://ziglang.org/download/0.15.2/zig-${ZIG_ARCH}-linux-0.15.2.tar.xz" -o /tmp/zig.tar.xz \
    && tar -xf /tmp/zig.tar.xz -C /opt \
    && mv "/opt/zig-${ZIG_ARCH}-linux-0.15.2" /opt/zig \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

RUN pip install --no-cache-dir pyarrow

WORKDIR /libscanio
# Built from the real repo source, not a copied host binary — the whole
# point is testing the actual Linux build under real memory ceilings.
COPY src /libscanio/src
COPY include /libscanio/include
COPY python /libscanio/python
COPY build.zig /libscanio/build.zig
RUN zig build c-lib -Doptimize=ReleaseFast

COPY bench/lambda/run_libscanio.py bench/lambda/run_pyarrow.py /bench/
WORKDIR /work
