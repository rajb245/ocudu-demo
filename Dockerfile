# syntax=docker/dockerfile:1.7
# SPDX-FileCopyrightText: Copyright (C) 2026 DeepSig Inc.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# OCUDU ZMQ demo image: gNB with the dApp runtime, the embedded E3 plane and
# (optionally) the CUDA-accelerated L1, built for a ZeroMQ virtual radio.
#
# Recipe follows the Dockerfile in ocudu-dapp-quickstart (asn1c fork with
# -gen-APER, flatc, asn1tools venv, clang) with ZeroMQ added for the
# virtual-radio demo and UHD kept for split-8 USRPs. DPDK stays off (no
# split-7.2 fronthaul here). That repo is a reference, not an input: nothing
# here reads it, so bootstrap.sh does not clone it. It is public at
# https://gitlab.com/ocudu/work_groups/wg2_ai_ran/ocudu-dapp-quickstart.
#
# Build context is the workspace root holding ocudu/ and ocudu-dapp-sdk/.
#
#   docker compose -f demo/docker-compose.yml build gnb        # CPU L1
#   docker compose -f demo/docker-compose.yml build gnb-cuda   # CUDA L1
#
# CPU and CUDA are the same stages with a different BASE_IMAGE, so only the
# variant you ask for is ever built.

ARG BASE_IMAGE=ubuntu:24.04

# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS toolchain

ARG DEBIAN_FRONTEND=noninteractive
ARG ASN1C_REPOSITORY=https://github.com/mouse07410/asn1c.git
# Pinned asn1c fork commit with the APER generator used by the release.
ARG ASN1C_COMMIT=844f9ca

