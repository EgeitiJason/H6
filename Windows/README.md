# Windows infrastructure

Domain controllers, DHCP, file server, PKI and the Veeam host for `mfrace.internal`,
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
3. Copy [`unattend.xml`](unattend.xml) to `C:\unattend.xml`, set the
   Administrator password in it, then
   `sysprep /generalize /oobe /shutdown /unattend:C:\unattend.xml` — without
   it every clone stops at the OOBE password screen and the agent never starts.
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

Every row it touches is started, rewritten and rebooted, so to add hosts to a
site that is already running, name them:

```bash
curl -s http://<linux-ip>:8000/Windows/pve-bootstrap.sh | \
    PVE=PROD-1 SRC=http://<linux-ip>:8000/Windows ONLY="SRV-PKI-01 SRV-PKI-02" bash
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

### Users and file shares

`roles/Users/users.csv` is fake staff from `./generate-users.py [per-department]`
(default 25). Raising the count only appends, so existing accounts are never
renamed. The `Users` role (on `SRV-ADDS-01`) creates `SG-<department>` groups,
the users with `USER_INITIAL_PASSWORD` (changed at first logon), and a GPO
whose preferences map `F:` Faelles, `G:` Afdelinger and `H:` `Privat\%LogonUser%`,
with a logon script creating that private folder. The GPO is also linked to
`Computers` for `EnableLinkedConnections`, so admins see that `H:` too. `FileServer` creates one
`D:\Shares\Afdelinger\<department>` per leaf OU under Users
(`OU-Structure/ous.psd1`, the same list the `SG-` groups come from); on
`Privat` users may only create a folder, which then only its creator can open.
Removing a row deletes nothing.

### Wallpaper

The `Wallpaper` role (on `SRV-ADDS-01`, after `Users`) copies the badge image from
`wallpapers/` into NETLOGON and links `GPO_MFRACE_Wallpaper` to `Users` and
`Computers`, which sets it as both desktop (Fill) and lock screen. The lock screen policy is only honoured by Enterprise, Education and
Server editions.

### DMZ web servers

`SRV-DMZ-IIS-01` and `-02` sit on VLAN 40 and run `BaseServer` plus `IIS`,
which installs the Web-Server feature and nothing else - no sites, bindings or
certificates. They are not domain-joined, so they get neither a GPO nor an
autoenrolled certificate.

### PKI

Two tiers. `SRV-PKI-01` is a standalone root CA, never domain-joined;
`SRV-PKI-02` is the enterprise issuing CA. `PKI-Root` installs the root and
points its CRL and certificate URLs at `http://SRV-PKI-02.mfrace.internal/CertEnroll`.
`PKI-Issuing` then, over WinRM as the root's local Administrator (`AD_PASSWORD`):
copies the root certificate and CRL into its IIS `CertEnroll`, publishes the
root to AD, has the root sign its request, and **shuts the root down**. It also
creates version 2 copies of the User and Computer templates, `MFRACE-User` and
`MFRACE-Computer`, with autoenroll for Domain Users, Domain Computers and Domain
Controllers, and links `GPO_MFRACE_PKI_AutoEnrollment` at the domain root.
Computers enroll at their next policy refresh (`gpupdate /force`), users at
their next logon.

Because the root stays off, a full `./deploy.sh` afterwards waits five minutes for `SRV-PKI-01` to come
back on SSH, then moves on. That's expected.

Workstations get `MFRACE-Computer`, which carries **Client Authentication
only** - a workstation has no business answering as a TLS server. Servers get
Server Authentication instead, for LDAPS, RDP, IIS and WinRM over HTTPS, from
the built-in `Machine` template. A template's permissions name groups and never
OUs, so the scoping is a GPO: `GPO_MFRACE_PKI_ServerCert`, linked to
`OU=Servers`, holds an *Automatic Certificate Request Settings* (ACRS) policy,
and only computers in that OU request it. ACRS is the one mechanism that scopes
per OU, and it can only request version 1 templates - which is why `Machine` is
published on the CA and why servers do not use an `MFRACE-` template here.

**One manual step:** GPMC stores the ACRS entry as an undocumented object under
the GPO, so the role creates and links the GPO but leaves that entry to you, and
says so on every run until it exists. In `gpmc.msc`, edit
`GPO_MFRACE_PKI_ServerCert` - Computer Configuration - Policies - Windows
Settings - Security Settings - Public Key Policies - *Automatic Certificate
Request Settings* - New, and pick **Computer**. Domain controllers are not in
`OU=Servers`; link the same GPO to their OU as well if you want LDAPS
certificates on them.

`MFRACE-RADIUS` (from the built-in `WebServer` template) is for PacketFence,
which is not in the domain. Its certificate is issued by hand:

1. In PacketFence, generate a CSR for `srv-radius-01.mfrace.internal`. Check it
   carries that name as a **SAN**, not only as the CN:
   `openssl req -in radius.csr -noout -text`.
2. On `SRV-PKI-02`, as a domain admin:
   `certreq -submit -attrib "CertificateTemplate:MFRACE-RADIUS" radius.csr radius.cer`
3. Fetch the chain from `http://srv-pki-02.mfrace.internal/CertEnroll/`. Those
   files are DER, so `openssl x509 -inform der -in <file> -out <file>.pem`.

