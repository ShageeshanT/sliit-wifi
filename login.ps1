# SLIIT Wi-Fi auto-login (FortiGate fgtauth captive portal)
#
# Modes:
#   login.ps1            - run the login flow (default)
#   login.ps1 -Setup     - interactively save DPAPI-encrypted credentials
#   login.ps1 -Install   - register the scheduled task (on-logon + on-network-connect)
#   login.ps1 -Uninstall - remove the scheduled task
#
# Credentials are stored in creds.xml via Export-Clixml - DPAPI-encrypted under
# the current Windows user. No other account on this machine can decrypt them.

[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$logPath   = Join-Path $scriptDir 'login.log'
$credPath  = Join-Path $scriptDir 'creds.xml'
$oldCfg    = Join-Path $scriptDir 'config.txt'
$vbsPath   = Join-Path $scriptDir 'SLIIT Wifi.vbs'
$taskName  = 'SLIIT Wifi Auto-Login'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $logPath -Value $line -Encoding utf8 } catch { }
}

# ---------------------------------------------------------------------------
# Credential helpers (DPAPI via Export-Clixml)
# ---------------------------------------------------------------------------
function Save-PortalCredential {
    param([string]$User, [securestring]$SecPass)
    $cred = New-Object System.Management.Automation.PSCredential($User, $SecPass)
    $cred | Export-Clixml -Path $credPath
    Write-Log "Saved encrypted credentials to $credPath"
}

function Get-PortalCredential {
    # Prefer encrypted store
    if (Test-Path $credPath) {
        return (Import-Clixml -Path $credPath)
    }

    # One-time migration from legacy plaintext config.txt
    if (Test-Path $oldCfg) {
        Write-Log 'Migrating plaintext config.txt -> creds.xml (DPAPI)'
        $cfg = Get-Content $oldCfg -Raw | ConvertFrom-StringData
        if (-not $cfg.username -or -not $cfg.password) {
            throw 'config.txt is missing username or password'
        }
        $sec = ConvertTo-SecureString $cfg.password -AsPlainText -Force
        Save-PortalCredential -User $cfg.username -SecPass $sec

        # Shred the plaintext file
        try {
            # Overwrite then delete, just to be thorough
            $junk = 'x' * 256
            Set-Content -Path $oldCfg -Value $junk -NoNewline -Encoding utf8
            Remove-Item $oldCfg -Force
            Write-Log "Deleted plaintext $oldCfg"
        } catch {
            Write-Log "Could not delete $oldCfg : $($_.Exception.Message)"
        }
        return (Import-Clixml -Path $credPath)
    }

    throw "No credentials on disk. Run: powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Setup"
}

