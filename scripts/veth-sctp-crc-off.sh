#!/bin/sh
# SPDX-FileCopyrightText: Copyright (C) 2026 DeepSig Inc.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Turn off SCTP CRC offload on the container's veth interfaces.
#
# On older kernels (seen on Ubuntu 20.04, 5.4) veth advertises tx-checksum-sctp,
# so the stack leaves the CRC32c for "hardware" that never exists on a
# veth -> bridge -> veth path. Small packets happened to get through; the
# gNB's E3AP INIT-ACKs did not, and every SCTP client in another container
# saw its association time out while the receiving namespace counted
# SctpChecksumErrors. Newer kernels (7.0 checked) do not have the problem,
# and the script is a no-op there too - the toggle just disables an offload.
#
# Only eth* interfaces whose driver is veth are touched, so the same image on
# the host network (the USRP gNB) changes nothing on the host's NICs.
# Needs CAP_NET_ADMIN; without it the toggle fails quietly and the gNB still
# starts, only reachable over E3 from the host or from its own namespace.
for d in /sys/class/net/eth*; do
  [ -e "$d" ] || continue
  i=$(basename "$d")
  drv=$(ethtool -i "$i" 2>/dev/null | awk '/^driver:/{print $2}')
  [ "$drv" = veth ] || continue
  if ethtool -K "$i" tx-checksum-sctp off >/dev/null 2>&1; then
    echo "veth-sctp-crc-off: $i tx-checksum-sctp off"
  else
    echo "veth-sctp-crc-off: could not change $i (no CAP_NET_ADMIN?)" >&2
  fi
done
exit 0
