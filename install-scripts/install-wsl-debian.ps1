param(
    [string]$Username       = $env:USERNAME.ToLower(),
    [string]$ProjectsPath   = "projects",
    [string]$Distro         = "Debian",
    [int]$SshPort           = 22022,
    [switch]$SkipSshContainer
)

$ErrorActionPreference = "Stop"

function Write-Info($msg) {
    Write-Host "[INFO] $msg"
}

function Write-Warn($msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

function Write-Ok($msg) {
    Write-Host "[OK]   $msg" -ForegroundColor Green
}

# -----------------------------
# Configure .wslconfig (mirrored networking for localhost relay)
# -----------------------------
$wslConfigPath = "$env:USERPROFILE\.wslconfig"
if (-not (Test-Path $wslConfigPath)) { New-Item $wslConfigPath -ItemType File | Out-Null }
$wslConfigContent = Get-Content $wslConfigPath -Raw

if ($wslConfigContent -notmatch "networkingMode\s*=\s*mirrored") {
    if ($wslConfigContent -match "\[wsl2\]") {
        $wslConfigContent = $wslConfigContent -replace "(\[wsl2\])", "`$1`nnetworkingMode=mirrored"
    } else {
        $wslConfigContent += "`n[wsl2]`nnetworkingMode=mirrored`n"
    }
    Set-Content $wslConfigPath $wslConfigContent -NoNewline
    Write-Ok "Enabled mirrored networking in .wslconfig"
} else {
    Write-Ok "Mirrored networking already configured"
}

# -----------------------------
# Ensure WSL distro exists
# -----------------------------
Write-Info "Checking WSL distro..."
$distros = (wsl --list --quiet 2>$null) -replace "`0", "" | Where-Object { $_ -ne "" }

if ($distros -notcontains $Distro) {
    Write-Info "Installing $Distro..."
    wsl --install -d $Distro --no-launch
    Write-Warn "$Distro installed. A reboot may be required before continuing."
} else {
    Write-Ok "$Distro already installed"
}

# -----------------------------
# Ensure Systemd is enabled in WSL
# -----------------------------
$wslConf = "[boot]`nsystemd=true`n"
$currentConf = wsl -d $Distro -u root -- bash -c "cat /etc/wsl.conf 2>/dev/null"
if ($currentConf -notmatch "systemd=true") {
    Write-Info "Enabling systemd in /etc/wsl.conf..."
    $wslConf | wsl -d $Distro -u root -- bash -c "cat > /etc/wsl.conf"
}

# -----------------------------
# Run Linux setup script
# -----------------------------
Write-Info "Preparing Linux setup script..."
$setupScript = Join-Path $PSScriptRoot "setup-debian.sh"
$remotePath = "/tmp/setup-debian.sh"

# Resolve VSCode settings path for WSL
$drive = $env:APPDATA.Substring(0, 1).ToLower()
$settingsWSL = "/mnt/$drive" + ($env:APPDATA.Substring(2) -replace '\\', '/') + "/Code/User/settings.json"

# Transfer and execute script
Write-Info "Transferring setup script..."
Get-Content $setupScript -Raw | wsl -d $Distro -u root -- bash -c "tr -d '\r' > $remotePath && chmod +x $remotePath"

Write-Info "Executing setup script inside $Distro..."
wsl -d $Distro -u root -- $remotePath $Username $ProjectsPath $settingsWSL $env:USERNAME

if ($LASTEXITCODE -eq 2) {
    Write-Warn "WSL configuration updated. Terminating $Distro to apply changes..."
    wsl --terminate $Distro
    Start-Sleep -Seconds 1
    Write-Info "Resuming setup..."

    # Re-transfer script as /tmp is cleared on restart
    Get-Content $setupScript -Raw | wsl -d $Distro -u root -- bash -c "tr -d '\r' > $remotePath && chmod +x $remotePath"

    wsl -d $Distro -u root -- $remotePath $Username $ProjectsPath $settingsWSL $env:USERNAME
}
Write-Ok "Linux configuration complete"

# -----------------------------
# Find VS Code (Stable or Insiders)
# -----------------------------
$vscodePaths = @(
    "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
    "$env:ProgramFiles\Microsoft VS Code\Code.exe",
    "$env:LOCALAPPDATA\Programs\Microsoft VS Code Insiders\Code - Insiders.exe",
    "$env:ProgramFiles\Microsoft VS Code Insiders\Code - Insiders.exe"
)
$vscodePath = $vscodePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($null -ne $vscodePath) {
    Write-Info "Found VS Code: $vscodePath"
    $isInsiders = $vscodePath -match "Insiders"
    $binName = if ($isInsiders) { "code-insiders.cmd" } else { "code.cmd" }
    $vscodeBin = Join-Path (Split-Path $vscodePath -Parent) "bin\$binName"
    
    if (Test-Path $vscodeBin) {
        Write-Info "Checking VSCode WSL extension..."
        $extensions = & $vscodeBin --list-extensions
        
        # Use regex match to be case-insensitive and more robust
        $hasExtension = $extensions | Where-Object { $_ -match "ms-vscode-remote.remote-wsl" }
        
        if (-not $hasExtension) {
            Write-Info "Installing WSL extension for VSCode..."
            & $vscodeBin --install-extension ms-vscode-remote.remote-wsl --force
            Write-Ok "WSL extension installed"
        } else {
            Write-Ok "WSL extension already installed"
        }
    } else {
        Write-Warn "VS Code CLI (code.cmd) not found at expected path: $vscodeBin"
    }

    # Clear the Remote-WSL extension's server state so VS Code re-downloads
    # the server on next connect rather than assuming a stale install is present.
    $appDataDir = if ($isInsiders) { "Code - Insiders" } else { "Code" }
    $remoteWslStorage = "$env:APPDATA\$appDataDir\User\globalStorage\ms-vscode-remote.remote-wsl"
    if (Test-Path $remoteWslStorage) {
        Remove-Item $remoteWslStorage -Recurse -Force
        Write-Ok "Cleared Remote-WSL server state (forces fresh server download)"
    }
}

# -----------------------------
# Pinning folder to QuickAccess
# -----------------------------
$wslPath = "\\wsl.localhost\$Distro\home\$Username\projects"

$shell = New-Object -ComObject shell.application
$folder = $shell.Namespace($wslPath)

if ($folder -ne $null) {
    $quickAccess = $shell.Namespace("shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}")
    $alreadyPinned = $quickAccess.Items() | Where-Object { $_.IsFolder -and $_.Path -eq $wslPath }
    if (-not $alreadyPinned) {
        $folder.Self.InvokeVerb("pintohome")
        Write-Ok "Projects folder pinned to Quick Access"
    } else {
        Write-Ok "Projects folder already pinned to Quick Access"
    }
} else {
    Write-Warn "Could not pin folder - WSL path not reachable: $wslPath"
    Write-Warn "Open Explorer and navigate to $wslPath to pin it manually"
}

# -----------------------------
# Create VSCode shortcut
# -----------------------------
Write-Info "Creating VSCode shortcut on Desktop..."
$shortcutPath = "$([Environment]::GetFolderPath('Desktop'))\$Distro.lnk"

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)

