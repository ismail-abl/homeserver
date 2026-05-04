# My Home Server

Infrastructure automation and container orchestration using Ansible and Proxmox.

## TODOs

- [ ] Prerequisite setup on dev machine (first test ansible playbook, running script, windows + linux)
- [ ] Setup proxmox host (first boot)
- [ ] Network Stack
- [ ] Prerequisite for ansible, terraform on Proxmox host
- [ ] Check feasibility of using community-script to auto install services in containers/VMs
- [ ] Website

## Ansible Workflow

Development and versioning stay on the local machine (git). Ansible execution uses a remote Linux host to avoid Windows compatibility issues with native Ansible.

**Why this approach?**
Ansible CLI can fail on native Windows with `OSError: [WinError 1] Incorrect function`. The solution: execute from a remote Linux host over SSH/SCP, keeping your source code on Windows.

### Quick Start

#### Option 1: Linux / WSL / macOS (Direct execution)

```bash
cd ansible
bash ./scripts/setup-venv.sh
source .venv/bin/activate
ansible-playbook playbooks/install_sudo.yml
```

Or run playbook directly:
```bash
cd ansible
./scripts/setup-venv.sh && ./.venv/bin/ansible-playbook playbooks/install_sudo.yml
```

**Environment variables:**
- `PYTHON_CMD` - Python executable to use (default: `python3`)

#### Option 2: Windows (Remote execution via SSH)

From the `ansible/` directory:

```powershell
Set-Location c:\Users\ismail\Apps\homeserver\ansible
.\run-ansible.ps1 playbooks/install_sudo.yml
```

Or with shorthand:
```powershell
.\run-ansible.ps1 playbook/install_sudo.yml
```

**What the script does:**
1. Validates playbook exists locally
2. Copies entire `ansible/` directory to remote host via `scp`
3. Sets execute permission on `setup-venv.sh`
4. Runs venv setup and ansible-playbook on remote host over SSH

**Prerequisites for Windows:**
- SSH access to remote Linux host (variable `$remoteMachine = "home"` in script)
- `ssh`, `scp` available in PATH (Git Bash, WSL terminal, or native OpenSSH)

**Configuration (edit `run-ansible.ps1`):**
- `$remoteMachine` - SSH host/user@hostname (currently `"home"`)
- `$remoteAnsibleFolder` - Remote directory name (currently `"homeserver"`)

### Ansible Structure

```
ansible/
├── ansible.cfg              # Ansible configuration
├── inventory.ini            # Hosts inventory (proxmox)
├── requirements.txt         # Python dependencies (ansible-core, etc)
├── group_vars/
│   └── all.yml             # Variables for all hosts
├── host_vars/
│   └── proxmox.yml         # Host-specific variables for proxmox
├── vars/
│   └── global.yml          # Global variables for playbooks
├── roles/
│   └── common/             # Common role (sudo, etc)
│       ├── tasks/main.yml
│       └── templates/
├── playbooks/              # Playbooks
│   └── 00-test-install-wget.yml
├── templates/              # Shared Jinja2 templates
├── setup-venv.sh           # Bootstrap Python venv (Linux/bash)
└── run-ansible.ps1         # Remote launcher (Windows/PowerShell)
```

### Development Setup

**On Linux/WSL/macOS:**
1. Edit playbooks locally
2. Test with local venv
3. Commit to git
4. Push to remote (Github)

**On Windows:**
1. Edit playbooks locally
2. Commit to git
3. Run `.\run-ansible.ps1` to test on remote host
4. Push to remote (Github)

### CV-Oriented Highlights

- Designed a three-tier IaC workflow (dev workstation, remote execution runner, infrastructure targets)
- Implemented repeatable Ansible execution pipeline from Windows to Linux over SSH/SCP
- Standardized environment bootstrap with isolated Python virtual environments
- Improved operational reliability by separating source control workflow from runtime pipeline
- Applied infrastructure automation practices: idempotent playbooks, reproducible dependency setup

## Hardware

- **CPU:** AMD Ryzen 5 3600
- **RAM:** 2x8 GB (16 GB total)
- **Network:** 1 Gbps link
- **GPU:** AMD Radeon 6600
- **Storage:** 500 GB SSD (ZFS no RAID)
