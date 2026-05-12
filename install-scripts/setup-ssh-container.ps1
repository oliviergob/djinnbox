param(
    [string]$Username     = $env:USERNAME.ToLower(),
    [string]$Distro       = "Debian",
    [string]$ProjectsPath = "projects",
    [int]$SshPort         = 22022
)

$ErrorActionPreference = "Stop"
$ContainerName = "djinnbox"
$TaskName      = "WSL-$ContainerName"

function Write-Info($msg) { Write-Host "[INFO] $msg" }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Ok($msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }

# ── 1. SSH public key ─────────────────────────────────────────────────────
$pubKeyPath = "$env:USERPROFILE\.ssh\id_ed25519.pub"
if (-not (Test-Path $pubKeyPath)) {
    Write-Warn "No SSH public key at $pubKeyPath"
    Write-Warn "Generate one with: ssh-keygen -t ed25519"
    exit 1
}
$sshPubKey = (Get-Content $pubKeyPath -Raw).Trim()
Write-Ok "SSH public key loaded"

# ── 2. Transfer files to WSL ──────────────────────────────────────────────
$scriptPath = Join-Path $PSScriptRoot "setup-ssh-container.sh"

Write-Info "Transferring files to WSL..."
Get-Content $scriptPath -Raw | wsl -d $Distro -u root -- bash -c "tr -d '\r' > /tmp/setup-ssh-container.sh && chmod +x /tmp/setup-ssh-container.sh"
$sshPubKey                        | wsl -d $Distro -u root -- bash -c "tr -d '\r' > /tmp/dev-ssh-pubkey.tmp && chmod 644 /tmp/dev-ssh-pubkey.tmp"
Write-Ok "Files transferred"

# ── 3. Run Linux setup ────────────────────────────────────────────────────
Write-Info "Running Linux setup (first run builds the container image)..."
wsl -d $Distro -u root -- /tmp/setup-ssh-container.sh $Username $ProjectsPath $SshPort
Write-Ok "Linux setup complete"

# ── 4. Task Scheduler — start WSL at logon so systemd starts the container ─
if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $action    = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d `"$Distro`" -- true"
    $settings  = New-ScheduledTaskSettingsSet `
                     -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
                     -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    Register-ScheduledTask -TaskName $TaskName -Trigger $trigger -Action $action `
        -Settings $settings -Principal $principal `
        -Description "Starts WSL $Distro at logon; systemd linger then starts $ContainerName automatically" `
        | Out-Null
    Write-Ok "Task Scheduler task registered: $TaskName"
} else {
    Write-Ok "Task Scheduler task already exists: $TaskName"
}

# ── 5. Summary ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  $ContainerName is ready"                                    -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  SSH from Windows:  ssh -p $SshPort devuser@localhost"
Write-Host "  Web ports:         8100, 8200, 8300 -> localhost:8100/8200/8300"
Write-Host "  Projects mounted:  /home/devuser/projects -> ~/projects (WSL $Distro)"
Write-Host ""
Write-Host "  Auto-start: Task '$TaskName' starts WSL at logon;"
Write-Host "              systemd user service then starts the container."
Write-Host ""
