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
- [ ] Container configs through `pct`: reverse proxy + fail2ban, SFTPGo
- [x] Secrets with `ansible-vault`
- [ ] Network: bridges, SDN, firewall
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
it), so extend it over its volume group afterwards:
`lvextend -r -l +100%FREE pve/root`.

**New node.** A fresh Proxmox node only has its root password. Trust its host
key once (`ssh root@<ip> true`, checking the fingerprint on its console), then
run the baseline with `--limit <node> --ask-pass`: it authorizes
`ssh_admin_keys` before turning password logins off, and refuses to turn them
off if no admin key is in place.

**Every run.** Playbooks in order, `10`, `20` then `30`, each previewed then
applied:

```bash
ansible-playbook playbooks/10-host-baseline.yml --check --diff   # preview, changes nothing
ansible-playbook playbooks/10-host-baseline.yml                  # apply
ansible-playbook playbooks/20-pve-cluster.yml --check --diff
ansible-playbook playbooks/20-pve-cluster.yml
ansible-playbook playbooks/30-pve-storage.yml --check --diff
ansible-playbook playbooks/30-pve-storage.yml
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
dist-upgrade and reboots the node when `/var/run/reboot-required` appears, so
run it node by node (`--limit`).

- **Swap is zram**, sized `max(ram / 8, 1024)` MiB by zram-generator at every
  boot (`host_baseline_zram_size`). The nodes have no swap on disk.
- **CPU policy per node**: governor (`host_baseline_cpu_governor`, default
  `performance`) and boost (`host_baseline_cpu_boost`, default on), written at
  every boot and corrected live. One laptop runs without boost: its bursts drove
  the fan to full speed.

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
