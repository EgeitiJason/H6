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

# The VM name is the identity - vmids are allocated, never recorded. Cluster-wide,
# so a VM cloned to another node on a previous run is still found from here.
find_vm() { # name -> "vmid node", empty when absent
    NAME="$1" pvesh get /cluster/resources --type vm --output-format json |
        perl -MJSON::PP -0777 -ne 'for (@{decode_json($_)}) {
            next unless ($_->{name} // "") eq $ENV{NAME};
            print "$_->{vmid} $_->{node}\n"; last }'
}

while IFS=, read -r name ip pve node roles; do
    [ "$name" = "name" ] && continue
    [ "$pve" = "$PVE" ] || continue

    read -r vmid found_node < <(find_vm "$name")
    if [ -n "$vmid" ]; then
        # Where it actually is beats where the inventory wanted it - the node
        # column is a placement preference for the first clone, nothing more.
        echo "== $name ($vmid) already exists on $found_node, skipping clone"
        TARGET_NODE="$found_node"
    else
        vmid="$(pvesh get /cluster/nextid)"
        TARGET_NODE="${node:-$NODE}"
        echo "== $name ($vmid): cloning from template $TEMPLATE"
        # --name is what makes the lookup above work on the next run.
        # --target only applies in a cluster, and only when it differs from here.
        if [ "$TARGET_NODE" != "$NODE" ]; then
            qm clone "$TEMPLATE" "$vmid" --name "$name" --full --target "$TARGET_NODE"
        else
            qm clone "$TEMPLATE" "$vmid" --name "$name" --full
        fi
    fi

    # Via the API, not qm: the VM may well live on another node.
    pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/status/start" >/dev/null 2>&1 || true

    echo "-- waiting for guest agent on $name"
    for _ in $(seq 1 60); do
        pvesh get "/nodes/$TARGET_NODE/qemu/$vmid/agent/ping" >/dev/null 2>&1 && break
        sleep 5
    done

    # file-write goes over the virtio serial channel, so the guest needs no network yet.
    pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/agent/file-write" \
        --file 'C:\bootstrap.ps1' --content "$(cat "$WORK/bootstrap.ps1")"

    # The API takes argv as repeated --command values, and is async by default -
    # which is what we need: bootstrap.ps1 ends in a reboot, so it can never return.
    pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/agent/exec" \
        --command powershell.exe \
        --command -NoProfile \
        --command -ExecutionPolicy --command Bypass \
        --command -File --command 'C:\bootstrap.ps1' \
        --command -IPAddress --command "$ip" \
        --command -Gateway --command "$GATEWAY" \
        --command -Hostname --command "$name" \
        --command -DnsServer --command "$DNS" \
        --command -PublicKey --command "$PUBKEY"

    echo "== $name bootstrapped, will come up on $ip"
done < "$WORK/inventory.csv"

echo
echo "Done. From your workstation: Windows/deploy.sh"
