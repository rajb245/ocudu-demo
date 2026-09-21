#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (C) 2026 DeepSig Inc.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Lay out the workspace this demo expects, on a fresh machine.
#
#   git clone https://github.com/rajb245/ocudu-demo.git demo && demo/bootstrap.sh
#
# Any directory name works - DEMO_DIR in .env is set from it below - but the
# README's commands are written for "demo", so clone into that.
#
# Afterwards the workspace holds, side by side:
#
#   ocudu/                  the gNB: dApp runtime, E3 plane, CUDA L1.
#                           Public wg2 platform, pinned, + patches/ocudu here.
#   ocudu-dapp-sdk/         reference dApp packages built against that host
#   <this directory>/       Dockerfile, compose, configs. Named demo/ in the
#                           working repo and demo-public/ in the staged copy;
#                           the script uses whatever it is actually called.
#
# Then: cd <workspace> && docker compose -f <this directory>/docker-compose.yml up -d
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# What this directory is actually called. The public copy is staged as
# demo-public/, so nothing user-facing may assume the name "demo".
self="$(basename "${here}")"

# The gNB is the public OCUDU WG2 dApp platform at a pinned commit, plus the
# patches in patches/ocudu next to this script. That base already carries the
# CUDA L1 (PRACH,
# SRS, PUSCH, PDSCH) and the dApp/E3 runtime; the patches are the two PRACH
# fixes this demo found over the air and has not upstreamed yet:
#
#   0001  warm the GPU PRACH detector at construction (VkFFT NVRTC JIT on the
#         first detection stalls the shared PHY workers ~1 s into the run;
#         also caches the compiled kernels on disk)
#   0002  honour expert_phy.prach_th_correction_factor in the CUDA detector
#         (the CPU detector scales the threshold, the GPU one silently did not,
#         so the accelerated path reverted the OTA false-alarm fix)
#
# Pinned, not a branch, because a patch is only valid against the tree it was
# generated from. To move the pin: check out the new upstream commit, run
# "git am -3" over the patches, fix anything that conflicts, re-export with
# "git format-patch -o patches/ocudu <new base>", and update OCUDU_BASE here.
OCUDU_BASE="bc7eaab391ab875a6e67f1ee57bff387a1dbfc5f"
OCUDU_BRANCH="demo-patched"

# Every ref is a commit, not a branch. The SDK builds against the platform's
# headers, and its main tracks the platform's main TIP, not this pin: on
# 2026-09-20 it started using equalized_symbols in ocudu_dapp_receiver_metrics_v1
# and the gnb image stopped compiling against OCUDU_BASE. These three commits
# are the set the demo was built and measured with. Move them together.
SDK_BASE="c38255585991ad7005737a4308cd433dee5bcfea"        # 2026-09-02
GRDAPP_BASE="079cf7189173f9b75090b4736f6a68c1bd8bba0f"     # 2026-09-01

# repo dir | clone URL | ref | patch dir (optional, relative to this script)
repos=(
  "ocudu|https://gitlab.com/ocudu/work_groups/wg2_ai_ran/ocudu-dapp-platform.git|${OCUDU_BASE}|patches/ocudu"
  "ocudu-dapp-sdk|https://gitlab.com/ocudu/work_groups/wg2_ai_ran/ocudu-dapp-sdk.git|${SDK_BASE}|"
  "ocudu-dapp-gnuradio|https://github.com/rajb245/ocudu-dapp-gnuradio.git|${GRDAPP_BASE}|"
)

