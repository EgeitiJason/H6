# Proxmox Backup Server

Set up 2026-09-24. Two PBS VMs, each with a 1 TB `sdb` formatted ext4 as its
datastore (933G usable).

| Server | Runs on | Datastore | Role |
|---|---|---|---|
| `srv-pbs-01` (10.0.30.11) | BACKUP-1 | `pve-backups` | PROD-1 backs up here |
| `srv-pbs-02` (10.10.30.11) | BACKUP-2 | `pbs-01-remote` | Pulls from `srv-pbs-01` |

## Schedule

| Time | Where | What |
|---|---|---|
| 21:00 | PROD-1 → PBS-01 | Job `backup-pbs-01`: every VM, snapshot mode, to storage `pbs-01` |
| 23:00 / 23:30 | PBS-01 | Prune `pve-backups-daily` (7 daily, 4 weekly, 6 monthly), then GC |
| 02:00 | PBS-02 ← PBS-01 | Sync job `pull-pbs-01`, `remove-vanished` off |
| 04:00 / 04:30 | PBS-02 | Prune `pbs-01-remote-daily` (7 daily, 4 weekly, 12 monthly), then GC |

Retention is decided on the PBS side, not in PVE.

## Access

- `pve-cluster@pbs!backup`: `DatastoreBackup` on `pve-backups`. PROD-1 logs in
  with it. It can write backups but not prune or delete them, so a compromised
  PVE node can't wipe them.
- `sync@pbs!pbs-02`: `DatastoreReader` on `pve-backups`. PBS-02's remote
  `pbs-01` uses it.
- PBS tokens get the intersection of the user's and the token's own ACL, so
  both carry the role.
- The firewall must allow 10.10.30.11 → 10.0.30.11 TCP 8007. The pull
  runs in that direction.

## Will it fit? (estimated, to check)

Estimated on 2026-09-24, before the first nightly run:

- About 310 GiB of live VM data on `vm-pool`: 354 GiB used, minus snapshots,
  saved RAM states and unattached disks.
- A test backup of template 9000 compressed 18 GiB → 10.1 GiB (0.56).
- First full backup: **~130–175 GiB**. It's lower than 310 × 0.56 because
  Windows servers cloned from 9000 share their OS chunks.
- At an assumed **5 GiB/day** of new compressed chunks: PBS-01 **~400 GiB
  (~45%)**, PBS-02 **~550 GiB (~60%)**.
- At 15 GiB/day, PBS-01 gets tight and PBS-02 does not fit. The monthly
  backups carry most of the growth.

### Check

1. **2026-09-25, after the first 21:00 run:** PBS-01 → Datastore → `pve-backups`
   → Summary. Note the used space (the real full size) and the
   deduplication factor. Also check that the 02:00 `pull-pbs-01` shows OK on
   PBS-02.
2. **About 2026-10-01, after a week:** (used now − used after night 1) / 6
   gives the real daily change rate. Re-run the numbers above with it.
3. If it's high, cut monthly backups on PBS-02 (`keep-monthly`) before
   thinking about a bigger disk.

Not set up: client-side encryption (PBS-02 can read everything) and a
scheduled verify job.