# ---------------------------------------------------------------------------
# -Setup : interactive credential entry
# ---------------------------------------------------------------------------
function Invoke-Setup {
    Write-Host ''
    Write-Host 'SLIIT Wi-Fi credential setup' -ForegroundColor Cyan
    Write-Host '----------------------------'
    $u = Read-Host 'SLIIT username (e.g. it24103322)'
    if (-not $u) { throw 'Username cannot be empty' }
    $p = Read-Host 'SLIIT password' -AsSecureString
    if ($p.Length -eq 0) { throw 'Password cannot be empty' }

    Save-PortalCredential -User $u -SecPass $p

    if (Test-Path $oldCfg) {
        Remove-Item $oldCfg -Force
        Write-Host 'Removed plaintext config.txt' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host "OK - credentials saved (DPAPI-encrypted) to:" -ForegroundColor Green
    Write-Host "  $credPath"
    Write-Host 'Only your Windows user account can decrypt this file.'
}

# ---------------------------------------------------------------------------
# -Install : register scheduled task (logon + network-connect event)
# ---------------------------------------------------------------------------
function Invoke-Install {
    if (-not (Test-Path $vbsPath)) { throw "Launcher not found: $vbsPath" }

    # Action: run the silent .vbs wrapper (truly hidden - no flashing window)
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsPath`""

    # Trigger 1: at current-user logon
    $trigLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:UserName

    # Trigger 2: on NetworkProfile connect (event 10000). Fires every time you
    # join a Wi-Fi network or bring an interface up.
    $eventXml = @'
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">
    <Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select>
  </Query>
</QueryList>
'@
    $cimClass = Get-CimClass -ClassName MSFT_TaskEventTrigger `
                             -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigEvent = New-CimInstance -CimClass $cimClass -ClientOnly
    $trigEvent.Enabled      = $true
    $trigEvent.Subscription = $eventXml
    $trigEvent.Delay        = 'PT3S'   # 3s delay so DNS / DHCP settle

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

    $principal = New-ScheduledTaskPrincipal -UserId $env:UserName -LogonType Interactive -RunLevel Limited

    $task = New-ScheduledTask `
        -Action    $action `
        -Trigger   @($trigLogon, $trigEvent) `
        -Settings  $settings `
        -Principal $principal `
        -Description 'Auto-login to SLIIT Wi-Fi captive portal'

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask   -TaskName $taskName -InputObject $task | Out-Null

    Write-Host ''
    Write-Host "OK - scheduled task '$taskName' registered." -ForegroundColor Green
    Write-Host 'Triggers:'
    Write-Host '  * At user logon'
    Write-Host '  * Network connect (NetworkProfile event 10000, +3s delay)'
    Write-Host ''
    Write-Host "Manual test: Start-ScheduledTask -TaskName '$taskName'"
}

function Invoke-Uninstall {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Write-Host "Removed scheduled task '$taskName'." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------------
if ($Setup)     { Invoke-Setup;     exit 0 }
if ($Install)   { Invoke-Install;   exit 0 }
if ($Uninstall) { Invoke-Uninstall; exit 0 }

# ---------------------------------------------------------------------------
# Default mode: run login flow
# ---------------------------------------------------------------------------
try {
    $cred = Get-PortalCredential
    $user = $cred.UserName
    $pass = $cred.GetNetworkCredential().Password

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $probe    = 'http://www.msftconnecttest.com/connecttest.txt'
    $attempts = 3

    for ($i = 1; $i -le $attempts; $i++) {
        Write-Log "Attempt $i/$attempts - probing $probe"

        try {
            $resp = Invoke-WebRequest -Uri $probe -UseBasicParsing -TimeoutSec 10 `
                                      -MaximumRedirection 5 -SessionVariable session
        } catch {
            Write-Log "Probe failed: $($_.Exception.Message)"
            if ($i -lt $attempts) { Start-Sleep -Seconds ([int][Math]::Pow(2, $i)); continue }
            throw
        }

        $finalUrl = $resp.BaseResponse.ResponseUri.AbsoluteUri
        Write-Log "Landed: $finalUrl"

        # Already online? MSFT probe returns exactly "Microsoft Connect Test".
        if ($resp.Content -match 'Microsoft Connect Test' -and $finalUrl -notmatch 'fgtauth') {
            Write-Log 'Already online - exiting.'
            exit 0
        }

        # Extract FortiGate magic token from the form, or fall back to URL query
        $magic = $null
        if ($resp.Content -match 'name="?magic"?\s+value="([0-9a-fA-F]+)"') {
            $magic = $Matches[1]
        } elseif ($finalUrl -match 'fgtauth\?([0-9a-fA-F]+)') {
            $magic = $Matches[1]
        }

        $redir = $probe
        if ($resp.Content -match 'name="?4Tredir"?\s+value="([^"]+)"') { $redir = $Matches[1] }

        if (-not $magic) {
            Write-Log "No magic token in response - not on SLIIT portal? Will retry."
            if ($i -lt $attempts) { Start-Sleep -Seconds ([int][Math]::Pow(2, $i)); continue }
            Write-Log "Giving up after $attempts attempts."
            exit 3
        }

        Write-Log "magic=$magic  4Tredir=$redir"

        $portalBase = ([Uri]$finalUrl).GetLeftPart([UriPartial]::Authority)  # http://auth.sliit.lk:1003
        $postUrl    = "$portalBase/"

        $body = @{
            '4Tredir' = $redir
            magic     = $magic
            username  = $user
            password  = $pass
        }

        Write-Log "POST $postUrl"
        try {
            $login = Invoke-WebRequest -Uri $postUrl -Method Post -Body $body `
                                       -UseBasicParsing -TimeoutSec 15 `
                                       -MaximumRedirection 5 -WebSession $session
        } catch {
            Write-Log "POST failed: $($_.Exception.Message)"
            if ($i -lt $attempts) { Start-Sleep -Seconds ([int][Math]::Pow(2, $i)); continue }
            throw
        }

        if ($login.Content -match '(?i)authentication\s+required|invalid\s+credentials|login\s+failed') {
            Write-Log "Login FAILED (bad credentials?) Status=$($login.StatusCode)"
            exit 2
        }

        Write-Log "Login OK. Status=$($login.StatusCode) Final=$($login.BaseResponse.ResponseUri.AbsoluteUri)"
        exit 0
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
