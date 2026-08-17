#!/usr/bin/env bash
# Autorizza il traffico da/verso la rete NAT delle VM del lab.
#
# Perché serve: Docker imposta la policy della catena FORWARD a DROP e
# ricostruisce le proprie regole a ogni avvio, ignorando le reti di libvirt.
# DOCKER-USER è la catena che Docker riserva all'amministratore e non tocca.
set -euo pipefail

readonly SUBNET="192.168.150.0/24"

for flag in -s -d; do
  if ! iptables -C DOCKER-USER "${flag}" "${SUBNET}" -j ACCEPT 2>/dev/null; then
    iptables -I DOCKER-USER 1 "${flag}" "${SUBNET}" -j ACCEPT
  fi
done