RUN apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates git curl pkg-config \
    build-essential ccache clang cmake ninja-build \
    autoconf automake libtool bison flex \
    flatbuffers-compiler libflatbuffers-dev libgtest-dev libgmock-dev \
    libboost-program-options-dev libconfig++-dev libfftw3-dev \
    libmbedtls-dev libsctp-dev lksctp-tools libyaml-cpp-dev \
    libzmq3-dev libnuma-dev libssl-dev libpcap-dev nlohmann-json3-dev \
    libuhd-dev uhd-host \
    python3 python3-pip python3-venv python3-numpy python3-yaml \
    iproute2 iputils-ping iperf3 netcat-openbsd gdb \
  && rm -rf /var/lib/apt/lists/*

# asn1c with Aligned PER support (the distribution package lacks -gen-APER).
RUN git clone --depth 200 "${ASN1C_REPOSITORY}" /opt/src/asn1c \
  && cd /opt/src/asn1c && git checkout "${ASN1C_COMMIT}" \
  && test -f configure.ac && autoreconf -iv \
  && ./configure --prefix=/opt/asn1c \
  && make -j"$(nproc)" && make install \
  && /opt/asn1c/bin/asn1c -v 2>&1 | head -1 \
  && rm -rf /opt/src/asn1c

# Python side: schema tooling for the E3 codecs and the client CLIs.
RUN python3 -m venv /opt/venv \
  && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
  && /opt/venv/bin/pip install --no-cache-dir \
    asn1tools numpy h5py pyzmq flatbuffers PyYAML
ENV PATH=/opt/venv/bin:/opt/asn1c/bin:${PATH}

# ---------------------------------------------------------------------------
FROM toolchain AS ocudu-host

ARG OCUDU_BUILD_TYPE=Release
ARG OCUDU_JOBS=8
ARG OCUDU_ENABLE_CUDA=OFF
ARG OCUDU_CUDA_ARCHITECTURES=89-real
# Portable across modern x86-64 (AVX2). Override with native for a host-local
# build, or with a narrower value for an older target.
ARG OCUDU_MARCH=x86-64-v3
ARG OCUDU_C_COMPILER=clang
ARG OCUDU_CXX_COMPILER=clang++
# UHD for split-8 USRPs (B2xx, N3x0, N32x, X3x0, X410). ZeroMQ stays on, so
# one image serves both the virtual-radio demo and a real front end; which one
# runs is a device_driver choice in the gNB YAML.
ARG OCUDU_ENABLE_UHD=ON

# ENABLE_WERROR defaults ON upstream and the CUDA-only header
# lib/phy/upper/resource_grid_cuda_visible_impl.h declares a dead private
# field (host_shadow_from_index, one occurrence in the whole tree), which
# clang rejects as -Werror,-Wunused-private-field. It only bites when
# ENABLE_CUDA=ON, so the CPU image never sees it. Warnings are still printed;
# they just do not fail a build of a branch we are consuming, not developing.
# Drop this once the declaration is removed upstream.

WORKDIR /work
COPY ocudu /work/ocudu

RUN --mount=type=cache,id=ocudu-demo-ccache,target=/root/.cache/ccache \
    cmake -S /work/ocudu -B /work/ocudu/build -G Ninja \
      -DCMAKE_C_COMPILER=${OCUDU_C_COMPILER} -DCMAKE_CXX_COMPILER=${OCUDU_CXX_COMPILER} \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache \
      -DCMAKE_BUILD_TYPE=${OCUDU_BUILD_TYPE} \
      "-DCMAKE_CUDA_ARCHITECTURES=${OCUDU_CUDA_ARCHITECTURES}" \
      -DMARCH=${OCUDU_MARCH} \
      -DENABLE_DAPP=ON -DENABLE_E3=ON -DENABLE_E3_ASN1_CODEC=ON \
      -DASN1C_EXECUTABLE=/opt/asn1c/bin/asn1c \
      -DENABLE_ZEROMQ=ON -DENABLE_UHD=${OCUDU_ENABLE_UHD} -DENABLE_DPDK=OFF \
      -DENABLE_EXPORT=ON \
      -DENABLE_MKL=OFF -DENABLE_ARMPL=OFF -DENABLE_PLUGINS=OFF \
      -DENABLE_WERROR=OFF \
      -DENABLE_CUDA=${OCUDU_ENABLE_CUDA} \
  && cmake --build /work/ocudu/build --parallel ${OCUDU_JOBS} --target \
      gnb ocudu-dappctl ocudu-dapp-preflight ocudu-dapp-package ocudu-pusch-replay \
      dapp_runtime_test e3ap_test_server \
  && cmake --install /work/ocudu/build --prefix /opt/ocudu --component dapp_sdk \
  && ln -sf /work/ocudu/build/apps/gnb/gnb /usr/local/bin/gnb

# Host gate: the dApp runtime and the E3 codecs, before anything is packaged.
# The seccomp negative case cannot run under Docker's own seccomp filter.
#
# A CUDA build cannot run these here: the binaries link libcuda.so.1, which the
# container runtime injects only at run time with --gpus, so an image build has
# no driver. Upstream defers its GPU gates for the same reason. Run them after
# the build instead, with the GPU attached:
#
#   docker compose -f demo/docker-compose.yml -f demo/docker-compose.cuda.yml \
#     --profile gates run --rm gates
RUN if [ "${OCUDU_ENABLE_CUDA}" = "ON" ]; then \
      echo "CUDA build: gates deferred to the gates service (needs a GPU)"; \
    else \
      cd /work/ocudu/build \
      && ./tests/unittests/dapp/dapp_runtime_test \
           --gtest_filter=-dapp_class_c_process_supervisor.requires_seccomp_filter_before_route_admission_when_configured \
      && OCUDU_E3_SCHEMA_DIR=/work/ocudu/schemas/e3 python3 /work/ocudu/python/tests/test_e3ap_client.py \
           --server /work/ocudu/build/tests/unittests/dapp/e3ap_test_server; \
    fi

# ---------------------------------------------------------------------------
FROM ocudu-host AS dapp-sdk

ARG OCUDU_JOBS=8
ARG OCUDU_ENABLE_CUDA=OFF
ARG OCUDU_CUDA_ARCHITECTURES=89-real

COPY ocudu-dapp-sdk /work/ocudu-dapp-sdk
RUN --mount=type=cache,id=ocudu-demo-sdk-ccache,target=/root/.cache/ccache \
    cmake -S /work/ocudu-dapp-sdk -B /work/ocudu-dapp-sdk/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache \
      -DCMAKE_PREFIX_PATH=/opt/ocudu \
      "-DCMAKE_CUDA_ARCHITECTURES=${OCUDU_CUDA_ARCHITECTURES}" \
      -DOCUDU_DAPP_BUILD_CUDA_EXAMPLES=${OCUDU_ENABLE_CUDA} \
      -DOCUDU_DAPP_BUILD_PYTHON_CLASS_C=OFF \
      -DOCUDU_DAPP_REF_EXTRAS=ON \
  && cmake --build /work/ocudu-dapp-sdk/build --parallel ${OCUDU_JOBS} \
  && cmake --install /work/ocudu-dapp-sdk/build --prefix /opt/ocudu

# ---------------------------------------------------------------------------
FROM dapp-sdk AS release

# ethtool for scripts/veth-sctp-crc-off.sh (SCTP CRC offload workaround on
# old kernels - see the script). Tiny; installed here so the release layer
# is the only one that changes.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ethtool \
  && rm -rf /var/lib/apt/lists/*
# From a NAMED context, not a path under the build context. The build
# context is the workspace root, so a literal "demo/..." here breaks the
# moment this directory is called anything else - which it is in the staged
# public copy. The named context is wired to this directory in compose.
COPY --from=demo scripts/veth-sctp-crc-off.sh /usr/local/bin/veth-sctp-crc-off

# The dapp_sdk install component ships the packaging tools but not the two
# runtime binaries, so place them on a stable path: the gNB YAML names the
# preflight helper absolutely, and it must not be group/other-writable.
RUN install -m 0755 -o root -g root \
      /work/ocudu/build/apps/tools/dapp_preflight/ocudu-dapp-preflight \
      /opt/ocudu/bin/ocudu-dapp-preflight \
  && install -m 0755 -o root -g root \
      /work/ocudu/build/apps/tools/dappctl/ocudu-dappctl \
      /opt/ocudu/bin/ocudu-dappctl \
  && ln -sf /opt/ocudu/bin/ocudu-dappctl /usr/local/bin/ocudu-dappctl

# Catalog the demo gNB YAML points at, plus the runtime socket directory.
RUN mkdir -p /opt/ocudu/dapps /run/ocudu \
  && cp /work/ocudu-dapp-sdk/build/ref_*.so /opt/ocudu/dapps/ 2>/dev/null || true \
  && cp /work/ocudu-dapp-sdk/build/*.manifest.json /opt/ocudu/dapps/ 2>/dev/null || true \
  && cp /work/ocudu-dapp-sdk/build/*.spdx.json /opt/ocudu/dapps/ 2>/dev/null || true \
  && ls -la /opt/ocudu/dapps/

ENV OCUDU_E3_SCHEMA_DIR=/work/ocudu/schemas/e3 \
    OCUDU_E3_PYTHON_DIR=/work/ocudu/python \
    OCUDU_DAPP_SDK_BUILD=/work/ocudu-dapp-sdk/build \
    PYTHONPATH=/work/ocudu/python

WORKDIR /work
CMD ["/bin/bash"]