$projectsWslPath = "/home/$Username/$ProjectsPath"
if ($null -ne $vscodePath -and (Test-Path $vscodePath)) {
    # Preferred: Use native VS Code remote CLI
    $shortcut.TargetPath = $vscodePath
    $shortcut.Arguments = "--remote wsl+$Distro --folder-uri vscode-remote://wsl+$Distro$projectsWslPath"
    $shortcut.IconLocation = "$vscodePath,0"
} else {
    # Fallback: Use WSL interop if VS Code path isn't standard
    $shortcut.TargetPath = "wsl.exe"
    $shortcut.Arguments = "-d $Distro -- bash -lc `"code $projectsWslPath`""
}
$shortcut.Save()
Write-Ok "Shortcut created: $shortcutPath"

# -----------------------------
# Persistent SSH container (default; skip with -SkipSshContainer)
# -----------------------------
if (-not $SkipSshContainer) {
    & (Join-Path $PSScriptRoot "setup-ssh-container.ps1") `
        -Username      $Username `
        -Distro        $Distro `
        -ProjectsPath  $ProjectsPath `
        -SshPort       $SshPort
}

# -----------------------------
# Final summary
# -----------------------------
$sshPubKey = wsl -d $Distro -u "$Username" -- bash -c "cat ~/.ssh/id_ed25519.pub 2>/dev/null"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Setup complete"                                             -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  WSL distro:   $Distro"
Write-Host "  User:         $Username"
Write-Host "  Projects:     \\wsl.localhost\$Distro\home\$Username\$ProjectsPath"
Write-Host ""
if (-not $SkipSshContainer) {
    Write-Host "  SSH:          ssh -p $SshPort devuser@localhost"
    Write-Host "  Web ports:    8100, 8200, 8300  ->  localhost:8100/8200/8300"
    Write-Host ""
}
Write-Host "  GitHub SSH key (add at https://github.com/settings/keys):"
Write-Host ""
if ($sshPubKey) {
    Write-Host "  $sshPubKey" -ForegroundColor White
} else {
    Write-Host "  (no key found - something may have gone wrong)" -ForegroundColor Red
}
Write-Host ""