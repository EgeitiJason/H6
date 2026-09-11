#!/usr/bin/env bash
# Deploys roles to the Windows servers over SSH, driven from this checkout.
#
#   ./deploy.sh                     every host in inventory.csv, in order
#   ./deploy.sh SRV-ADDS-01         one host, all its roles
#   ./deploy.sh SRV-DHCP-01 DHCP    one role on one host
#
# Assumes pve-bootstrap.sh has already put sshd and your key on each box.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="$HERE/inventory.csv"
USER_NAME="${WIN_USER:-Administrator}"
ONLY_HOST="${1:-}"
ONLY_ROLE="${2:-}"

[ -f "$HERE/.env" ] && set -a && . "$HERE/.env" && set +a

ssh_win() { ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$USER_NAME@$1" "${@:2}"; }

wait_for_ssh() {
    local ip="$1"
    for _ in $(seq 1 60); do
        ssh_win "$ip" exit >/dev/null 2>&1 && return 0
        sleep 5
    done
    echo "!! $ip never came back on ssh" >&2
    return 1
}

push() {
    local ip="$1"
    ssh_win "$ip" 'if not exist C:\deploy mkdir C:\deploy' >/dev/null
    scp -q -o StrictHostKeyChecking=accept-new -r \
        "$HERE/config.psd1" "$HERE/roles" "$USER_NAME@$ip:C:/deploy/"
}

# Roles reboot. Rather than tracking which ones, run every role twice with a
# reconnect in between: pass two finishes anything a reboot interrupted, and
# for roles that never rebooted it is a free idempotency check.
run_role() {
    local ip="$1" role="$2" pass
    for pass in 1 2; do
        echo "-- $role on $ip (pass $pass)"
        ssh_win "$ip" powershell -NoProfile -ExecutionPolicy Bypass \
            -File "C:\\deploy\\roles\\$role\\Install.ps1" \
            -AdminPassword "'${AD_PASSWORD:-}'" \
            -FailoverSecret "'${DHCP_FAILOVER_SECRET:-}'" \
            -SelfName "'$3'"
        wait_for_ssh "$ip" || return 1
    done
}

while IFS=, read -r name ip pve node roles vlan; do
    [ "$name" = "name" ] && continue
    [ -n "$ONLY_HOST" ] && [ "$name" != "$ONLY_HOST" ] && continue

    echo "== $name ($ip)"
    wait_for_ssh "$ip" || continue
    push "$ip"

    IFS=';' read -ra role_list <<< "$roles"
    for role in "${role_list[@]}"; do
        [ -n "$ONLY_ROLE" ] && [ "$role" != "$ONLY_ROLE" ] && continue
        run_role "$ip" "$role" "$name" || break
    done
done < "$INVENTORY"
