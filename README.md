# Homeserver — Proxmox VE as code

Ansible for my home Proxmox VE setup: two nodes today for HA experimenting.
The goal is for this repository to replace my hand-built production setup
entirely, with every change versioned, reviewable and checkable:
`--check --diff` shows any drift between the repository and the nodes.

## Roadmap

- [x] Controller environment: WSL
- [x] Inventory and smoke test (`00-ping.yml`)
- [x] Host baseline (phase 1): APT sources (no-subscription), systemd lid switch, SSH security (key-only, prohibit-password), DNS, NTP (chrony with NTS)
- [x] Proxmox cluster (2 nodes): create/join, weighted quorum votes, declarative root SSH trust, separate opt-in wipe path
- [x] Storage: a ZFS pool for guest disks on every node, declared as one Proxmox storage
- [x] Swap in compressed RAM (zram)
- [x] Access: groups, a custom guest-operator role, users without stored passwords, pools, ACLs
- [x] Replication: every guest copied to the second node every 15 minutes (a warm copy, recovered by hand)
- [x] Backups: every guest every day to the external disk, with retention (no guest stopped)
- [ ] Container configs through `pct`: reverse proxy + fail2ban, SFTPGo
- [x] Secrets with `ansible-vault`
- [x] Firewall for the nodes: management from the LAN only, rollback if the controller is locked out
- [x] Firewall per guest: each filtered guest accepts only its own service ports
- [ ] Network: bridges, SDN
- [ ] LXC templates and container provisioning

## Hardware

- **node1:** Lenovo laptop (AMD Ryzen 5 5500U, NVMe + 6TB USB HDD), the production node
- **node2:** HP laptop
- **OS:** Proxmox VE 9 (Debian 13 Trixie)

## Usage

**Controller.** Any Linux works (here: WSL). A venv pins the Ansible and
ansible-lint versions per project:

```bash
sudo apt install -y python3-venv git sshpass
cd homeserver/ansible
./setup-linux.sh && source ~/.venvs/homeserver/bin/activate
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519
export ANSIBLE_VAULT_PASSWORD_FILE="$PWD/.vault_pass"   # gitignored; or --ask-vault-pass
ansible-playbook playbooks/00-ping.yml                  # smoke test
```

The vault holds the node addresses, so every run needs its password. On WSL
with the repository under `/mnt/c`, mount it with `metadata` in
`/etc/wsl.conf`, or Ansible ignores the world-writable `ansible.cfg`.

**Installation.** ext4, and in the disk options `hdsize 128`, `swapsize 0`,
`maxroot 128`, `minfree 0`, `maxvz 0`: the end of the disk stays unpartitioned
for the guest pool. The installer sizes the root itself (`maxroot` only caps
it); the storage playbook then grows it over its volume group.

**New node.** A fresh Proxmox node only has its root password. Trust its host
key once (`ssh root@<ip> true`, checking the fingerprint on its console), then
run the baseline with `--limit <node> --ask-pass`: it authorizes
`ssh_admin_keys` before turning password logins off, and refuses to turn them
off if no admin key is in place.

**Every run.** Playbooks in order, `10`, `20`, `30`, `40`, `50`, `60`, then `70`,
each previewed then applied:

```bash
ansible-playbook playbooks/10-host-baseline.yml --check --diff   # preview, changes nothing
ansible-playbook playbooks/10-host-baseline.yml                  # apply
ansible-playbook playbooks/20-pve-cluster.yml --check --diff
ansible-playbook playbooks/20-pve-cluster.yml
ansible-playbook playbooks/30-pve-storage.yml --check --diff
ansible-playbook playbooks/30-pve-storage.yml
ansible-playbook playbooks/40-pve-access.yml --check --diff
ansible-playbook playbooks/40-pve-access.yml
ansible-playbook playbooks/50-pve-replication.yml --check --diff
ansible-playbook playbooks/50-pve-replication.yml
ansible-playbook playbooks/60-pve-backup.yml --check --diff
ansible-playbook playbooks/60-pve-backup.yml
ansible-playbook playbooks/70-pve-firewall.yml --check --diff
ansible-playbook playbooks/70-pve-firewall.yml
```

A converged setup previews `changed=0`; anything else is drift.

**Options.** `--tags` / `--skip-tags` target parts of a role, e.g.
`--tags dns_ntp` skips the `apt` part, whose dist-upgrade may reboot the node.
`-e name=value` adjusts behaviour for one run, e.g. `-e pve_cluster_wipe=true`
dissolves and re-forms the cluster (destructive, day 0 only).

