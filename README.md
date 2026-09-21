<!-- SPDX-FileCopyrightText: Copyright (C) 2026 DeepSig Inc. -->
<!-- SPDX-License-Identifier: BSD-3-Clause-Clear -->
# OCUDU dApp/E3 demo — one cell, one UE, no radio

`docker compose up` brings up a complete 5G SA stack with no radio hardware:
Open5GS 5GC, the OCUDU gNB with the dApp runtime and the embedded E3
management/telemetry plane, and an OAI nrUE, joined by a ZeroMQ virtual radio.

```
 ocudu_demo_5gc        ocudu_demo_gnb                    oai_nr_ue
 Open5GS 5GC  <-NGAP-> OCUDU gNB          <--- ZMQ ---> OAI nrUE
 10.53.1.2            10.53.1.3                         10.53.1.4
                      | E3AP  sctp/36423                UE IP 10.45.1.2
                      | E3DP  sctp/38472
                      | ws    tcp/8001 -> telegraf -> InfluxDB -> Grafana :3300
```

Cell: TDD band n78, 20 MHz, 30 kHz SCS, PCI 1, PLMN 00101.

## Where this comes from

The gNB is the **public** WG2 platform
([`ocudu-dapp-platform`](https://gitlab.com/ocudu/work_groups/wg2_ai_ran/ocudu-dapp-platform)),
pinned to a commit and patched. That base carries the dApp/E3 runtime and the
CUDA L1; the two patches in `patches/ocudu` are the PRACH fixes this demo found
over the air and has not upstreamed — see `patches/ocudu/README.md`.
`bootstrap.sh` applies them onto a local branch `demo-patched`.

Everything around the gNB comes from the same place. The platform ships a
`docker/` tree — Open5GS, telegraf, InfluxDB provisioning and Grafana — which
this demo builds **unchanged** from `../ocudu/docker/…`. Those files began life
in srsRAN Project; that repository was archived in December 2025 when the
project became OCUDU, so the platform fork is now their public home.

`Dockerfile` follows the build recipe in
[`ocudu-dapp-quickstart`](https://gitlab.com/ocudu/work_groups/wg2_ai_ran/ocudu-dapp-quickstart) — the `asn1c` fork with `-gen-APER`,
`flatc`, an `asn1tools` venv, clang. That repo builds for real radios
(`ENABLE_ZEROMQ=OFF`, UHD/DPDK on) and ships no core and no UE, so `demo/` is
the join: its toolchain with the radio swapped for ZMQ, driving the platform's
core, and an OAI nrUE recipe of its own. It is a reference and not an input,
so `bootstrap.sh` does not clone it.

The UE is the one piece with no upstream to point at. `Dockerfile.oaiue` builds
the Duranta OAI fork (fetched by BuildKit as a remote context) for ZMQ and for
the USRP, and `configs/nrue_zmq.conf`, `configs/nrue_usrp_n78.conf` and
`configs/uecap_ports1.xml` live here.

## Prerequisites

Docker with **Compose v2 and buildx** (both are required — the compose files use
`additional_contexts`), the `sctp` kernel module, and `/dev/net/tun`.
`bootstrap.sh` clones the workspace and checks all of it. **No git
credentials are needed**: all three repos clone over https. `bootstrap.sh`
still knows how to demand a key, but only while some repo in its table uses an
`ssh://` or `git@` URL, so putting a private one back re-arms the check by
itself.

A proprietary Class-A neural receiver is demonstrated alongside this stack at
conference talks. It is not part of this repository and is not required: the
Class-A interface it plugs into is public, and `ocudu-dapp-sdk` ships a working
reference implementation of it.

## Quick start

```bash
mkdir <workspace> && cd <workspace>   # will hold demo/, ocudu/, ocudu-dapp-sdk/, ocudu-dapp-gnuradio/
git clone https://github.com/rajb245/ocudu-demo.git demo   # into "demo": every command below assumes that name
demo/bootstrap.sh                     # clone the other repos at their pinned refs, check the host

docker compose -f demo/docker-compose.yml build          # ~25 min cold
docker compose -f demo/docker-compose.yml up -d          # core + cell + UE
docker compose -f demo/docker-compose.yml --profile zmq --profile ui up -d  # + Grafana :3300
```

Another directory name works — `bootstrap.sh` sets `DEMO_DIR` in `.env` from
whatever it is called — but then substitute it for `demo/` in every command here.

The ZMQ cell and the USRP cell are **alternatives**, selected by profile:

| Command | Runs |
|---|---|
| `up -d` | 5GC + ZMQ gNB + OAI UE (`COMPOSE_PROFILES=zmq` in `.env`) |
| `--profile zmq --profile ui up -d` | the above plus Grafana |
| `--profile radio up -d` | 5GC + USRP gNB, **no UE** — see below |
| `--profile radio --profile ui up -d` | the above plus Grafana |

A CLI `--profile` replaces `COMPOSE_PROFILES` rather than adding to it, so
selecting `radio` drops the ZMQ pair automatically. Naming `ui` on its own
would likewise drop the cell, hence `--profile zmq --profile ui` above.

The UE takes ~30 s to sync, attach and bring up its tunnel. Watch for it:

```bash
docker logs -f oai_nr_ue | grep -E "Registration Accept|PDU Session|oaitun"
```

Expected, and verified on this stack:

```
Received Registration Accept with result 3GPP
Received PDU Session Establishment Accept, UE IPv4: 10.45.1.2
TUN Interface oaitun_ue1 successfully configured, IPv4 10.45.1.2
```

## Verify the cell carries traffic

```bash
docker exec oai_nr_ue ping -I oaitun_ue1 -c 8 10.45.1.1

docker exec -d ocudu_demo_5gc iperf3 -s -1 -p 5201
docker exec oai_nr_ue iperf3 -c 10.45.1.1 -B 10.45.1.2 -p 5201 -t 12
```

Measured here (12-core laptop, ZMQ virtual radio, everything on one host):
ping 42/61/92 ms min/avg/max, uplink iperf3 **5.7 Mbit/s**. These are properties
of the ZMQ loopback and a busy host, not of the RAN.

## Drive the E3 plane

Every client below also works from the host — against the gNB's bridge address
`10.53.1.3:36423` (`GNB_IP`). The published `127.0.0.1:36423` works on current
kernels; on the 5.4 host it times out (SCTP CRC through DNAT, see below).
Running them inside the gNB container just avoids installing `asn1tools`
locally.

```bash
E3() { docker exec ocudu_demo_gnb bash -c "cd /work/ocudu &&
  PYTHONPATH=/work/ocudu/python OCUDU_E3_SCHEMA_DIR=/work/ocudu/schemas/e3 $*"; }

# RAN functions and the eight telemetry streams
E3 'python3 -m ocudu_e3 --host 127.0.0.1 --port 36423 catalog'

# Catalog, instances, health, incidents
E3 'python3 apps/tools/dappctl/ocudu_dappctl.py --sctp 127.0.0.1:36423 inventory'
E3 'python3 apps/tools/dappctl/ocudu_dappctl.py --sctp 127.0.0.1:36423 health'
```

Six CPU reference packages are declared in the gNB YAML and appear in
`inventory` as `compatible: true`, `signatureStatus: unsignedPackage`:

```
org.ocudu.reference.channel-estimator.cpu   org.ocudu.reference.scheduler.cpu
org.ocudu.reference.equalizer.cpu           org.ocudu.reference.spectrum.cpu
org.ocudu.reference.receiver.cpu            org.ocudu.reference.srs-isac.cpu
```

Load and activate one while the cell is on the air. `--package` takes the
**package UUID** from `inventory`, not the manifest filename:

```bash
DAPPCTL='python3 apps/tools/dappctl/ocudu_dappctl.py --sctp 127.0.0.1:36423'
E3 "$DAPPCTL load --package 8f0d0001-4f9c-4e31-8c00-000000000001 \
      --placement in-process --backend cpu"
E3 "$DAPPCTL jobs list"          # mutations are async jobs; check the result

# then, carrying the instance id from `inventory`:
for step in prepare arm shadow activate; do
  E3 "$DAPPCTL lifecycle $step --instance <instanceId>"
done
```

Verified path: `loaded -> prepared -> armed -> shadow -> active`, with `health`
reporting zero fallbacks, deadline misses and incidents under uplink traffic.

### GNU Radio on the live uplink grid

`gr-dapp` (profile `zmq`; `gr-dapp-usrp` on the radio profile) is a plain
Python process from
[ocudu-dapp-gnuradio](https://github.com/rajb245/ocudu-dapp-gnuradio)
that subscribes to `classc.spectrum` over E3AP and pushes each snapshot of the
gNB's **frequency-domain uplink resource grid** — `(rx_ports, 14 symbols,
subcarriers)` complex64, one per captured slot — through GNU Radio 3.10 blocks.
Nothing is loaded into the gNB for this: the portable E3 spectrum route exists
whenever `e3ap_sctp` is configured and goes live when a subscriber attaches; the
reference spectrum dApp in the catalog does not need to be activated.

It starts with the stack and prints one JSON object per (slot, PRB) that clears
the threshold above the per-snapshot median floor:

```bash
docker compose logs -f gr-dapp
{"sfn": 296, "slot": 9, "prb": 7, "freq_mhz": 3482.94, "avg_db": -98.79, "floor_db": -120.0, "margin_db": 21.21}
```

`GRDAPP_SCRIPT=fsk_demod_dapp.py` swaps in the in-band 2-FSK demodulator and
`GRDAPP_ARGS` passes options through (`--threshold-db`, `--avg`, `--maximum`,
`--f0-prb/--f1-prb`, `--sps`). Both scripts have a `--selftest` on synthetic
grids, which the image runs at build time. The image (`Dockerfile.grdapp`)
takes `ocudu_e3` and the E3 schemas from the gNB source tree so the codec
always matches the gNB that is publishing.

Validated on both cells: the ZMQ stack (first detections 20 s after
`up -d`) and over the air on the X310 (`gr-dapp-usrp`, ~1,900 detections in
the first 30 s with the B200mini UE attached; the floor there is the X310's
real noise floor, about -65 dB, and the DC PRB at the carrier centre shows
up permanently - ignore PRB 25 on the 20 MHz cell).

## Split-8 on a real USRP

UHD is compiled in (`ENABLE_UHD=ON`) alongside ZeroMQ — one image serves both
the virtual-radio demo and a real front end; `ru_sdr.device_driver` in the gNB
YAML picks. DPDK stays off; there is no split-7.2 fronthaul here.

**Validated over the air** (2026-09-14 → 18): Ettus X310 + UBX-160 gNB on the
box, OAI nrUE on a B200mini on the laptop, ~1 m apart, both on an OctoClock
10 MHz. Attach in ~10 s, PDU session, ping ~30 ms, **DL 19.0 / UL 7.9 Mb/s** TCP,
0 real-time failures with PRACH and SRS accelerated on the GPU. Every setting that had to change to get
there is already in `configs/gnb_rf_x310_tdd_n78_20mhz_dapp.yml`, with the
reasoning in its comments.

```bash
# gNB host (CUDA image; drop the cuda overlay for the CPU build)
docker compose -f docker-compose.yml -f docker-compose.cuda.yml --profile radio up -d   # 5gc, gnb-usrp, gr-dapp-usrp
# UE host (may be another machine; joined by RF only) - see docker-compose.ue.yml header for the one-off UHD images step
UE_EXTRA_ARGS="--clock-source 1" docker compose -f docker-compose.ue.yml up -d
docker logs -f oai_nr_ue_usrp | grep -aE "RA procedure succeeded|Registration Accept|oaitun_ue1 successfully"
```

`gnb-usrp` runs `configs/gnb_rf_x310_tdd_n78_20mhz_dapp.yml` on host networking
with `rtprio`/`memlock` raised; `docker-compose.ue.yml` is a separate compose
project that passes the B200mini through (`/dev/bus/usb`, device-cgroup
`c 189:* rmw`, bind-mounted UHD images). Bring both down when the cell is not
being shown (experimental licence).

What the config encodes, and why (details and evidence in the doc):

- **Radio**: `master_clock_rate=184.32e6` (23.04 MS/s must divide it; a missing
  MCR also fakes a 37 kHz CFO in measurements), 10 GbE on the HG image's SFP+
  **port 1**, FPGA compat 39 for UHD 4.6, `clock: external` from the OctoClock,
  `tx_mode: continuous` (discontinuous was 20 dB worse on the uplink).
- **Gains are measured, not placeholders**: `tx_gain 12`, `rx_gain 11` for a UE
  at 1 m. Both were found by lowering — the gNB overdrives its own receiver
  (rx) and its own PDSCH desenses it under downlink load (tx). Judge `pusch` in
  the metrics table *during* a DL iperf, not idle. UBX-160 range is 0–31.5 on
  both; the upstream B200 numbers (80/40) are a different scale.
- **PRACH**: format 0 (`prach_config_index: 7`) — short format B4 was never
  detected over the air; `prach_th_correction_factor: 4.0` silences the
  format-0 false alarms (RARs sent with the UE switched off);
  `preamble_rx_target_pw: -80`; `zero_correlation_zone` left at 0 (the only
  value that matched preambles in the sweep).
- **Msg3**: `time_alignment_calibration: 128` samples is the only value that
  attaches; it is X310/UBX-specific.
- **UE**: `--ue-rxgain` carries a per-device offset (45.25 dB here) and
  `--ue-txgain` is an *attenuation*; `--continuous-tx` for TDD on apt UHD;
  antennas on **both** TX/RX and RX2.
- **Host prep** on the gNB side stays on the host: the `usrp-10g` static
  address, `/etc/sysctl.d/90-usrp.conf` (62914560), no UHD install needed
  (probe from inside the image).

Attach is **stochastic**: most 2–4-minute windows attach on the first try,
some never do — restart the UE, not the gNB. A UE further than the bench needs
the two gains re-swept (raise, watching `pusch` under load).

## CUDA

The CPU and CUDA images are the same build stages with a different
`BASE_IMAGE`, so a machine only ever builds the variant it will run.

```bash
# set OCUDU_CUDA_ARCHITECTURES in demo/.env for the deployment GPU first
docker compose -f demo/docker-compose.yml -f demo/docker-compose.cuda.yml up -d
```

| GPU | `OCUDU_CUDA_ARCHITECTURES` |
|---|---|
| RTX 5090 (Blackwell) | `120-real` |
| RTX 4090 / RTX 6000 Ada | `89-real` |
| H100 / GH200 | `90-real` |
| DGX Spark (GB10) | `121` |

Note `121` is GB10, **not** the 5090 — it is the quickstart recipe's default,
so it is an easy wrong pick. A CUDA 13 base image also needs an **r580+** host driver.

`OCUDU_MARCH` defaults to `x86-64-v3` so an image built on one box runs on
another. On a dedicated host, rebuild with `native`.

## Things that will bite you

Each of these cost a debugging cycle here; they are all fixed in the committed
files, but they are worth knowing when you change something.

**`init: true` on the gNB is load-bearing.** The native preflight helper calls
`getppid()` and refuses to harden if its parent is PID 1 — a guard against
having been reparented to init. The gNB *is* PID 1 in a container unless an
init process is present, so without it **every** dApp load fails with
`native preflight helper rejected the module at sandbox setup failed (exit 10)`.
Nothing in the message points at PID 1. Docker's default seccomp profile is
*not* the problem and does not need lifting.

**`minimum_trust_policy_epoch: 0` is mandatory for an unsigned lab catalog.**
It defaults to `1`, and the validator rejects a nonzero epoch when no trust
store is set — so `package_signature_mode: allow_unsigned` alone gives
`Required dApp package signatures need an absolute trust store and nonzero
minimum epoch` and the gNB exits. The documented lab snippet omits this.

**A crashed gNB leaves its dApp socket behind.** Restarting the *same*
container after a gNB crash fails with `Unable to create dApp service: local
management socket path already exists` (`/run/ocudu/dapp-management.sock`
survives in the container filesystem). Both gNB services now `rm -f` it before
starting. Related: on the X310 the gNB occasionally segfaults in
`lower_phy_rx#0` within a second of `==== gNB started ===`; every crashed run so
far also logged UHD's `[RFNOC::GRAPH] One or more blocks timed out during
flush!` during X300 init, and a plain `up -d --force-recreate` has always come
up clean on the next try.

**CUDA acceleration on a real radio: the stall is VkFFT's NVRTC compile on the
PRACH path.** Diagnosed with `ru_dummy` (no radio). The GPU PRACH detector
is pooled; each instance compiles its IDFT kernel with NVRTC on its *first*
detection, on a shared `main_pool` worker that also runs the DU slot chain:
15–54 ms per instance, five instances, all at the first PRACH occasions →
a burst of late DL_TTI/UL_TTI requests that a USRP cannot survive (a virtual
radio waits, which is why ZMQ never showed it). Steady-state detection is
~30 µs. PUSCH/SRS/PDSCH acceleration alone are clean. **Fixed** by
`patches/ocudu/0001` (warm-up at detector construction + on-disk VkFFT kernel
cache): 0 late slots in every accelerated `ru_dummy` arm, the burst returns
with `OCUDU_PRACH_ACCELERATION_WARMUP=0`. `bootstrap.sh` applies it over the
pinned public platform commit. **Confirmed
over the air** (X310, same session, one arm each): 0 real-time failures with
every knob on `auto`; the tracked X310 config now runs PRACH and SRS
acceleration (DL 19.0 / UL 7.9 Mb/s) and keeps PUSCH on the host, because the
GPU PUSCH path reports ~9 dB pessimistic SINR (5.8 vs 14–16 dB), so link
adaptation parks UL MCS at 0–3 and UL TCP drops 6.8 → ~1–2 Mb/s at 0–2 % BLER;
traced to the accelerated path's SINR estimator, parked. Remaining start-up
transient: the lower-PHY GPU
PRACH demodulator builds its FFT plan on first use, so ~14 PRACH requests are
dropped in the first 200 ms. Unrelated but costly: the accelerated build
pre-allocates 16 worst-case GPU LDPC decoders (~1.7 GB each, 27.7 GB total) for
a 20 MHz cell, which is why it needs a 32 GB card.

**Over-the-air attach is stochastic.** Same config, same bench: most 2–4 min
windows attach in ~10 s, a few never do. `down`/`up` the UE container only; the
gNB is fine. Budget a retry in any run-of-show.

**Restart the ZMQ pair together.** `docker compose restart gnb` (or restarting
just the UE) leaves the ZMQ REQ/REP streams desynchronised — both sides sit in
`Waiting for data` forever with no error. Use `down` then `up -d`.

**A cell at `dmrs_additional_position: 1` needs the patched UE.** TS 38.214
6.2.2 has the UE assume the *default* pos2 for a PUSCH scheduled by DCI 0_0;
OAI's nrUE applies the dedicated value for every DCI format. Invisible at the
pos2 default, a hard attach failure at pos1: the gNB's fallback scheduler builds
msg5's grant with the common DM-RS info, msg5 never decodes, RLC hits max
retransmissions and the UE loops through random access (measured here: no attach
in 170 s, versus 10 s with the patch). `patches/oai/0001-…` is applied in the
`builder-usrp` stage of `Dockerfile.oaiue`. It only matters for a cell that
sets `dmrs_additional_position: 1`; the shipped X310 cell runs the pos2
default either way.

**The OAI UE needs its build directory on the library path.** `nr-uesoftmodem`
`dlopen()`s `libparams_libconfig.so` by bare name; without `LD_LIBRARY_PATH` it
dies with SIGSEGV (exit 139) after printing a config-module error.

**SCTP between containers silently fails on old kernels.** On Ubuntu 20.04
(5.4) veth advertises SCTP CRC offload, so the gNB's E3AP INIT-ACKs leave with
an uncomputed CRC32c and every E3 client in another container times out on
connect while its namespace counts `SctpChecksumErrors`; the NGAP association
to the core and the tiny ABORT to a closed port both get through, which makes
it look like anything but a checksum problem. The gNB container now runs
`scripts/veth-sctp-crc-off.sh` (`ethtool -K ethN tx-checksum-sctp off`, needs
`NET_ADMIN`) before starting. Kernel 7.0 on the box does not have the bug.

## Files

| File | Role |
|---|---|
| `Dockerfile` | gNB image: toolchain (asn1c APER fork, flatc, venv), host build, SDK, catalog. CPU/CUDA via `BASE_IMAGE` |
| `Dockerfile.grdapp` | GNU Radio 3.10 + `ocudu_e3` client: the Class-C observer dApps, self-tested at build |
| `Dockerfile.oaiue` | OAI nrUE, ZMQ and USRP variants, plus a tools layer; the two builds share a deps stage so only the compile repeats |
| `docker-compose.yml` | 5GC, gNB, OAI nrUE, GNU Radio dApp; `ui` profile for telegraf/InfluxDB/Grafana |
| `docker-compose.cuda.yml` | CUDA overlay: CUDA base image, `ENABLE_CUDA=ON`, GPU reservation |
| `configs/gnb_zmq_*_dapp.yml` | the ZMQ demo cell: `dapp:` block, E3AP/E3DP, metrics websocket |
| `configs/gnb_rf_x310_*_dapp.yml` | split-8 cell on an Ettus X310, tuned over the air against a B200mini OAI UE |
| `scripts/veth-sctp-crc-off.sh` | SCTP CRC offload workaround the ZMQ gNB runs at start (old kernels) |
| `scripts/up`, `scripts/down` | bring the over-the-air cell up and down (both compose files, `radio` profile) |
| `scripts/check` | one verdict line on cell health: started, activated, deadlines, radio, SCTP, dApp |
| `scripts/up_e3`, `scripts/down_e3` | start and stop the live E3 spectrum stream without touching the cell |
| `scripts/up_ue`, `scripts/down_ue` | the over-the-air UE, **on the UE host**; `up_ue` defaults to the external 10 MHz reference and reports where the attach got to |
| `configs/nrue_zmq.conf`, `configs/uecap_ports1.xml` | OAI nrUE over ZMQ, and the UE capability set both UEs use |
| `patches/ocudu/` | the two PRACH fixes applied over the pinned public platform commit |
| `bootstrap.sh` | clone the workspace at pinned refs, check host prerequisites, guess `OCUDU_CUDA_ARCHITECTURES` from the local GPU |
| `.env` | build parallelism, `MARCH`, CUDA arch, RAN addressing; compose-side substitutions |
| `metrics.env` | container-side environment for telegraf, InfluxDB and Grafana |

## Licence

This repository is under **The Clear BSD License** (`BSD-3-Clause-Clear`), the
same licence as [ocudu-dapp-gnuradio](https://github.com/rajb245/ocudu-dapp-gnuradio).
See `LICENSE`.

Three things in here are not ours and keep their own terms. Full texts of every
identifier used are in `LICENSES/`.

| | licence | why |
|---|---|---|
| everything not listed below | `BSD-3-Clause-Clear` | original work, © DeepSig Inc. |
| `patches/ocudu/*` | `BSD-3-Clause-Open-MPI` | modifications to the OCUDU platform, which is under that licence; the files they touch are © DeepSig and © Software Radio Systems |
| `docker-compose.yml`, `.env`, `metrics.env` | `BSD-3-Clause-Open-MPI` | the 5GC and metrics services derive from the platform's `docker/` tree, © Software Radio Systems |
| `patches/oai/*`, `configs/nrue_zmq.conf`, `configs/uecap_ports1.xml` | `LicenseRef-CSSL-1.0` | from OpenAirInterface, which is under the Collaborative Standards Software License v1.0. `uecap_ports1.xml` is verbatim upstream; `nrue_zmq.conf` derives from `ci-scripts/conf_files/nrue.uicc.conf` |

`Dockerfile` and `Dockerfile.dockerignore` follow the `ocudu-dapp-quickstart`
recipe, which is `BSD-3-Clause-Clear` and © DeepSig, so they carry the same
terms as the rest of this repository.
