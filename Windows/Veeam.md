# Veeam Backup & Replication

Set up 2026-09-24. Two Veeam servers, both Windows VMs from `inventory.csv`
(`BaseServer;DomainJoin` only - B&R itself is an ISO install, see
[README.md](README.md)).

| Server | Site | Role |
|---|---|---|
| `srv-veeam-01` (10.0.30.10) | BACKUP-1, Middelfart | The backup server. Owns both jobs. |
| `srv-veeam-02` (10.10.30.10) | BACKUP-2, Odense | Repository host only. No jobs of its own. |

Both run a full B&R install, but only 01 drives anything. 02 exists to hold the
offsite copy, and 01 reaches into it.

## What is backed up

`srv-file-01` (10.0.10.14, VLAN 10) is the only protected computer, added by
hand to the `Manually Added` protection group. The Veeam agent is deployed and
managed from 01 (`ManagedByBackupServer`).

| Job | Type | Source | Target | Schedule | Retention |
|---|---|---|---|---|---|
| `Agent Backup Job 1` | Agent, Server | `D:\` on `srv-file-01` | `Default Backup Repository` (D:\Backup on 01) | Daily, every day | 7 restore days + GFS 4 weekly / 6 monthly / 2 yearly |
| `Backup Copy Job 1` | Immediate backup copy | `Agent Backup Job 1` | `SRV-VEEAM-02 Backup Repository` (D:\Backup on 02) | Continuously | 7 restore days + GFS 4 weekly / 6 monthly / 2 yearly |

`D:\` on the file server is where `D:\Shares` lives - Faelles, Afdelinger and
Privat, see [roles/FileServer/Install.ps1](roles/FileServer/Install.ps1).

Both jobs carry the same GFS: weekly kept on Sunday, monthly on the first
week, yearly in January. Middelfart and Odense therefore hold the same depth -
losing BACKUP-1 costs no history.

Immediate mode means the copy job picks up each new restore point as it
appears, rather than on a clock of its own. Retry is 3 attempts, 10 minutes
apart.

## Direction: 01 pushes, 02 does not pull

This is the opposite of the PBS setup, where PBS-02 pulls from PBS-01
([../Proxmox/PBS.md](../Proxmox/PBS.md)). It is not a preference - Veeam has no
pull.

A backup copy job is driven by whichever backup server holds the source
backup's metadata in its configuration database, and that server always
pushes. Pointing 02 at 01's `D:\Backup` as a repository does work, and 02 can
read the restore points, but they come in flagged `IsImported = True` and
Veeam will not accept an imported backup as a copy source. The source picker
on 02 simply comes up empty.

The only way to have 02 initiate would be to move ownership of the agent job
to 02 as well, leaving 01 as a pure repository server. That was not done - 01
stays the backup server.

## Firewall

The Veeam agent connects *back* to its backup server, so rules have to exist
in both directions. Deployment succeeding proves nothing about whether the job
will run.

| From | To | Ports | Why |
|---|---|---|---|
| `srv-veeam-01` | `srv-file-01` | 445, 135, 6160, 6162 | Agent deployment |
| `srv-file-01` | `srv-veeam-01` | 10005, 6160-6162, 2500-3300 | Agent management channel + data |
| `srv-veeam-01` | `srv-veeam-02` | 445, 6160, 6162, 2500-3300 | Copy job writing to the Odense repository |

VLAN 10 -> VLAN 30 was open on 445 only to begin with. The agent deployed fine
over it, then the job hung for 37 minutes polling an agent that could not
answer on 10005, and failed with "Managed session has failed: A connection
attempt failed...". Opening the ports above fixed it: the same job then
finished in 2m26s.

## Verified 2026-09-24

- `Agent Backup Job 1`: Success, 17:34:37 -> 17:37:04.
- `Backup Copy Job 1`: Success, 18:01:17 -> 18:02:32.
- One Full restore point present in the Odense repository, created 17:34:51.

The first `.vbk` was **2.7 MB**. `D:` on the file server is 32 GB with 31.9 GB
free - the shares are empty. The chain works end to end, but it has not yet
moved a realistic amount of data. Re-check sizing once the shares are in use,
on both sides: with matching GFS the Odense repository now grows at roughly the
same rate as the Middelfart one, not at a seventh of it.

## Not set up

- Backup encryption, in neither job. 02 can read everything.
- Email notification (`EmailNotification` is off on both jobs).
- An application-aware or SureBackup verification job.
- Anything covering the other servers in `inventory.csv` - only `srv-file-01`
  is protected. The Proxmox VMs are covered separately by PBS.

## Leftovers to clean up

`srv-veeam-02` still has `srv-veeam-01` registered as a managed server from the
attempt to make 02 pull. It is harmless but unused, and 02's console showing a
managed server it never touches is confusing later. Remove it, or note why it
stays.