## Roles

### `host_baseline`

APT sources and upgrades, base packages (`jq`, and `dnsmasq` for the SDN's
DHCP with the stock service off), systemd (lid switch, sleep targets), zram
swap, CPU frequency policy, SSH, DNS and NTP. Every part is tagged (`system`,
`apt`, `swap`, `cpu`, `sshd`, `dns_ntp`, `cron`, `subgid`), so it can be applied
on its own. `apt` runs a
dist-upgrade and, last, reboots the node when it needs it: a package asks for
it, or the node does not run the kernel it would boot (Proxmox kernels never
say so). The preview says `Would reboot` and why; with
`host_baseline_reboot: false` a node only reports it, for a node whose guests
should not go down unannounced. After a reboot, the role checks the node came
back on that kernel.

- **Swap is zram**, sized `max(ram / 8, 1024)` MiB by zram-generator at every
  boot (`host_baseline_zram_size`). The nodes have no swap on disk.
- **CPU policy per node**: governor (`host_baseline_cpu_governor`, default
  `performance`) and boost (`host_baseline_cpu_boost`, default on), written at
  every boot and corrected live. The nodes run `schedutil` without boost
  (`group_vars/pve`): boost bursts drove a laptop's fan to full speed.

- **SSH hardening is a drop-in** (`/etc/ssh/sshd_config.d/00-hardening.conf`).
  Proxmox rewrites `PermitRootLogin yes` into `sshd_config` on every cluster
  create/join; the drop-in is read first, and sshd keeps the first value it
  reads.
- **Time is authenticated (NTS)** from Netnod's NTS pool (`nts.ntp.se`), with
  `authselectmode prefer`: the unauthenticated fallback (`ntp.metas.ch`) is used
  only if no NTS source works. The chrony default (`mix`) would instead leave
  the clock unsynchronised whenever the NTS sources fail.

### `pve_cluster`

- **Non-destructive by default.** A node without `/etc/pve/corosync.conf` is
  joined (or, for the bootstrap node, the cluster is created); a member is
  never touched. A healthy cluster reports `changed=0`.
- **The destructive path is separate and opt-in** (`pve_cluster_wipe`). It backs
  up `config.db` and `/etc/corosync` on every node, dissolves the cluster, lets
  the normal path re-form it, then asserts that the bootstrap node's guests and
  `storage.cfg` came through unchanged.
- **Quorum votes are declared** (`pve_cluster_votes`, default 1). The
  production node carries 3 of 4 votes, so it stays quorate on its own and the
  second node can be switched off at any time.
- **Root's `authorized_keys` is declarative**: exactly `ssh_admin_keys` plus
  each node's root key. On Proxmox the file is a symlink into `/etc/pve`
  (pmxcfs), where `authorized_key` cannot work (it chowns to `root:root`, which
  pmxcfs refuses), so the whole file is written with `copy` through the symlink
  and validated key by key first. `host_baseline` only *adds* the admin keys;
  removals are this role's job, and since both read `ssh_admin_keys`, running
  one playbook after the other changes nothing.
- **Runs on the whole cluster only.** Every node needs the others' keys,
  addresses and votes, so a partial run (`--limit`) is refused up front.
  Another cluster is another inventory group (`pve_cluster_group`).
- **Never trusts `pvecm`'s exit code.** `pvecm create` and `pvecm add` both exit
  0 on failure; each is followed by a check of what it must have produced, and
  joins wait until the bootstrap node's cluster filesystem itself is quorate.
- **`pvecm` rather than `community.proxmox.proxmox_cluster`**: that module has
  no quorum votes, no way to dissolve a cluster, and joins over the API with the
  root password.

### `pve_storage`

- **The root LV fills its volume group**, grown online with its ext4 (tag
  `root`), never shrunk: the installer leaves part of the volume group free.
- **One pool for guest disks, `pve-data`, also the storage ID**, in its own
  partition at the unpartitioned end of the system disk. The partition is found
  by its GPT name (`zfs-pve-data`), so a reinstall of Proxmox leaves the pool
  intact and the role imports it again. ZFS refuses a pool last used by another
  system (a reinstall changes the hostid): the role stops and says so, and
  `-e pve_storage_force_import=true` imports it.
- **Proxmox's own tools.** `pvesh .../disks/zfs` creates the pool and enables
  its import at boot; `pvesm` declares the storage, and each node adds itself to
  its node list, one node at a time (`serial: 1`).
