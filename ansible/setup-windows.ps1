# as windows sucks with ansible
# script to execute ansible-playbook commands from a remote machine
# meant to run playbook with ansible-playbook but may change

# prerequisite
# remote machine ssh name or user@hostname
$remoteMachine = "home"
# folder that will contain ansible files on remote machine
$remoteAnsibleFolder = "homeserver"

$scriptName = Split-Path -Leaf $PSCommandPath

if ($args.Count -ne 1) {
    Write-Error "Usage: .\$scriptName path/to/playbook"
    exit 1
}

# ensure script is executed from ansible directory (contains ansible.cfg)
if (-not (Test-Path -Path "ansible.cfg" -PathType Leaf)) {
    Write-Error "ansible.cfg not found in current directory. Run this script from the ansible directory."
    exit 1
}

# normalize playbook path to an ansible-root relative linux path
$playbookPath = $args[0] -replace '\\', '/'
if ($playbookPath.StartsWith("playbook/")) {
    $playbookPath = "playbooks/" + $playbookPath.Substring("playbook/".Length)
}
if ($playbookPath.StartsWith("/")) {
    $playbookPath = $playbookPath.TrimStart("/")
}
if ($playbookPath.StartsWith("ansible/")) {
    $playbookPath = $playbookPath.Substring("ansible/".Length)
}
if ($playbookPath -notmatch "/" -and $playbookPath.EndsWith(".yml")) {
    $playbookPath = "playbooks/$playbookPath"
}

if (-not (Test-Path -Path $playbookPath -PathType Leaf)) {
    Write-Error "Playbook not found locally from ansible root: $playbookPath"
    exit 1
}

# create directory
ssh $remoteMachine "mkdir -p '$remoteAnsibleFolder'"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create remote directory."
    exit 1
}

# copy ansible folder content to remote machine using scp -r
scp -r * "${remoteMachine}:$remoteAnsibleFolder/."
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to copy ansible directory with scp."
    exit 1
}

# chmod u+x setup-linux.sh on remote machine
ssh $remoteMachine "chmod u+x '$remoteAnsibleFolder/scripts/setup-linux.sh'"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to set execute permission on setup-linux.sh."
    exit 1
}

# run setup + playbook from remote ansible root
ssh $remoteMachine "cd '$remoteAnsibleFolder' && ./scripts/setup-linux.sh && ./.venv/bin/ansible-playbook '$playbookPath'"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Remote playbook execution failed."
    exit 1
}