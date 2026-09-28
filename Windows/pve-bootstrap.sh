#!/usr/bin/env bash
# Runs on a Proxmox host. Clones, starts and bootstraps every inventory row
# belonging to this datacenter, then hands off to deploy.sh over SSH.
#
#   curl -s http://<linux-ip>:8000/Windows/pve-bootstrap.sh | PVE=PROD-1 SRC=http://<linux-ip>:8000/Windows bash
#
# Paste it once per Proxmox datacenter - a standalone host is not a cluster
# member, so a clone issued here cannot land there.
#
# ONLY limits it to named hosts, since every row it touches is rebooted:
#
#   ... | PVE=PROD-1 SRC=... ONLY="SRV-PKI-01 SRV-PKI-02" bash
set -euo pipefail

# Everything goes to the terminal and to a log file, timestamped.
LOG="${LOG:-/var/log/pve-bootstrap.log}"
exec > >(while IFS= read -r l; do printf '%(%F %T)T %s\n' -1 "$l"; done | tee -a "$LOG") 2>&1
# set -e alone dies silently - say where and on what.
trap 'echo "!! failed at line $LINENO: $BASH_COMMAND"' ERR

SRC="${SRC:?set SRC to the base URL serving this directory}"
PVE="${PVE:?set PVE to this datacenter name, matching the inventory pve column}"
NODE="$(hostname -s)"
ONLY="${ONLY:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== pve-bootstrap for $PVE on $NODE, logging to $LOG"
for f in inventory.csv bootstrap.ps1 config.psd1; do
    echo "-- fetching $SRC/$f"
    curl -sSf "$SRC/$f" -o "$WORK/$f"
done

# config.psd1 is PowerShell, but the values we need are plain scalars.
psd_value() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$WORK/config.psd1"; }
DNS="$(psd_value PrimaryDCIP)"
TEMPLATE="${TEMPLATE:-$(sed -n "s/^[[:space:]]*'$PVE'[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p" "$WORK/config.psd1")}"
: "${TEMPLATE:?no template vmid for $PVE in config.psd1 Templates}"

PUBKEY="${PUBKEY:-}"
if [ -z "$PUBKEY" ]; then
    PUBKEY="$(curl -sf "$SRC/id_pubkey" || true)"
fi
: "${PUBKEY:?set PUBKEY, or serve your public key as id_pubkey next to this script}"
echo "-- template $TEMPLATE, dns $DNS"

# The VM name is the identity - vmids are allocated, never recorded. Cluster-wide,
# so a VM cloned to another node on a previous run is still found from here.
find_vm() { # name -> "vmid node", empty when absent
    pvesh get /cluster/resources --type vm --output-format json |
        NAME="$1" perl -MJSON::PP -0777 -ne 'for (@{decode_json($_)}) {
            next unless ($_->{name} // "") eq $ENV{NAME};
            print "$_->{vmid} $_->{node}\n"; last }'
}

while IFS=, read -r name ip pve node roles vlan; do
    [ "$name" = "name" ] && continue
    [ "$pve" = "$PVE" ] || continue
    # Every row reached below is started, rewritten and rebooted, so a partial
    # run has to be opt-in by name rather than by datacenter.
    if [ -n "$ONLY" ]; then
        case " ${ONLY//,/ } " in *" $name "*) ;; *) continue ;; esac
    fi

    # read returns 1 on no output (VM absent), which set -e would treat as fatal.
    read -r vmid found_node < <(find_vm "$name") || true
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
        # --full 0: linked clone, so the template must stay - removing it breaks every VM.
        # --target only applies in a cluster, and only when it differs from here.
        if [ "$TARGET_NODE" != "$NODE" ]; then
            qm clone "$TEMPLATE" "$vmid" --name "$name" --full 0 --target "$TARGET_NODE"
        else
            qm clone "$TEMPLATE" "$vmid" --name "$name" --full 0
        fi
    fi

    # Via the API, not qm: the VM may well live on another node. Rewrite net0
    # rather than setting it fresh, or Proxmox hands out a new MAC.
    net0="$(pvesh get "/nodes/$TARGET_NODE/qemu/$vmid/config" --output-format json |
        perl -MJSON::PP -0777 -ne 'print decode_json($_)->{net0}')"
    echo "-- setting vlan $vlan on net0 ($net0)"
    pvesh set "/nodes/$TARGET_NODE/qemu/$vmid/config" \
        --net0 "$(sed 's/,tag=[0-9]*//' <<< "$net0"),tag=$vlan"

    echo "-- starting $name on $TARGET_NODE"
    pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/status/start" >/dev/null 2>&1 || echo "-- (start returned non-zero, probably already running)"

    echo "-- waiting for guest agent on $name (up to 5 min)"
    agent=""
    for i in $(seq 1 60); do
        pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/agent/ping" >/dev/null 2>&1 && { agent=1; break; }
        (( i % 6 == 0 )) && echo "-- still waiting for agent on $name ($((i * 5))s)"
        sleep 5
    done
    [ -n "$agent" ] || { echo "!! guest agent on $name never answered"; exit 1; }

    # file-write goes over the virtio serial channel, so the guest needs no network yet.
    echo "-- writing C:\\bootstrap.ps1 to $name"
    pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/agent/file-write" \
        --file 'C:\bootstrap.ps1' --content "$(cat "$WORK/bootstrap.ps1")"

    # The API takes argv as repeated --command values, and is async by default -
    # which is what we need: bootstrap.ps1 ends in a reboot, so it can never return.
    echo "-- running bootstrap.ps1 on $name"
    pvesh create "/nodes/$TARGET_NODE/qemu/$vmid/agent/exec" \
        --command powershell.exe \
        --command -NoProfile \
        --command -ExecutionPolicy --command Bypass \
        --command -File --command 'C:\bootstrap.ps1' \
        --command -IPAddress --command "$ip" \
        --command -Gateway --command "${ip%.*}.1" \
        --command -Hostname --command "$name" \
        --command -DnsServer --command "$DNS" \
        --command -PublicKey --command "$PUBKEY"

    echo "== $name bootstrapped, will come up on $ip"
done < "$WORK/inventory.csv"

echo
echo "Done. From your workstation: Windows/deploy.sh"