- **Guarded.** Nothing is created unless exactly one disk carries `/`, its
  largest free block ends the disk and holds at least
  `pve_storage_min_free_gib`, and no pool of that name exists elsewhere. A
  storage of that name that is not this pool is never rewritten.
- **ARC maximum** `pve_storage_arc_max_mib` (1024 MiB), written to
  `modprobe.d` and applied live; raise it per host or group with the RAM.

### `pve_access`

- **Rights go to groups, never to users.** `admins` (Administrator on `/`),
  `operators` (the custom role `VMOperator` on guests, the storages and
  networks they use, node and pool views) and `viewers` (PVEAuditor, empty,
  ready for a monitoring client). Groups, users, ACLs and the pools are
  declared in `group_vars/pve`; `pve_pools` is the single list of guests per
  pool, which other roles reuse.
- **`VMOperator`** is `PVEVMAdmin` plus what a guest needs to exist (storage
  space, a bridge or vnet, node and pool views): full control of every guest,
  no node shell, no user, cluster, datacenter or node firewall, or storage
  settings (a guest's own firewall is part of the guest).
- **No password is stored.** Users are created without one; each is typed once
  with `pveum passwd`. TOTP is optional and enrolled by hand in the web UI if
  wanted (it cannot be declared).
- **Declares, never deletes.** It creates and corrects what it declares (a
  custom role's privileges, comments, user e-mail, group membership, pool members) and
  leaves everything else alone, including users made by hand and `root@pam`.
- **Runs once for the cluster.** Proxmox keeps all of this in `/etc/pve`,
  shared by every node: the role reads it from one node, works out the
  differences, applies one `pveum` command per difference, reads again and
  asserts nothing is left. `--check` prints the differences it would apply.

### `pve_replication`

- **Every guest not on the second node is copied to it every 15 minutes**
  with Proxmox storage replication (ZFS snapshots sent incrementally; the
  first copy is full, capped at 50 MB/s). No guest is stopped.
- **Refuses before writing anything** if a guest has a disk Proxmox cannot
  replicate (not on a ZFS storage present on both nodes, or a bind mount not
  marked `replicate=0`), or if a job already points at another node. It never
  edits a guest.
- **A warm copy, not a failover.** With the votes at 3 + 1 the second node
  alone is never quorate, so guests are brought up there by hand, from a copy
  at most 15 minutes old. Media on the external disk are not copied.
- **Declares and corrects, never deletes**: jobs are read, compared,
  created or corrected (schedule, rate), read again and asserted.

### `pve_backup`

- **Every guest, every day, without stopping any.** One vzdump job,
  snapshot mode, `zstd`, at 06:00, keeps the last day, a week-old and a
  month-old archive. Running
  VMs use fleecing on the fast pool, so a slow backup disk does not stall
  them. Bind mounts are not archived: media on the external disk stay out.
- **On the external disk of one node** (`pve_backup_node`), in a directory
  readable by root only (containers that bind-mount the disk share its
  group). The role refuses to run when the disk is not mounted, and the
  storage is declared with `is_mountpoint`, so Proxmox takes it offline
  instead of filling the root filesystem if the disk is ever missing.
- **Limit:** the archives live on the same machine as the guests: they
  protect from mistakes and corruption, not from losing that node. Failures
  only show in the Proxmox task log until notifications are set up.
- **Declares and corrects, never deletes**: the storage entry and the job
  are read, compared with the declaration, created or corrected, then read
  again and asserted. `--check` prints what would change.

### `pve_firewall`

- **The nodes drop what they do not expect.** The web UI, consoles,
  migration and ping are open to the home network only (both address
  families); SSH to everyone (key-only logins); DHCP and DNS to the guests
  on the networks the nodes serve. Proxmox itself keeps cluster traffic open.
- **It cannot lock its operator out.** It refuses to run unless Ansible
  connects from the management network. A first activation writes the
  rules disabled and checks them; every change is written under a rollback
  timer and kept only once a new SSH connection and the web UI answer from
  every node. Otherwise the previous file comes back after three minutes.
- **Guests filtered one by one.** Security groups (web, torrent, DNS, media,
  file transfer) are declared once; each chosen guest drops everything else
  coming in. Home automation, which discovers devices on its own, accepts
  the home network and nothing from the internet. A
  guest whose network card is not set to be filtered is refused, never edited.
- **The whole file is declared**, and so are the declared guests' files: a
  rule added in the web UI is removed at the next run.