Revocation is answered by the Online Responder at
`http://srv-pki-02.mfrace.internal/ocsp`, which is what PacketFence's TLS
profile should check - its GUI does not do plain CRLs. Every certificate issued
after this role ran carries that URL.

**One manual step:** the responder's *revocation configuration* is not
scripted. Its only interface is the `CertAdm.OCSPAdmin` COM object, which
behaves differently from PowerShell than from VBScript, reports saves that
never persist, and leaves a half-written configuration that throws on every
later read - not something to run unattended. `PKI-Issuing` installs the
responder, publishes `OCSPResponseSigning` and adds the OCSP URL to the CA, then
tells you if this is missing. In `ocsp.msc` on `SRV-PKI-02`, right-click
*Revocation Configuration* - *Add*: name it `MFRACE-Issuing-CA`, select the CA
from AD, and leave the signing certificate on *automatically selected* with the
`OCSPResponseSigning` template.

### 802.1X on the clients

The `Dot1x` role (on `SRV-PKI-02`, after `PKI-Issuing`) writes the built-in
Wired and Wireless Network policies - EAP-TLS, server
`srv-radius-01.mfrace.internal`, trusting `MFRACE-Root-CA` by thumbprint, and
*User or computer authentication*.

Wired is one GPO for every computer, with 802.1X **enabled but not enforced**,
so a laptop on a home port still gets a link. Each SSID in `config.psd1` gets
its own GPO, because a GPO holds only one wireless policy, filtered to its own
`SG-Wifi-*` group - so a machine gets an SSID by being put in that group.
The groups are created empty in `OU=Wifi,OU=Groups`.

GPMC has no cmdlets for these policies; the role writes the XML blob into the
GPO's AD object itself. The blobs in `roles/Dot1x/*.xml` were written from the
documented schema, not exported from a policy made in the console. If a client
does not show the profile (`netsh wlan show profiles`, `netsh lan show
profiles`), build one by hand in GPMC and export the real thing over them:

```powershell
Get-ADObject -SearchBase "CN=Machine,CN={<GPO GUID>},CN=Policies,CN=System,DC=mfrace,DC=internal" `
  -LDAPFilter '(|(objectClass=ms-net-ieee-80211-GroupPolicy)(objectClass=ms-net-ieee-8023-GroupPolicy))' `
  -Properties * | Format-List *PolicyData, gPCMachineExtensionNames
```

Put `{{SSID}}`, `{{POLICYNAME}}`, `{{POLICYGUID}}` and `{{EAPCONFIG}}` back in,
and check the CSE pair in `Install.ps1` against `gPCMachineExtensionNames`.

**The root CRL is valid for 52 weeks.** Renew it before then, or every
certificate stops validating: start `SRV-PKI-01`, then
`./deploy.sh SRV-PKI-01` followed by `./deploy.sh SRV-PKI-02 PKI-Issuing`.

## How it fits together

`config.psd1` is the single source of truth — domain, IPs, sites, time zone.
Nothing else hardcodes them.

`inventory.csv` says what runs where. Role order within the `roles` cell is
execution order; row order is host order. That is the entire dependency system:
no resolver, no graph. `SRV-ADDS-02` must follow `-01` because you cannot
promote a replica into a forest that does not exist, and `SRV-DHCP-02` must
follow `-01` because it receives its scopes by failover replication.

vmids are not recorded. `pve-bootstrap.sh` matches each row by VM name across
the cluster and allocates a fresh id from `/cluster/nextid` for anything
missing, so re-running it is safe — and renaming a host in the CSV builds a new
VM rather than touching the old one.

### Adding a role

Three rules, and that's the whole framework:

1. A folder under `roles/` containing `Install.ps1`, with its data beside it as
   a CSV.
2. Start with the standard param block and
   `$Config = Import-PowerShellDataFile "$PSScriptRoot\..\..\config.psd1"`.
   `deploy.sh` passes `-AdminPassword`, `-FailoverSecret`, `-SelfName` and
   `-UserPassword` to every role, so declare all four even if unused.
   Anything that needs AD or SYSVOL from a key-based SSH logon goes through
   `roles/Invoke-AsDomainAdmin.ps1`.
3. Make it **idempotent**. `deploy.sh` runs each role twice with a reconnect in
   between: pass two finishes anything a reboot interrupted, and for roles that
   never reboot it is a free idempotency check.

Then add the role name to a host's `roles` cell.

## Known gaps

- Veeam B&R itself is an ISO install; `SRV-VEEAM-01` only gets `BaseServer` and
  `DomainJoin` from here.
- PacketFence (`srv-radius-01`, 10.0.10.16) is configured in its own GUI, not
  from here. What has to line up on this side: Windows DHCP must have **no**
  scope on the registration and isolation VLANs (PacketFence serves DHCP and
  DNS there), and those VLANs' `ip helper-address` must point only at it.
  On the production VLANs, add it as a *second* helper next to the DHCP
  servers so it sees leases for fingerprinting. Its AD source can bind as any
  domain user; machines arrive as `host/<name>.mfrace.internal`
  (`servicePrincipalName`), users as their UPN.
- A client only gets its certificate and 802.1X policy while it can reach a DC,
  so join and `gpupdate` it on an ordinary port before moving it behind 802.1X.
- The switches have no `ip name-server` or `ip helper-address` yet. Until they
  point at `SRV-ADDS-01` and `SRV-DHCP-01`, DHCP only serves its own subnet.