# Put <dir> on OCUDU_BRANCH = <ref> + every patch in <patchdir>, and leave it
# alone if it is already there. Never discards local work: a dirty tree or a
# branch that has moved on is reported, not reset.
apply_patches() { # dir | ref | patchdir
  local dir="$1" ref="$2" patchdir="$3"
  local repo="${root}/${dir}" pd="${here}/${patchdir}"
  local -a patches
  mapfile -t patches < <(ls -1 "${pd}"/*.patch 2>/dev/null || true)
  if (( ${#patches[@]} == 0 )); then
    echo "   no patches in ${patchdir}; leaving ${dir} at ${ref:0:10}"
    return 0
  fi

  if git -C "${repo}" rev-parse --verify --quiet "refs/heads/${OCUDU_BRANCH}" >/dev/null; then
    local have
    have="$(git -C "${repo}" rev-list --count "${ref}..${OCUDU_BRANCH}" 2>/dev/null || echo -1)"
    if [[ "${have}" == "${#patches[@]}" ]]; then
      git -C "${repo}" checkout --quiet "${OCUDU_BRANCH}"
      echo "   ${OCUDU_BRANCH} already = ${ref:0:10} + ${#patches[@]} patches"
      return 0
    fi
    echo "   WARN  ${OCUDU_BRANCH} is ${have} commits past ${ref:0:10}, expected ${#patches[@]}."
    echo "         Not touching it. To rebuild it from scratch:"
    echo "           git -C ${repo} checkout ${ref} && git -C ${repo} branch -D ${OCUDU_BRANCH}"
    echo "         then re-run this script."
    return 0
  fi

  if [[ -n "$(git -C "${repo}" status --porcelain)" ]]; then
    echo "   WARN  ${dir} has uncommitted changes; not applying patches."
    return 0
  fi

  echo "   ${OCUDU_BRANCH} = ${ref:0:10} + ${#patches[@]} patches"
  git -C "${repo}" checkout --quiet -B "${OCUDU_BRANCH}" "${ref}"
  # -3 so the patches still apply once upstream has moved the surrounding
  # lines; a real conflict stops here rather than half-patching the tree.
  if ! git -C "${repo}" am -3 --quiet "${patches[@]}"; then
    git -C "${repo}" am --abort >/dev/null 2>&1 || true
    echo "   PATCHES DO NOT APPLY to ${ref:0:10}. The pin and ${patchdir} disagree." >&2
    return 1
  fi
}

for entry in "${repos[@]}"; do
  IFS='|' read -r dir url ref patchdir <<<"${entry}"
  if [[ -d "${root}/${dir}/.git" ]]; then
    # An already-present repo must not be able to abort the run: a failed
    # fetch (no network, no forwarded agent) should still leave you with the
    # existing checkout and the host checks below.
    echo "== ${dir}: present, fetching ${ref:0:10}"
    if ! git -C "${root}/${dir}" fetch --quiet origin "${ref}" 2>/dev/null; then
      # A pinned sha is usually already in the object store; only a moved
      # branch really needs the network.
      git -C "${root}/${dir}" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null \
        || echo "   fetch failed and ${ref:0:10} is not local; keeping the existing checkout"
    fi
    if [[ -n "${patchdir}" ]]; then
      apply_patches "${dir}" "${ref}" "${patchdir}"
    else
      git -C "${root}/${dir}" checkout --quiet "${ref}" || \
        echo "   could not check out ${ref}; leaving the working tree as it is"
    fi
  else
    echo "== ${dir}: cloning ${ref:0:10}"
    if [[ -n "${patchdir}" ]]; then
      # Full clone, not --branch: the pin is a commit, and the patches need
      # real history to three-way merge against.
      git clone --quiet "${url}" "${root}/${dir}"
      apply_patches "${dir}" "${ref}" "${patchdir}"
    else
      # Not --branch: the ref is a commit, and --branch only takes branch or
      # tag names. A detached checkout is what we want here.
      git clone --quiet "${url}" "${root}/${dir}"
      git -C "${root}/${dir}" checkout --quiet "${ref}"
    fi
  fi
done

# The gNB and gr-dapp images build with the WORKSPACE as their context, so
# compose must name this directory to find the Dockerfiles in it. That name is
# not fixed - the public copy is staged as demo-public/ - so keep .env honest
# rather than making the reader discover it as "lstat .../demo: no such file".
envfile="${here}/.env"
have_dir="$(sed -n 's/^DEMO_DIR=//p' "${envfile}" 2>/dev/null | head -1)"
if [[ ! -f "${envfile}" ]]; then
  :
elif [[ -z "${have_dir}" ]]; then
  printf 'DEMO_DIR=%s\n' "${self}" >> "${envfile}"
  echo "== set DEMO_DIR=${self} in ${self}/.env"
elif [[ "${have_dir}" != "${self}" ]]; then
  sed -i "s|^DEMO_DIR=.*|DEMO_DIR=${self}|" "${envfile}"
  echo "== set DEMO_DIR=${self} in ${self}/.env (was ${have_dir})"
fi

echo
echo "== host checks"
fail=0
# Returns 1 on failure so a caller can branch on it. The script runs under
# set -e, so any call that does NOT branch must swallow that with "|| true",
# or one missing prerequisite aborts the run instead of reporting all of them.
check() { # name | command
  if eval "$2" >/dev/null 2>&1; then
    printf '   ok      %s\n' "$1"
  else
    printf '   MISSING %s\n' "$1"
    fail=1
    return 1
  fi
}
docker_fail=0
plugin_fail=0
check "docker"                 "docker version"         || docker_fail=1
check "docker compose v2"      "docker compose version" || plugin_fail=1
check "docker buildx"          "docker buildx version"  || plugin_fail=1

# Of those three only "docker version" talks to the daemon, so a MISSING there
# with the CLI present is the daemon being down or this user not being in the
# docker group - not a missing package. The two plugin checks run entirely
# locally, so when they fail the plugin really is absent.
if (( docker_fail )) && command -v docker >/dev/null 2>&1; then
  printf '           docker is installed but the daemon did not answer: either it\n'
  printf '           is not running (sudo systemctl start docker), or this user is\n'
  printf '           not in the docker group (sudo usermod -aG docker "$USER",\n'
  printf '           then log out and back in).\n'
fi
# Only recommend installing when something really is not installed: a docker
# that is present but unreachable is the case above, and apt will not fix it.
if (( plugin_fail )) || { (( docker_fail )) && ! command -v docker >/dev/null 2>&1; }; then
  cat <<'HINT'
           On Ubuntu, install Engine + Compose v2 + buildx from Docker's own apt
           repo. The distro packages will not do: docker.io ships neither plugin,
           and the "docker-compose" package is the old Python v1, which cannot
           read the compose files here (they use additional_contexts).

             sudo apt-get install -y ca-certificates curl
             sudo install -m0755 -d /etc/apt/keyrings
             sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
               -o /etc/apt/keyrings/docker.asc
             echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
               https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
               | sudo tee /etc/apt/sources.list.d/docker.list
             sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli \
               containerd.io docker-buildx-plugin docker-compose-plugin
             sudo usermod -aG docker "$USER"      # then log out and back in

           Other distros carry the same packages under dnf/pacman.
HINT
fi

# Only demand a git key if something in the table above actually needs one.
# As of 2026-09-19 nothing does: every repo clones over https, so bootstrap
# needs no credentials at all. The check stays because putting a private repo
# back is then a one-line change and this re-arms itself.
ssh_repos=()
for entry in "${repos[@]}"; do
  IFS='|' read -r dir url _ _ <<<"${entry}"
  [[ "${url}" == git@* || "${url}" == ssh://* ]] && ssh_repos+=("${dir}")
done
if (( ${#ssh_repos[@]} )); then
  check "ssh access to gitlab"   "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@gitlab.com 2>&1 | grep -q Welcome" || true
  printf '           needed by: %s\n' "${ssh_repos[*]}"
else
  printf '   --      no git credentials needed; every repo above clones over https\n'
fi
# SCTP carries NGAP, E3AP and E3DP. "Available" is not enough - the host
# module must actually be loaded before the stack is started.
# Read /proc/modules rather than piping lsmod into grep -q: -q exits on the
# first match, lsmod takes SIGPIPE, and pipefail then reports the pipeline as
# failed precisely when the module IS loaded.
if grep -q '^sctp ' /proc/modules; then
  printf '   ok      sctp kernel module (loaded)\n'
elif modinfo sctp >/dev/null 2>&1; then
  printf '   WARN    sctp available but NOT loaded - NGAP/E3AP will fail.\n'
  printf '           sudo modprobe sctp && echo sctp | sudo tee /etc/modules-load.d/sctp.conf\n'
  fail=1
else
  printf '   MISSING sctp kernel module\n'
  fail=1
fi
check "/dev/net/tun"           "test -c /dev/net/tun" || true

# The CUDA overlay only; the CPU stack needs none of this. cuda_ok gates which
# build the closing banner leads with: recommending a CPU build on a box with a
# working GPU sends people down the slow path by default.
cuda_ok=0
gpu_present=0
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_present=1
  printf '   ok      nvidia-smi (%s)\n' "$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  # Only meaningful once the daemon answers: with docker down this fails for
  # that reason and a toolkit recipe would send the reader the wrong way.
  if (( docker_fail )); then
    printf '   --      gpu visible to docker: not checked, docker is not answering\n'
  elif check "gpu visible to docker" "docker run --rm --gpus all ubuntu:24.04 true"; then
    cuda_ok=1
  else
    # nvidia-smi already succeeded above, so the DRIVER is fine and the piece
    # that bridges it into containers is what is missing. They are separate
    # packages, which is why a working nvidia-smi is not evidence either way.
    cat <<'GPUHINT'
           nvidia-smi works, so the driver is fine - it is the NVIDIA Container
           Toolkit that is missing. Docker reports this as "failed to discover
           GPU vendor from CDI: no known GPU vendor found".

             curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
               | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
             curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
               | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
               | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
             sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
             sudo nvidia-ctk runtime configure --runtime=docker
             sudo systemctl restart docker

           Needed only for the CUDA overlay. The CPU and ZMQ stack runs without it.
GPUHINT
  fi
  driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
  major="${driver%%.*}"
  if (( major < 580 )); then
    printf '   WARN    driver %s predates r580; the CUDA 13 base image will not run.\n' "${driver}"
    printf '           Either update the driver or set OCUDU_CUDA_IMAGE to a CUDA 12.x devel tag.\n'
    cuda_ok=0
  fi

  # First guess at OCUDU_CUDA_ARCHITECTURES, from the GPU this machine has.
  # compute_cap is "12.0" on a 5090, "8.9" on Ada, "8.6" on an A10; CMake wants
  # it without the dot. The "-real" suffix emits SASS only (smaller image, no
  # PTX), which is what this demo builds for. Needs driver r510+ for the query.
  # Written into this directory's .env so it is visible and editable - inspect
  # it before a
  # long build, and set it by hand for a deployment GPU that is not this one.
  caps="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d ' ' | grep -E '^[0-9]+\.[0-9]+$' || true)"
  cap="$(printf '%s\n' "${caps}" | head -1 | tr -d .)"
  if [[ -z "${cap}" ]]; then
    printf '   WARN    driver cannot report compute_cap; leaving OCUDU_CUDA_ARCHITECTURES as is.\n'
  else
    if (( $(printf '%s\n' "${caps}" | sort -u | wc -l) > 1 )); then
      printf '   WARN    GPUs of differing compute capability (%s); using device 0.\n' \
             "$(printf '%s\n' "${caps}" | sort -u | tr '\n' ' ')"
      printf '           Match nvcuda_device_id in the gNB YAML to the card you build for.\n'
    fi
    want="${cap}-real"
    envfile="${here}/.env"
    have="$(sed -n 's/^OCUDU_CUDA_ARCHITECTURES=//p' "${envfile}" 2>/dev/null | head -1)"
    if [[ "${have}" == "${want}" ]]; then
      printf '   ok      OCUDU_CUDA_ARCHITECTURES=%s matches this GPU\n' "${want}"
    elif [[ -z "${have}" ]]; then
      printf '   WARN    no OCUDU_CUDA_ARCHITECTURES in %s; this GPU wants %s\n' "${envfile}" "${want}"
    else
      sed -i "s/^OCUDU_CUDA_ARCHITECTURES=.*/OCUDU_CUDA_ARCHITECTURES=${want}/" "${envfile}"
      printf '   ok      OCUDU_CUDA_ARCHITECTURES=%s (was %s) - set in %s/.env, inspect before building\n' \
             "${want}" "${have}" "${self}"
    fi
  fi
else
  printf '   --      no GPU here; CPU stack only (skip docker-compose.cuda.yml)\n'
fi

echo
if (( fail )); then
  echo "Some prerequisites are missing - see above." >&2
  exit 1
fi

echo
echo "Workspace ready at ${root}"
echo
if (( cuda_ok )); then
  # This box can run the accelerated L1, so lead with it. Both -f flags are
  # needed on EVERY command: the overlay alone has no command, no volumes and
  # no host networking, so compose starts the image's default shell and exits
  # 0 with no cell and no error.
  cat <<EOF
This box has a GPU docker can use, so build the CUDA image. Pass BOTH -f flags
every time - the overlay on its own starts a shell and exits, with no error.

  cd ${root}
  docker compose -f ${self}/docker-compose.yml -f ${self}/docker-compose.cuda.yml build gnb
  docker compose -f ${self}/docker-compose.yml -f ${self}/docker-compose.cuda.yml up -d
  docker compose -f ${self}/docker-compose.yml -f ${self}/docker-compose.cuda.yml --profile ui up -d

The first line takes ~20 min. OCUDU_CUDA_ARCHITECTURES was guessed from this
GPU above; check ${self}/.env before that build if you are targeting a
different card.

CPU build instead, if you specifically want it - no GPU, slower L1, same demo:

  docker compose -f ${self}/docker-compose.yml build gnb
  docker compose -f ${self}/docker-compose.yml up -d
EOF
else
  cat <<EOF
  cd ${root}
  docker compose -f ${self}/docker-compose.yml build gnb      # ~20 min
  docker compose -f ${self}/docker-compose.yml up -d          # core + cell + UE
  docker compose -f ${self}/docker-compose.yml --profile ui up -d   # + Grafana :3300
EOF
  if (( gpu_present )); then
    cat <<EOF

A GPU is present but the CUDA build is not offered: see the GPU line above.
Once docker can use it, re-run this script and it will give you the CUDA
commands instead.
EOF
  fi
fi
