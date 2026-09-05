# Simulates an AWS Lambda-style memory-constrained environment via
# `docker run --memory=`. Build once from the REPO ROOT (not this
# directory — needs src/include/python/build.zig as build context):
#   docker build -f bench/lambda/Dockerfile -t libscanio-lambda-bench .
# then run bench_lambda_tiers.sh to sweep tiers. bench_lambda_tiers.sh
# does both steps for you.
#
# arm64 base by default — matches Apple Silicon hosts natively (avoids
# QEMU crashes building Zig under x86_64 emulation on Docker Desktop) and
# happens to match AWS Graviton Lambda's real architecture. For an x86_64
# Lambda comparison, rebuild with `--platform linux/amd64` and swap the
# zig download URL below to zig-x86_64-linux-0.15.2.tar.xz.
FROM python:3.12-slim

RUN apt-get update && apt-get install -y curl xz-utils && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz -o /tmp/zig.tar.xz \
    && tar -xf /tmp/zig.tar.xz -C /opt \
    && mv /opt/zig-aarch64-linux-0.15.2 /opt/zig \
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
