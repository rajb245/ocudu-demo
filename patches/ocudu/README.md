<!-- SPDX-FileCopyrightText: Copyright (C) 2026 DeepSig Inc. -->
<!-- SPDX-License-Identifier: BSD-3-Clause-Clear -->
# Patches against the public OCUDU dApp platform

Base: `https://gitlab.com/ocudu/work_groups/wg2_ai_ran/ocudu-dapp-platform`
at **`bc7eaab391ab875a6e67f1ee57bff387a1dbfc5f`** — the pin is in
`bootstrap.sh` (`OCUDU_BASE`), which clones that commit and applies these
patches onto a local branch `demo-patched`. That base already carries the
dApp/E3 runtime and the CUDA L1 (PRACH, SRS, PUSCH, PDSCH); these two patches
are the PRACH fixes this demo found over the air and has not upstreamed yet.
Together they are 8 files, +247/−14.

## `0001-phy-cuda-warm-up-the-GPU-PRACH-detector-at-construct.patch`

With `expert_phy.prach_acceleration_mode: auto` the cell would stall about a
second into the run — on the radio, ~50 real-time failures and a dead cell.
Cause: VkFFT compiles its kernels with NVRTC at **plan init**, and the CUDA
PRACH detector built its plan on the **first detection**, i.e. on a shared
`main_pool` PHY worker inside a slot deadline. Five pooled detectors ×
15.6–53.5 ms of JIT is far past the budget.

The patch builds the plan at construction instead (`warm_up()`, driven by a new
`warmup_configuration{nof_rx_ports, long_format, zero_correlation_zone}` that
`factories.cpp` fills from the cell config), and caches the compiled kernels on
disk via VkFFT's `saveApplicationToString` / `loadApplicationFromString`. The
cache lives in `$OCUDU_PRACH_VKFFT_CACHE_DIR` (default `/tmp/ocudu-prach-vkfft`)
and is keyed by VkFFT version, CUDA runtime, compute capability, DFT size,
batch and thread count, so it is safe to carry between runs but not between
GPUs or toolkits.

Validated on `ru_dummy` (0 late slots with the warm-up, 41 with it disabled)
and over the air (0 real-time failures).

## `0002-phy-cuda-apply-prach_th_correction_factor-in-the-acc.patch`

`expert_phy.prach_th_correction_factor` raises the detection threshold; we need
`4.0` over the air because the `{format 0, ZCZ 0, 1 port}` entry in the
threshold table is the lowest in it (0.147) and is flagged unvalidated, so
thermal noise alone triggers detections. The **CPU** detector scaled the
threshold; the **CUDA** one took the raw table value and never saw the factor,
so turning PRACH acceleration on silently reverted the fix — with no UE
anywhere, the cell issued 23 RARs to 23 RNTIs in 3.5 minutes.

The patch plumbs `threshold_scaling` through the accelerated factory and
applies it in `compute_geometry()`, matching the CPU path:

```cpp
geometry.threshold = threshold * threshold_scaling;   // was: = threshold
```

Validated with the UE off: 0 RARs with the patch, 16 without.

## Moving the pin

A patch is only valid against the tree it was generated from, so the base is a
commit, not a branch. To move it:

```sh
cd ocudu
git fetch origin && git checkout -B demo-patched <new upstream commit>
git am -3 ../demo/patches/ocudu/*.patch          # fix any conflict, then --continue
git format-patch -o ../demo/patches/ocudu <new upstream commit>
```

then set `OCUDU_BASE` in `bootstrap.sh` to the new commit.
