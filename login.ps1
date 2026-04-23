# SLIIT Wi-Fi auto-login (FortiGate fgtauth captive portal)
#
# Modes:
#   login.ps1            - run the login flow (default)
#   login.ps1 -DryRun    - full flow except the final POST; prints what it would send
#   login.ps1 -Setup     - interactively save DPAPI-encrypted credentials
#   login.ps1 -Install   - register the scheduled task (on-logon + on-network-connect)
#   login.ps1 -Uninstall - remove the scheduled task (prompts to delete creds too)
#
# Credentials are stored in creds.xml via Export-Clixml - DPAPI-encrypted under
# the current Windows user. No other account on this machine can decrypt them.

[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$Force     # skip "delete creds.xml?" prompt during -Uninstall
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configurable
# ---------------------------------------------------------------------------
# Skip the login flow if the current Wi-Fi SSID doesn't match this wildcard.
# Examples: '*SLIIT*', 'SLIIT-BYOD', '*'   (set to $null to disable)
$SsidFilter      = '*SLIIT*'

# Log rotation: if login.log exceeds $MaxLogBytes, truncate to last $MaxLogKeepLines
$MaxLogBytes     = 262144   # 256 KB
$MaxLogKeepLines = 500

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------
$scriptDir = $PSScriptRoot
$logPath   = Join-Path $scriptDir 'login.log'
$credPath  = Join-Path $scriptDir 'creds.xml'
$oldCfg    = Join-Path $scriptDir 'config.txt'
$vbsPath   = Join-Path $scriptDir 'SLIIT Wifi.vbs'
$debugHtml = Join-Path $scriptDir 'portal-debug.html'
$taskName  = 'SLIIT Wifi Auto-Login'
$probeUrl  = 'http://www.msftconnecttest.com/connecttest.txt'

# ---------------------------------------------------------------------------
# Log rotation + logging
# ---------------------------------------------------------------------------
function Invoke-LogRotation {
    if (-not (Test-Path $logPath)) { return }
    try {
        $size = (Get-Item $logPath).Length
        if ($size -le $MaxLogBytes) { return }
        $tail = Get-Content $logPath -Tail $MaxLogKeepLines -Encoding utf8
        $header = "--- log rotated at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (was $size bytes) ---"
        Set-Content -Path $logPath -Value (@($header) + $tail) -Encoding utf8
    } catch { }
}
Invoke-LogRotation

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
        try {
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
# SSID detection (via netsh)
# ---------------------------------------------------------------------------
function Get-CurrentSsid {
    # Returns the SSID of the first connected wireless interface, or $null
    # (wired / no wifi / netsh error).
    try {
        $out = netsh wlan show interfaces 2>$null
        if (-not $out) { return $null }
        foreach ($line in $out) {
            # Match "SSID : foo" but NOT "BSSID : ..." — require a word boundary before SSID
            if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$' -and $line -notmatch 'BSSID') {
                $ssid = $Matches[1].Trim()
                if ($ssid) { return $ssid }
            }
        }
    } catch { }
    return $null
}

# ---------------------------------------------------------------------------
# Probe: returns a hashtable describing current connectivity state
# ---------------------------------------------------------------------------
function Test-PortalState {
    try {
        $resp = Invoke-WebRequest -Uri $probeUrl -UseBasicParsing -TimeoutSec 10 `
                                  -MaximumRedirection 5 -SessionVariable s
    } catch {
        return @{ Status = 'Offline'; Error = $_.Exception.Message }
    }
    $finalUrl = $resp.BaseResponse.ResponseUri.AbsoluteUri
    if ($resp.Content -match 'Microsoft Connect Test' -and $finalUrl -notmatch 'fgtauth') {
        return @{ Status = 'Online'; FinalUrl = $finalUrl }
    }
    return @{
        Status   = 'Gated'
        Response = $resp
        FinalUrl = $finalUrl
        Session  = $s
    }
}

# ---------------------------------------------------------------------------
# -Setup
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
    Write-Host 'OK - credentials saved (DPAPI-encrypted) to:' -ForegroundColor Green
    Write-Host "  $credPath"
}

# ---------------------------------------------------------------------------
# -Install
# ---------------------------------------------------------------------------
function Invoke-Install {
    if (-not (Test-Path $vbsPath)) { throw "Launcher not found: $vbsPath" }

    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsPath`""
    $trigLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:UserName

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
    $trigEvent.Delay        = 'PT3S'

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

    $principal = New-ScheduledTaskPrincipal -UserId $env:UserName `
                                            -LogonType Interactive -RunLevel Limited

    $task = New-ScheduledTask -Action $action `
                              -Trigger @($trigLogon, $trigEvent) `
                              -Settings $settings -Principal $principal `
                              -Description 'Auto-login to SLIIT Wi-Fi captive portal'

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask   -TaskName $taskName -InputObject $task | Out-Null

    Write-Host ''
    Write-Host "OK - scheduled task '$taskName' registered." -ForegroundColor Green
    Write-Host 'Triggers:'
    Write-Host '  * At user logon'
    Write-Host '  * Network connect (NetworkProfile event 10000, +3s delay)'
}

# ---------------------------------------------------------------------------
# -Uninstall
# ---------------------------------------------------------------------------
function Invoke-Uninstall {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$taskName'." -ForegroundColor Yellow

    if (Test-Path $credPath) {
        $delete = $Force
        if (-not $Force) {
            $ans = Read-Host 'Also delete saved credentials (creds.xml)? [y/N]'
            $delete = ($ans -match '^(y|yes)$')
        }
        if ($delete) {
            Remove-Item $credPath -Force
            Write-Host 'Deleted creds.xml.' -ForegroundColor Yellow
        } else {
            Write-Host 'Kept creds.xml.'
        }
    }
    if (Test-Path $debugHtml) {
        Remove-Item $debugHtml -Force -ErrorAction SilentlyContinue
    }
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
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # --- SSID filter (skip cheap & early if not on SLIIT) ------------------
    $ssid = Get-CurrentSsid
    if ($ssid -and $SsidFilter -and ($ssid -notlike $SsidFilter)) {
        Write-Log "SSID '$ssid' does not match filter '$SsidFilter' - skipping."
        exit 0
    }
    if ($ssid) {
        Write-Log "On Wi-Fi SSID: $ssid"
    } else {
        Write-Log 'No Wi-Fi SSID detected (wired or unknown) - proceeding.'
    }

    $cred = Get-PortalCredential
    $user = $cred.UserName
    $pass = $cred.GetNetworkCredential().Password

    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        Write-Log "Attempt $i/$attempts - probing $probeUrl"
        $state = Test-PortalState

        if ($state.Status -eq 'Offline') {
            Write-Log "Probe failed: $($state.Error)"
            if ($i -lt $attempts) { Start-Sleep -Seconds ([int][Math]::Pow(2, $i)); continue }
            throw $state.Error
        }

        Write-Log "Landed: $($state.FinalUrl)"

        if ($state.Status -eq 'Online') {
            Write-Log 'Already online - exiting.'
            exit 0
        }

        # --- Gated. Parse magic + 4Tredir from FortiGate response ----------
        $resp = $state.Response
        $session = $state.Session
        $finalUrl = $state.FinalUrl

        # Dump portal HTML on first gated run (or on -DryRun) for debugging
        if ($DryRun -or -not (Test-Path $debugHtml)) {
            try {
                Set-Content -Path $debugHtml -Value $resp.Content -Encoding utf8
                Write-Log "Wrote portal HTML to $debugHtml ($($resp.Content.Length) bytes)"
            } catch { Write-Log "Could not dump portal HTML: $($_.Exception.Message)" }
        }

        $magic = $null
        if ($resp.Content -match 'name="?magic"?\s+value="([0-9a-fA-F]+)"') {
            $magic = $Matches[1]
        } elseif ($finalUrl -match 'fgtauth\?([0-9a-fA-F]+)') {
            $magic = $Matches[1]
        }

        $redir = $probeUrl
        if ($resp.Content -match 'name="?4Tredir"?\s+value="([^"]+)"') { $redir = $Matches[1] }

        if (-not $magic) {
            Write-Log 'No magic token in response - not on SLIIT portal? Will retry.'
            if ($i -lt $attempts) { Start-Sleep -Seconds ([int][Math]::Pow(2, $i)); continue }
            Write-Log "Giving up after $attempts attempts."
            exit 3
        }

        $portalBase = ([Uri]$finalUrl).GetLeftPart([UriPartial]::Authority)
        $postUrl    = "$portalBase/"

        Write-Log "Parsed: magic=$magic  4Tredir=$redir  postUrl=$postUrl"

        # --- Dry run: stop here ----------------------------------------------
        if ($DryRun) {
            $passLen = $pass.Length
            Write-Log '[DRY RUN] Would POST the following body (password redacted):'
            Write-Log "[DRY RUN]   4Tredir  = $redir"
            Write-Log "[DRY RUN]   magic    = $magic"
            Write-Log "[DRY RUN]   username = $user"
            Write-Log "[DRY RUN]   password = <redacted, $passLen chars>"
            Write-Log "[DRY RUN] Target   = $postUrl"
            Write-Log "[DRY RUN] Portal HTML saved at $debugHtml"
            Write-Log '[DRY RUN] Nothing submitted. Exit 0.'

            Write-Host ''
            Write-Host "[DRY RUN] magic   : $magic"
            Write-Host "[DRY RUN] 4Tredir : $redir"
            Write-Host "[DRY RUN] target  : $postUrl"
            Write-Host "[DRY RUN] HTML    : $debugHtml"
            Write-Host "[DRY RUN] No credentials submitted." -ForegroundColor Cyan
            exit 0
        }

        # --- Real POST -------------------------------------------------------
        $body = @{
            '4Tredir' = $redir
            magic     = $magic
            username  = $user
            password  = $pass
        }

        Write-Log "POST $postUrl"
        try {
            $null = Invoke-WebRequest -Uri $postUrl -Method Post -Body $body `
                                      -UseBasicParsing -TimeoutSec 15 `
                                      -MaximumRedirection 5 -WebSession $session
        } catch {
            Write-Log "POST failed: $($_.Exception.Message)"
            if ($i -lt $attempts) { Start-Sleep -Seconds ([int][Math]::Pow(2, $i)); continue }
            throw
        }

        # --- Verify by re-probing. This is the real success check. ----------
        Start-Sleep -Seconds 1
        $verify = Test-PortalState
        if ($verify.Status -eq 'Online') {
            Write-Log "Login OK - post-login probe confirms online ($($verify.FinalUrl))."
            exit 0
        }
        Write-Log "Login FAILED - post-login probe still gated/offline: status=$($verify.Status) url=$($verify.FinalUrl)"
        if ($i -lt $attempts) {
            Write-Log 'Retrying...'
            Start-Sleep -Seconds ([int][Math]::Pow(2, $i))
            continue
        }
        exit 2
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
