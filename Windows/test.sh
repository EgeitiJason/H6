#!/usr/bin/env bash
# Smallest thing that fails if the inventory/config parsing breaks.
# The PowerShell roles can only be checked on a live server; this covers the
# Linux-side plumbing that decides what runs where.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
fail=0
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "ok   $1"
    else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

# --- config.psd1 scalar extraction, as pve-bootstrap.sh does it
psd_value() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" config.psd1; }
check "PrimaryDCIP"  "10.0.10.10"       "$(psd_value PrimaryDCIP)"
check "DomainName"   "mfrace.internal"  "$(psd_value DomainName)"

tmpl() { sed -n "s/^[[:space:]]*'$1'[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p" config.psd1; }
check "PROD-1 template"   "9000" "$(tmpl PROD-1)"
check "BACKUP-1 template" "9000" "$(tmpl BACKUP-1)"

# --- inventory rows
rows() { tail -n +2 inventory.csv; }
check "host count" "6" "$(rows | wc -l)"
check "PROD-1 rows"   "5" "$(rows | awk -F, '$3=="PROD-1"'   | wc -l)"
check "BACKUP-1 rows" "1" "$(rows | awk -F, '$3=="BACKUP-1"' | wc -l)"
# Name is the key pve-bootstrap.sh clones against - a duplicate collapses two
# hosts onto one VM.
check "unique names" "6" "$(rows | cut -d, -f1 | sort -u | wc -l)"

# vlan tags net0 on the bridge; the gateway is derived as <ip>.1, so the IP
# must sit in the matching 10.0.<vlan>.0/24 or the host comes up unrouted.
check "vlan matches subnet" "" "$(rows | awk -F, '$2 !~ "^10\\.0\\." $6 "\\." {print $1}')"
check "VEEAM on vlan 30" "30" "$(rows | awk -F, '$1=="SRV-VEEAM-01" {print $6}')"

# Role order within a cell is execution order - it must survive parsing intact.
roles_of() { rows | awk -F, -v n="$1" '$1==n {print $5}'; }
IFS=';' read -ra r <<< "$(roles_of SRV-ADDS-01)"
check "ADDS-01 role count" "3" "${#r[@]}"
check "ADDS-01 first role" "BaseServer" "${r[0]}"
check "ADDS-01 last role"  "OU-Structure" "${r[2]}"

# DC-Primary must precede DC-Secondary, and DHCP-01 precede DHCP-02, or
# promotion and failover both fail. Row order is the only thing enforcing it.
line_of() { rows | grep -n "^$1," | cut -d: -f1; }
[ "$(line_of SRV-ADDS-01)" -lt "$(line_of SRV-ADDS-02)" ] \
    && echo "ok   ADDS-01 before ADDS-02" || { echo "FAIL ADDS ordering"; fail=1; }
[ "$(line_of SRV-DHCP-01)" -lt "$(line_of SRV-DHCP-02)" ] \
    && echo "ok   DHCP-01 before DHCP-02" || { echo "FAIL DHCP ordering"; fail=1; }

# A DC must never carry DomainJoin, and a member server must always carry it.
for h in SRV-ADDS-01 SRV-ADDS-02; do
    case "$(roles_of $h)" in *DomainJoin*) echo "FAIL $h joins the domain"; fail=1;;
        *) echo "ok   $h does not join";; esac
done
for h in SRV-DHCP-01 SRV-DHCP-02 SRV-FILE-01 SRV-VEEAM-01; do
    case "$(roles_of $h)" in *DomainJoin*) echo "ok   $h joins";;
        *) echo "FAIL $h missing DomainJoin"; fail=1;; esac
done

# Every role named in the inventory must actually exist on disk.
rows | cut -d, -f5 | tr ';' '\n' | sort -u | while read -r role; do
    [ -f "roles/$role/Install.ps1" ] && echo "ok   role $role exists" \
        || { echo "FAIL role $role has no Install.ps1"; exit 1; }
done || fail=1

# The scope owner in config must be a real host that runs the DHCP role.
owner=$(sed -n "s/.*DhcpServers.*=.*@(\s*'\([^']*\)'.*/\1/p" config.psd1)
case "$(roles_of "$owner")" in *DHCP*) echo "ok   scope owner $owner runs DHCP";;
    *) echo "FAIL scope owner '$owner' does not run DHCP"; fail=1;; esac

# --- PowerShell files must at least parse. Behaviour needs a live server, but
# a syntax error should never reach one.
if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File ./parsecheck.ps1 || fail=1
else
    echo "skip pwsh not installed - PowerShell files unparsed"
fi

exit $fail
