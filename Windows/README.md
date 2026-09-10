# Windows infrastructure

Domain controllers, DHCP, file server and the Veeam host for `mfrace.internal`,
deployed to Proxmox from a Linux workstation. Cisco switch configs live in
[`../Cisco/`](../Cisco/).

Two transports, each doing the job it's good at:

| Stage | Channel | Why |
|---|---|---|
| Bootstrap a fresh VM | QEMU guest agent | Works with no guest network and no credentials |
| Deploy roles | PS Remoting over SSH | Long-running, streams output, interactive when it breaks |

## One-time setup

**A Windows template per Proxmox datacenter.** `qm guest exec` needs the guest
agent already inside Windows, so this is the only manual console work — once
ever, not once per server.

1. Install Windows Server on a VM with virtio disk and NIC.
2. Install `virtio-win-guest-tools.exe` — the same package as the storage and
   network drivers, and it contains the guest agent.
3. `sysprep /generalize /oobe /shutdown`
4. `qm set <vmid> --agent 1`, then convert to a template.

Record its vmid in `config.psd1` under `Templates`. PROD-1's copy must live on
Ceph so all three nodes can clone it; BACKUP-1 needs its own on local storage.

**Secrets.** `cp .env.example .env` and fill it in. `.env` is gitignored.
Avoid `"` `&` `|` `^` `<` `>` in passwords — they travel through a cmd.exe
command line on the way to PowerShell.

## Building the lab

Serve this checkout, and put your public key where the bootstrap can find it:

```bash
cp ~/.ssh/id_ed25519.pub Windows/id_pubkey     # gitignored
cd /home/jason/repo/H6 && python3 -m http.server 8000
```

Then paste one line into each Proxmox datacenter's shell — PVE's shell is
xterm.js on Linux, so paste works there (it's the *Windows* noVNC console that
has no usable clipboard, which is the whole reason for this approach):

```bash
# on a PROD-1 node
curl -s http://<linux-ip>:8000/Windows/pve-bootstrap.sh | PVE=PROD-1 SRC=http://<linux-ip>:8000/Windows bash
# on BACKUP-1
curl -s http://<linux-ip>:8000/Windows/pve-bootstrap.sh | PVE=BACKUP-1 SRC=http://<linux-ip>:8000/Windows bash
```

Each clones, starts and bootstraps only the inventory rows whose `pve` column
matches — a standalone host is not a cluster member, so a clone issued on PROD-1
cannot land on BACKUP-1.

Then, from this machine:

```bash
./deploy.sh                     # every host, in inventory order
./deploy.sh SRV-ADDS-01         # one host, all its roles
./deploy.sh SRV-DHCP-01 DHCP    # one role on one host
./test.sh                       # inventory/config sanity + PowerShell parse check
```

## How it fits together

`config.psd1` is the single source of truth — domain, IPs, sites, time zone.
Nothing else hardcodes them.

`inventory.csv` says what runs where. Role order within the `roles` cell is
execution order; row order is host order. That is the entire dependency system:
no resolver, no graph. `SRV-ADDS-02` must follow `-01` because you cannot
promote a replica into a forest that does not exist, and `SRV-DHCP-02` must
follow `-01` because it receives its scopes by failover replication.

### Adding a role

Three rules, and that's the whole framework:

1. A folder under `roles/` containing `Install.ps1`, with its data beside it as
   a CSV.
2. Start with the standard param block and
   `$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"`.
   `deploy.sh` passes `-AdminPassword`, `-FailoverSecret` and `-SelfName` to
   every role, so declare all three even if unused.
3. Make it **idempotent**. `deploy.sh` runs each role twice with a reconnect in
   between: pass two finishes anything a reboot interrupted, and for roles that
   never reboot it is a free idempotency check.

Then add the role name to a host's `roles` cell.

## Known gaps

- `FileServer/shares.csv` is a placeholder. Real share layout and NTFS ACLs
  against the OU-tree groups (IT, HR, Finans, Lager) are still to be decided.
- Veeam B&R itself is an ISO install; `SRV-VEEAM-01` only gets `BaseServer` and
  `DomainJoin` from here.
- NAC/RADIUS is out of scope — likely PacketFence, which would be its own Linux
  appliance beside `Cisco/` and `Windows/`, not a role here.
- The switches have no `ip name-server` or `ip helper-address` yet. Until they
  point at `SRV-ADDS-01` and `SRV-DHCP-01`, DHCP only serves its own subnet.
