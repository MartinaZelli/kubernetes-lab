#!/usr/bin/env bash
# Autorizza il traffico delle reti del lab attraverso la catena FORWARD.
#
# Perché serve: Docker imposta la policy della catena FORWARD a DROP e
# ricostruisce le proprie regole a ogni avvio, ignorando le reti di libvirt.
# DOCKER-USER è la catena che Docker riserva all'amministratore e non tocca.
#
# Tre reti, non una sola:
#   - la sottorete delle VM (traffico dei nodi e VXLAN incapsulato)
#   - la rete dei pod di k3s
#   - la rete dei pod di kubeadm/Calico
#
# Le reti dei pod servono perché Calico, con VXLANCrossSubnet su nodi della
# stessa sottorete, NON incapsula: i pacchetti attraversano l'host con
# indirizzi 10.244.x.x in chiaro e vanno autorizzati esplicitamente.
set -euo pipefail

readonly SUBNETS=(
  "192.168.150.0/24" # VM del lab
  "10.42.0.0/16"     # pod k3s
  "10.244.0.0/16"    # pod kubeadm (Calico)
)

for subnet in "${SUBNETS[@]}"; do
  for flag in -s -d; do
    if ! iptables -C DOCKER-USER "${flag}" "${subnet}" -j ACCEPT 2>/dev/null; then
      iptables -I DOCKER-USER 1 "${flag}" "${subnet}" -j ACCEPT
    fi
  done
done
