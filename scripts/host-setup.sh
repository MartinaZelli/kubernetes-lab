#!/usr/bin/env bash
# Prerequisiti dell'host per il lab.
# Idempotente: rilanciabile senza danni.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly POOL_NAME="default"
readonly POOL_PATH="/var/lib/libvirt/images"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Va eseguito come root: sudo $0" >&2
  exit 1
fi

if virsh pool-info "${POOL_NAME}" &>/dev/null; then
  echo "[ok]  storage pool '${POOL_NAME}' già presente"
else
  echo "[new] creo lo storage pool '${POOL_NAME}'"
  virsh pool-define-as "${POOL_NAME}" dir --target "${POOL_PATH}"
  virsh pool-build "${POOL_NAME}"
  virsh pool-start "${POOL_NAME}"
  virsh pool-autostart "${POOL_NAME}"
fi

install -m 755 "${SCRIPT_DIR}/k8s-lab-firewall.sh" /usr/local/bin/k8s-lab-firewall.sh
install -m 644 "${SCRIPT_DIR}/k8s-lab-firewall.service" /etc/systemd/system/k8s-lab-firewall.service
systemctl daemon-reload
systemctl enable --now k8s-lab-firewall.service
echo "[ok]  regole firewall installate e attive"
