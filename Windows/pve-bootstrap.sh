#!/usr/bin/env bash
# Runs on a Proxmox host. Clones, starts and bootstraps every inventory row
# belonging to this datacenter, then hands off to deploy.sh over SSH.
#
#   curl -s http://<linux-ip>:8000/Windows/pve-bootstrap.sh | PVE=PROD-1 SRC=http://<linux-ip>:8000/Windows bash
#
# Paste it once per Proxmox datacenter - a standalone host is not a cluster
# member, so a clone issued here cannot land there.
set -euo pipefail

SRC="${SRC:?set SRC to the base URL serving this directory}"
PVE="${PVE:?set PVE to this datacenter name, matching the inventory pve column}"
NODE="$(hostname -s)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -sf "$SRC/inventory.csv"  -o "$WORK/inventory.csv"
curl -sf "$SRC/bootstrap.ps1"  -o "$WORK/bootstrap.ps1"
curl -sf "$SRC/config.psd1"    -o "$WORK/config.psd1"

# config.psd1 is PowerShell, but the three values we need are plain scalars.
psd_value() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$WORK/config.psd1"; }
GATEWAY="$(psd_value Gateway)"
DNS="$(psd_value PrimaryDCIP)"
TEMPLATE="${TEMPLATE:-$(sed -n "s/^[[:space:]]*'$PVE'[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p" "$WORK/config.psd1")}"
: "${TEMPLATE:?no template vmid for $PVE in config.psd1 Templates}"

PUBKEY="${PUBKEY:-}"
if [ -z "$PUBKEY" ]; then
    PUBKEY="$(curl -sf "$SRC/id_pubkey" || true)"
fi
: "${PUBKEY:?set PUBKEY, or serve your public key as id_pubkey next to this script}"

while IFS=, read -r name vmid ip pve node roles; do
    [ "$name" = "name" ] && continue
    [ "$pve" = "$PVE" ] || continue

    if qm status "$vmid" >/dev/null 2>&1; then
        echo "== $name ($vmid) already exists, skipping clone"
    else
        echo "== $name ($vmid): cloning from template $TEMPLATE"
        # --target only applies in a cluster, and only when it differs from here.
        if [ -n "$node" ] && [ "$node" != "$NODE" ]; then
            qm clone "$TEMPLATE" "$vmid" --name "$name" --full --target "$node"
        else
            qm clone "$TEMPLATE" "$vmid" --name "$name" --full
        fi
    fi

    TARGET_NODE="${node:-$NODE}"
    qm start "$vmid" 2>/dev/null || true

    echo "-- waiting for guest agent on $name"
    for _ in $(seq 1 60); do
        pvesh get "/nodes/$TARGET_NODE/qemu/$vmid/agent/ping" >/dev/null 2>&1 && break
        sleep 5
    done

    # file-write goes over the virtio serial channel, so the guest needs no network yet.
    pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/agent/file-write" \
        --file 'C:\bootstrap.ps1' --content "$(cat "$WORK/bootstrap.ps1")"

    # --synchronous 0: bootstrap.ps1 ends in a reboot, so it can never return.
    qm guest exec "$vmid" --synchronous 0 -- \
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\bootstrap.ps1' \
        -IPAddress "$ip" -Gateway "$GATEWAY" -Hostname "$name" \
        -DnsServer "$DNS" -PublicKey "$PUBKEY"

    echo "== $name bootstrapped, will come up on $ip"
done < "$WORK/inventory.csv"

echo
echo "Done. From your workstation: Windows/deploy.sh"
