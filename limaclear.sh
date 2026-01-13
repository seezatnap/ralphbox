#!/usr/bin/env bash
set -euo pipefail

# limaclear.sh — Stop and delete all Lima VMs

vms=$(limactl list --format '{{.Name}}' 2>/dev/null || true)

if [[ -z "$vms" ]]; then
  echo "No Lima VMs found."
  exit 0
fi

echo "Found VMs:"
echo "$vms" | sed 's/^/  /'
echo ""

read -p "Delete all? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

while IFS= read -r vm; do
  [[ -z "$vm" ]] && continue
  echo "[+] Deleting: $vm"
  limactl delete -f "$vm"
done <<< "$vms"

echo "Done."
