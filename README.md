# H6

Infrastructure for `mfrace.internal` — Middelfart Racing.

| Area | Contents |
|---|---|
| [`Cisco/`](Cisco/) | Switch configurations, per site |
| [`Windows/`](Windows/) | Domain controllers, DHCP, file server — see [Windows/README.md](Windows/README.md) |

Servers run on three Proxmox datacenters: **PROD-1** (Middelfart, 3 nodes,
Ceph), **BACKUP-1** (Middelfart, standalone, PBS + Veeam) and **BACKUP-2**
(Odense, standalone, replicas of both).
