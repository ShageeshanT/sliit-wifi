# SLIIT Wi-Fi auto-login (FortiGate fgtauth captive portal)
# Version: 1.1.0
# https://github.com/ShageeshanT/sliit-wifi
#
# Modes:
#   login.ps1                - run the login flow (default)
#   login.ps1 -DryRun        - full flow except the final POST; prints what it would send
#   login.ps1 -Setup         - GUI setup: enter credentials and install the task
#   login.ps1 -SetupConsole  - same as -Setup but via console prompts (no GUI)
#   login.ps1 -Install       - register the scheduled task (on-logon + on-network-connect)
#   login.ps1 -Uninstall     - remove the scheduled task (prompts to delete creds too)
#   login.ps1 -Doctor        - print a health check of the entire system
#
# Flags:
#   -Quiet               - suppress toast notifications (logs still write)
#   -Force               - skip "delete creds.xml?" prompt during -Uninstall
#
# Credentials are stored in creds.xml via Export-Clixml - DPAPI-encrypted under
# the current Windows user. No other account on this machine can decrypt them.

[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$SetupConsole,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$Doctor,
    [switch]$Quiet,
    [switch]$Force
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
# Toast notifications (Windows 10/11 native, no extra modules)
# ---------------------------------------------------------------------------
$ToastAppId = 'SLIIT.WiFi.AutoLogin'

function Register-ToastAppId {
    # One-time registration so toasts attribute to "SLIIT Wi-Fi" instead of
    # "PowerShell". Idempotent.
    $regPath = "HKCU:\Software\Classes\AppUserModelId\$ToastAppId"
    if (Test-Path $regPath) { return }
    try {
        New-Item -Path $regPath -Force | Out-Null
        Set-ItemProperty -Path $regPath -Name DisplayName -Value 'SLIIT Wi-Fi'
        Set-ItemProperty -Path $regPath -Name ShowInSettings -Value 0 -Type DWord
    } catch { }
}

function Show-LoginToast {
    param(
        [Parameter(Mandatory)][ValidateSet('Success','Failure','Warning')]
        [string]$Type,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Quiet) { return }
    try {
        Register-ToastAppId
        # Load WinRT assemblies (lazy; only when actually showing a toast)
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        # XML-escape the dynamic strings
        $titleEsc = [System.Security.SecurityElement]::Escape($Title)
        $msgEsc   = [System.Security.SecurityElement]::Escape($Message)

        $template = @"
<toast><visual><binding template="ToastGeneric">
<text>$titleEsc</text>
<text>$msgEsc</text>
</binding></visual></toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show($toast)
    } catch {
        Write-Log "Toast failed: $($_.Exception.Message)"
    }
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
# -SetupConsole : original CLI prompts (for power users / scripted installs)
# ---------------------------------------------------------------------------
function Invoke-SetupConsole {
    Write-Host ''
    Write-Host 'SLIIT Wi-Fi credential setup' -ForegroundColor Cyan
    Write-Host '----------------------------'
    $u = Read-Host 'SLIIT username (e.g. it12345678)'
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
# -Setup : WinForms GUI (default user-facing setup experience)
# ---------------------------------------------------------------------------
function Invoke-SetupGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- Form ---------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text             = 'SLIIT Wi-Fi Setup'
    $form.Size             = New-Object System.Drawing.Size(460, 380)
    $form.StartPosition    = 'CenterScreen'
    $form.FormBorderStyle  = 'FixedDialog'
    $form.MaximizeBox      = $false
    $form.MinimizeBox      = $false
    $form.Topmost          = $true
    $form.BackColor        = [System.Drawing.Color]::White
    $form.Font             = New-Object System.Drawing.Font('Segoe UI', 9)

    # --- Header -------------------------------------------------------------
    $header           = New-Object System.Windows.Forms.Label
    $header.Text      = 'SLIIT Wi-Fi Auto-Login'
    $header.Font      = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $header.ForeColor = [System.Drawing.Color]::FromArgb(0, 60, 120)
    $header.Location  = New-Object System.Drawing.Point(24, 18)
    $header.Size      = New-Object System.Drawing.Size(400, 28)
    $form.Controls.Add($header)

    # --- Subheader ----------------------------------------------------------
    $sub          = New-Object System.Windows.Forms.Label
    $sub.Text     = 'Enter your SLIIT credentials. Encrypted with Windows DPAPI - only your account on this PC can decrypt.'
    $sub.Location = New-Object System.Drawing.Point(24, 50)
    $sub.Size     = New-Object System.Drawing.Size(400, 36)
    $sub.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($sub)

    # --- Username -----------------------------------------------------------
    $userLbl          = New-Object System.Windows.Forms.Label
    $userLbl.Text     = 'Username (e.g. it12345678)'
    $userLbl.Location = New-Object System.Drawing.Point(24, 100)
    $userLbl.Size     = New-Object System.Drawing.Size(300, 20)
    $form.Controls.Add($userLbl)

    $userBox          = New-Object System.Windows.Forms.TextBox
    $userBox.Location = New-Object System.Drawing.Point(24, 122)
    $userBox.Size     = New-Object System.Drawing.Size(400, 25)
    $userBox.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.Controls.Add($userBox)

    # --- Password -----------------------------------------------------------
    $passLbl          = New-Object System.Windows.Forms.Label
    $passLbl.Text     = 'Password'
    $passLbl.Location = New-Object System.Drawing.Point(24, 158)
    $passLbl.Size     = New-Object System.Drawing.Size(120, 20)
    $form.Controls.Add($passLbl)

    $passBox          = New-Object System.Windows.Forms.TextBox
    $passBox.Location = New-Object System.Drawing.Point(24, 180)
    $passBox.Size     = New-Object System.Drawing.Size(400, 25)
    $passBox.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
    $passBox.UseSystemPasswordChar = $true
    $form.Controls.Add($passBox)

    # --- Install task checkbox ---------------------------------------------
    $taskCb          = New-Object System.Windows.Forms.CheckBox
    $taskCb.Text     = 'Also install auto-login (recommended)'
    $taskCb.Location = New-Object System.Drawing.Point(24, 220)
    $taskCb.Size     = New-Object System.Drawing.Size(400, 25)
    $taskCb.Checked  = $true
    $form.Controls.Add($taskCb)

    # --- Status label -------------------------------------------------------
    $status          = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(24, 252)
    $status.Size     = New-Object System.Drawing.Size(400, 38)
    $status.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($status)

    # --- Buttons ------------------------------------------------------------
    $save             = New-Object System.Windows.Forms.Button
    $save.Text        = 'Save'
    $save.Location    = New-Object System.Drawing.Point(254, 298)
    $save.Size        = New-Object System.Drawing.Size(80, 32)
    $save.BackColor   = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $save.ForeColor   = [System.Drawing.Color]::White
    $save.FlatStyle   = 'Flat'
    $save.FlatAppearance.BorderSize = 0
    $form.Controls.Add($save)
    $form.AcceptButton = $save

    $cancel           = New-Object System.Windows.Forms.Button
    $cancel.Text      = 'Cancel'
    $cancel.Location  = New-Object System.Drawing.Point(344, 298)
    $cancel.Size      = New-Object System.Drawing.Size(80, 32)
    $cancel.FlatStyle = 'Flat'
    $form.Controls.Add($cancel)
    $form.CancelButton = $cancel

    # --- Pre-fill if creds already exist ------------------------------------
    if (Test-Path $credPath) {
        try {
            $existing = Import-Clixml $credPath
            $userBox.Text = $existing.UserName
            $sub.Text = "Update credentials for $($existing.UserName), or enter a different account."
            $passBox.Focus() | Out-Null
        } catch { }
    } else {
        $userBox.Focus() | Out-Null
    }

    # --- Save handler -------------------------------------------------------
    $save.Add_Click({
        $u = $userBox.Text.Trim()
        $p = $passBox.Text
        if (-not $u) {
            $status.Text = 'Username cannot be empty.'
            $status.ForeColor = [System.Drawing.Color]::Crimson
            $userBox.Focus() | Out-Null
            return
        }
        if (-not $p) {
            $status.Text = 'Password cannot be empty.'
            $status.ForeColor = [System.Drawing.Color]::Crimson
            $passBox.Focus() | Out-Null
            return
        }
        try {
            $save.Enabled = $false
            $cancel.Enabled = $false
            $status.Text = 'Saving credentials...'
            $status.ForeColor = [System.Drawing.Color]::DimGray
            $form.Refresh()

            $sec = ConvertTo-SecureString $p -AsPlainText -Force
            Save-PortalCredential -User $u -SecPass $sec
            if (Test-Path $oldCfg) { Remove-Item $oldCfg -Force }

            if ($taskCb.Checked) {
                $status.Text = 'Installing auto-login scheduled task...'
                $form.Refresh()
                Invoke-Install | Out-Null
                $status.Text = "All set. Auto-login will fire next time you join SLIIT-STD."
            } else {
                $status.Text = 'Credentials saved. Auto-login NOT installed (use -Install later).'
            }
            $status.ForeColor = [System.Drawing.Color]::SeaGreen

            # Auto-close after 1.5s
            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = 1500
            $timer.Add_Tick({ $timer.Stop(); $form.Close() })
            $timer.Start()
        } catch {
            $status.Text = "Error: $($_.Exception.Message)"
            $status.ForeColor = [System.Drawing.Color]::Crimson
            $save.Enabled = $true
            $cancel.Enabled = $true
        }
    })

    [void]$form.ShowDialog()
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
# -Doctor : health-check diagnostic
# ---------------------------------------------------------------------------
function Invoke-Doctor {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $issues = 0
    function Mark-Issue { $script:issues++ }

    Write-Host ''
    Write-Host 'SLIIT Wi-Fi Auto-Login - Health Check' -ForegroundColor Cyan
    Write-Host ('-' * 41)

    # --- 1. Credentials ----------------------------------------------------
    if (Test-Path $credPath) {
        try {
            $cred = Import-Clixml $credPath
            Write-Host ("[OK] Credentials saved      ({0})" -f $cred.UserName) -ForegroundColor Green
        } catch {
            Write-Host '[X]  Credentials unreadable - run: powershell -File login.ps1 -Setup' -ForegroundColor Red
            Mark-Issue
        }
    } else {
        Write-Host '[X]  No credentials saved   - run: powershell -File login.ps1 -Setup' -ForegroundColor Red
        Mark-Issue
    }

    # --- 2. Scheduled task -------------------------------------------------
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        $lastRun = if ($info.LastRunTime -gt [datetime]'2000-01-01') {
            $info.LastRunTime.ToString('MM/dd HH:mm')
        } else { 'never' }
        $exit = $info.LastTaskResult
        if ($task.State -eq 'Disabled') {
            Write-Host '[!]  Scheduled task         disabled - re-enable: Enable-ScheduledTask -TaskName ''SLIIT Wifi Auto-Login''' -ForegroundColor Yellow
            Mark-Issue
        } elseif ($exit -eq 0 -or $exit -eq 267011) {
            # 267011 = task has not yet run (fresh install)
            Write-Host ("[OK] Scheduled task active  (last run: {0}, exit {1})" -f $lastRun, $exit) -ForegroundColor Green
        } else {
            Write-Host ("[!]  Scheduled task         last failed (last run: {0}, exit 0x{1:X})" -f $lastRun, $exit) -ForegroundColor Yellow
            Write-Host '     Check log: Get-Content login.log -Tail 20'
            Mark-Issue
        }
    } else {
        Write-Host '[X]  Task not registered    - run: powershell -File login.ps1 -Install' -ForegroundColor Red
        Mark-Issue
    }

    # --- 3. SSID -----------------------------------------------------------
    $currSsid = Get-CurrentSsid
    if ($currSsid) {
        if (-not $SsidFilter -or ($currSsid -like $SsidFilter)) {
            Write-Host ("[OK] On Wi-Fi               ({0} - matches filter '{1}')" -f $currSsid, $SsidFilter) -ForegroundColor Green
        } else {
            Write-Host ("[!]  On Wi-Fi               ({0} - does not match filter '{1}')" -f $currSsid, $SsidFilter) -ForegroundColor Yellow
            Write-Host "     Edit `$SsidFilter at top of login.ps1 if this is your campus network."
        }
    } else {
        Write-Host '[!]  No Wi-Fi SSID detected (wired or disconnected)' -ForegroundColor Yellow
    }

    # --- 4. Connectivity / portal ------------------------------------------
    Write-Host '[..] Probing connectivity...' -NoNewline
    $state = Test-PortalState
    Write-Host "`r" -NoNewline
    switch ($state.Status) {
        'Online' {
            Write-Host ("[OK] Connectivity           online (no captive portal)              ") -ForegroundColor Green
        }
        'Gated' {
            $hint = ''
            if ($state.Response.Content -match 'fgtauth\?([0-9a-fA-F]+)') {
                $token = $Matches[1]
                $short = $token.Substring(0, [Math]::Min(8, $token.Length))
                $hint = " (FortiGate, magic=${short}...)"
            }
            Write-Host ("[!]  Connectivity           gated by captive portal$hint    ") -ForegroundColor Yellow
            Write-Host '     Run: powershell -File login.ps1   # to log in now'
        }
        'Offline' {
            Write-Host ("[X]  Connectivity           offline ({0})    " -f $state.Error) -ForegroundColor Red
            Mark-Issue
        }
    }

    # --- Recent log --------------------------------------------------------
    Write-Host ''
    Write-Host 'Recent log:' -ForegroundColor Cyan
    if (Test-Path $logPath) {
        Get-Content $logPath -Tail 5 | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host '  (no log file yet)'
    }

    # --- Summary -----------------------------------------------------------
    Write-Host ''
    if ($issues -eq 0) {
        Write-Host 'All checks passed.' -ForegroundColor Green
    } else {
        Write-Host ("{0} issue(s) found - see above for fixes." -f $issues) -ForegroundColor Yellow
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------------
if ($Setup)        { Invoke-SetupGui;     exit 0 }
if ($SetupConsole) { Invoke-SetupConsole; exit 0 }
if ($Install)      { Invoke-Install;      exit 0 }
if ($Uninstall)    { Invoke-Uninstall;    exit 0 }
if ($Doctor)       { Invoke-Doctor;       exit 0 }

# ---------------------------------------------------------------------------
# Default mode: run login flow
# ---------------------------------------------------------------------------
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $loginStart = Get-Date

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

        # SLIIT's FortiGate intercepts with a tiny HTML page containing a
        # JavaScript redirect (not an HTTP 302), so Invoke-WebRequest doesn't
        # follow it automatically. Detect and follow it manually.
        if ($resp.Content -match 'window\.location\s*=\s*["'']([^"'']*fgtauth[^"'']*)["'']') {
            $jsUrl = $Matches[1]
            Write-Log "JS redirect detected -> $jsUrl"
            try {
                $resp     = Invoke-WebRequest -Uri $jsUrl -UseBasicParsing -TimeoutSec 10 `
                                              -MaximumRedirection 5 -WebSession $session
                $finalUrl = $resp.BaseResponse.ResponseUri.AbsoluteUri
                Write-Log "Followed to: $finalUrl ($($resp.Content.Length) bytes)"
            } catch {
                # Even if fetching the real portal fails, we can still POST —
                # the magic is in the URL query string.
                Write-Log "Could not fetch JS target: $($_.Exception.Message)"
                $finalUrl = $jsUrl
            }
        }

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
            Show-LoginToast -Type Failure -Title 'SLIIT login: portal not detected' `
                            -Message 'Could not find a FortiGate captive portal. May not be on a SLIIT network.'
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
            $elapsed = [Math]::Round(((Get-Date) - $loginStart).TotalSeconds, 1)
            Write-Log "Login OK - post-login probe confirms online ($($verify.FinalUrl))."
            Show-LoginToast -Type Success -Title 'Logged in to SLIIT' `
                            -Message "Authenticated as $user in ${elapsed}s"
            exit 0
        }
        Write-Log "Login FAILED - post-login probe still gated/offline: status=$($verify.Status) url=$($verify.FinalUrl)"
        if ($i -lt $attempts) {
            Write-Log 'Retrying...'
            Start-Sleep -Seconds ([int][Math]::Pow(2, $i))
            continue
        }
        Show-LoginToast -Type Failure -Title 'SLIIT login rejected' `
                        -Message 'Portal did not accept credentials. Run setup.cmd to update password.'
        exit 2
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Show-LoginToast -Type Failure -Title 'SLIIT auto-login error' `
                    -Message $_.Exception.Message
    exit 1
}
