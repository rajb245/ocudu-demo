<!-- SPDX-FileCopyrightText: Copyright (C) 2026 DeepSig Inc. -->
<!-- SPDX-License-Identifier: BSD-3-Clause-Clear -->
# OCUDU dApp/E3 demo

A 5G SA stack in Docker: Open5GS core, the OCUDU gNB with the dApp runtime and
E3 interface, and an OAI nrUE — joined by a ZeroMQ virtual radio, or over the
air with USRPs.

```
 ocudu_demo_5gc        ocudu_demo_gnb                    oai_nr_ue
 Open5GS 5GC  <-NGAP-> OCUDU gNB          <--- ZMQ ---> OAI nrUE
 10.53.1.2            10.53.1.3                         10.53.1.4
                      | E3AP  sctp/36423                UE IP 10.45.1.2
                      | E3DP  sctp/38472
```

Cell: TDD band n78, 20 MHz, 30 kHz SCS, PCI 1, PLMN 00101.

## Sources

`bootstrap.sh` clones these next to this repo at pinned commits:

- [ocudu-dapp-platform](https://gitlab.com/ocudu/work_groups/wg2_ai_ran/ocudu-dapp-platform) — the gNB, plus the two PRACH patches in `patches/ocudu/`
- [ocudu-dapp-sdk](https://gitlab.com/ocudu/work_groups/wg2_ai_ran/ocudu-dapp-sdk) — reference dApps
- [ocudu-dapp-gnuradio](https://github.com/rajb245/ocudu-dapp-gnuradio) — GNU Radio E3 observer

The OAI nrUE is built from [duranta-project/openairinterface5g](https://github.com/duranta-project/openairinterface5g) (pinned in `.env`).

## Prerequisites

- Docker Engine with Compose v2 and buildx (from Docker's apt repo, not `docker.io`)
- `sctp` kernel module loaded: `sudo modprobe sctp`
- `/dev/net/tun`
- CUDA build only: NVIDIA driver r580+ and the NVIDIA Container Toolkit
- No git credentials — every repo clones over https

`bootstrap.sh` checks all of these and prints the fix for anything missing.

## Build

```bash
mkdir <workspace> && cd <workspace>
git clone https://github.com/rajb245/ocudu-demo.git demo
demo/bootstrap.sh
```

Then build one gNB image — CPU, or CUDA if bootstrap reports a usable GPU:

```bash
docker compose -f demo/docker-compose.yml build                                        # CPU, ~25 min
docker compose -f demo/docker-compose.yml -f demo/docker-compose.cuda.yml build        # CUDA
```

For CUDA, bootstrap sets `OCUDU_CUDA_ARCHITECTURES` in `demo/.env` from the local
GPU (`120-real` RTX 5090, `89-real` Ada, `86-real` A10/A100, `90-real` H100).
The image only runs on that GPU generation.

All commands below assume the clone is named `demo`.

## Run with the virtual radio (no hardware)

```bash
demo/scripts/up zmq       # core, gNB, UE, GNU Radio observer
demo/scripts/check        # health verdict; exit 0 when the cell is good
```

The UE attaches in about 30 s:

```bash
docker logs -f oai_nr_ue | grep -E "Registration Accept|PDU Session|oaitun"
```

```
Received Registration Accept with result 3GPP
Received PDU Session Establishment Accept, UE IPv4: 10.45.1.2
TUN Interface oaitun_ue1 successfully configured, IPv4 10.45.1.2
```

Check traffic:

```bash
docker exec oai_nr_ue ping -I oaitun_ue1 -c 8 10.45.1.1
demo/scripts/iperf_ue 12
```

Stop everything:

```bash
demo/scripts/down
```

To restart, use `down` then `up`. Restarting only the gNB or only the UE leaves
the ZMQ link hung.

`demo/scripts/up zmq ui` adds Grafana on http://localhost:3300.

## Drive the E3 interface

```bash
E3() { docker exec ocudu_demo_gnb bash -c "cd /work/ocudu &&
  PYTHONPATH=/work/ocudu/python OCUDU_E3_SCHEMA_DIR=/work/ocudu/schemas/e3 $*"; }
DAPPCTL='python3 apps/tools/dappctl/ocudu_dappctl.py --sctp 127.0.0.1:36423'

E3 'python3 -m ocudu_e3 --host 127.0.0.1 --port 36423 catalog'   # RAN functions, telemetry streams
E3 "$DAPPCTL inventory"                                          # packages, instances, connections
E3 "$DAPPCTL health"
```

Load a reference dApp and walk it to `active` (`--package` takes the UUID from
`inventory`; the instance id is also in `inventory` after the load):

```bash
E3 "$DAPPCTL load --package 8f0d0001-4f9c-4e31-8c00-000000000001 --placement in-process --backend cpu"
for step in prepare arm shadow activate; do
  E3 "$DAPPCTL lifecycle $step --instance <instanceId>"
done
E3 "$DAPPCTL health"      # expect all zeros
```

## GNU Radio on the uplink grid

The observer starts with the cell and prints one JSON line per (slot, PRB) above
the noise floor:

```bash
docker logs -f ocudu_demo_grdapp            # ZMQ cell
docker logs -f ocudu_demo_grdapp_usrp       # over-the-air cell
```

```
{"sfn": 296, "slot": 9, "prb": 7, "freq_mhz": 3482.94, "avg_db": -98.79, "floor_db": -120.0, "margin_db": 21.21}
```

On the 20 MHz cell PRB 25 is the DC subcarrier and is always lit.

Stop and restart the stream without touching the cell:

```bash
demo/scripts/down_e3
demo/scripts/up_e3
```

For the in-band 2-FSK demodulator instead:

```bash
GRDAPP_SCRIPT=fsk_demod_dapp.py GRDAPP_ARGS="--f0-prb 10 --f1-prb 40" \
  docker compose -f demo/docker-compose.yml --profile zmq up -d --no-deps --force-recreate gr-dapp
```

## Run over the air (split 8, USRP)

Hardware: Ettus X310 + UBX-160 for the gNB, a B200mini for the UE, both locked to
a 10 MHz reference. This transmits in band n78 — use it only under a licence
that covers it.

gNB host, once: connect the X310's SFP+ port 1 (10 GbE on the HG image), give
that host interface `192.168.40.1/24` (the radio is `192.168.40.2`), and raise
the socket buffers:

```bash
echo -e "net.core.rmem_max=62914560\nnet.core.wmem_max=62914560" | sudo tee /etc/sysctl.d/90-usrp.conf
sudo sysctl --system
```

gNB host:

```bash
demo/scripts/up           # core, USRP gNB, GNU Radio observer
demo/scripts/check
```

UE host (may be a different machine), once:

```bash
docker compose -f demo/docker-compose.ue.yml build
mkdir -p ~/uhd-images
docker run --rm -v "$HOME/uhd-images":/usr/share/uhd/images \
  --entrypoint /usr/bin/uhd_images_downloader ocudu-demo/oai-nr-ue:usrp -t b2xx
```

Set `UE_USRP_ARGS` in `demo/.env` to your B200mini's serial (`uhd_find_devices`), then:

```bash
demo/scripts/up_ue        # uses the external 10 MHz reference
demo/scripts/check_ue
```

If the UE does not attach within a few minutes, restart the UE (`down_ue`,
`up_ue`), not the gNB. Frequency, gains and PRACH settings are in
`demo/configs/gnb_rf_x310_tdd_n78_20mhz_dapp.yml`; the UE gains are
`UE_RX_GAIN`/`UE_TX_GAIN` in `demo/.env`. `demo/scripts/down` and
`demo/scripts/down_ue` stop both ends.

## Scripts

| | |
|---|---|
| `scripts/up [zmq\|radio] [ui]` | start a cell (default `radio`); picks the CPU or CUDA image |
| `scripts/down` | stop everything |
| `scripts/check` | cell health, exit 0 when good |
| `scripts/up_e3`, `scripts/down_e3` | start / stop the E3 spectrum stream |
| `scripts/iperf_ue [seconds]` | uplink and downlink throughput over the UE tunnel |
| `scripts/up_ue`, `scripts/down_ue`, `scripts/check_ue` | over-the-air UE, on the UE host |

## Licence

[The Clear BSD License](LICENSE) (`BSD-3-Clause-Clear`), except:

| | licence |
|---|---|
| `patches/ocudu/*`, `docker-compose.yml`, `.env`, `metrics.env` | `BSD-3-Clause-Open-MPI` (derived from the OCUDU platform) |
| `patches/oai/*`, `configs/nrue_zmq.conf`, `configs/uecap_ports1.xml` | `LicenseRef-CSSL-1.0` (from OpenAirInterface) |

Full texts are in `LICENSES/`.
