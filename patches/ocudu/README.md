<!-- SPDX-FileCopyrightText: Copyright (C) 2026 DeepSig Inc. -->
<!-- SPDX-License-Identifier: BSD-3-Clause-Clear -->
# Patches against the OCUDU dApp platform

`bootstrap.sh` clones
[ocudu-dapp-platform](https://gitlab.com/ocudu/work_groups/wg2_ai_ran/ocudu-dapp-platform)
at `bc7eaab391ab875a6e67f1ee57bff387a1dbfc5f` (`OCUDU_BASE`) and applies these
onto a local branch `demo-patched`. Both affect only the CUDA PRACH detector.

- **`0001-phy-cuda-warm-up-the-GPU-PRACH-detector-at-construct.patch`** — builds
  the GPU PRACH detector's VkFFT plan when the detector is created instead of on
  its first detection, so the NVRTC compile does not stall the PHY inside a slot
  deadline. Compiled kernels are cached in `$OCUDU_PRACH_VKFFT_CACHE_DIR`
  (default `/tmp/ocudu-prach-vkfft`); set `OCUDU_PRACH_ACCELERATION_WARMUP=0` to
  disable the warm-up.
- **`0002-phy-cuda-apply-prach_th_correction_factor-in-the-acc.patch`** — makes
  the CUDA detector honour `expert_phy.prach_th_correction_factor`, as the CPU
  detector already does.
