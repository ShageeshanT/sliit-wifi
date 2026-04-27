# SLIIT Wi-Fi Auto-Login

> **Connect to SLIIT Wi-Fi. Get internet. That's it.**
> Zero clicks, zero typing, zero browser popups — every time, automatically.

![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![No deps](https://img.shields.io/badge/dependencies-none-success)
![Credentials](https://img.shields.io/badge/credentials-DPAPI%20encrypted-important)
![License](https://img.shields.io/badge/license-MIT-blue)

```
 ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐
 │ Wi-Fi joined │ ──► │ Task Sched.  │ ──► │  login.ps1       │
 │  (SLIIT-STD) │     │  fires (3s)  │     │  POSTs to portal │
 └──────────────┘     └──────────────┘     └────────┬─────────┘
                                                    │
                                                    ▼
                                         You have internet. Silently.
```

---

## ⚡ The headline feature: fully automatic login

Once installed, **you never interact with this tool again**. It runs in the background as a Windows Scheduled Task that listens for network-connect events. The moment your laptop joins SLIIT-STD, the script:

1. Detects the FortiGate captive portal
2. Follows the JavaScript redirect to the login form
3. Extracts the session token (`magic`)
4. POSTs your credentials over HTTPS
5. Verifies you're online by re-probing the network

All in **under 5 seconds**, with no window flash, no taskbar blip, no notification.

On any other Wi-Fi (home, mobile hotspot, café), the script checks the SSID, sees it's not SLIIT, and exits silently. Zero impact when you're off-campus.

---

## What it actually does

SLIIT's Wi-Fi sits behind a **FortiGate `fgtauth` captive portal** at `https://auth.sliit.lk:1003`. Until you submit your SLIIT credentials there, every HTTP request gets intercepted with a JavaScript-redirect page. This tool automates that submission.

It's a single PowerShell script, no third-party libraries, no installer beyond Windows itself.

### Highlights

- **🔒 Credentials encrypted with Windows DPAPI** — sealed to your user account; useless on any other machine.
- **🤖 Auto-login on Wi-Fi connect** — Scheduled Task triggers on `NetworkProfile` event 10000 (logged every time Windows joins a network).
- **🚦 SSID-aware** — only runs on networks matching `*SLIIT*`; pure no-op everywhere else.
- **🛡️ Robust verification** — confirms login by re-probing, not by string-matching error pages. Retries with exponential backoff.
- **🪵 Self-rotating logs** — `login.log` capped at 256 KB, automatically trimmed.
- **🔍 Dry-run mode** — see exactly what the script would POST, without submitting.
- **📱 Works on phones too** — bookmarklet for one-tap login on iPhone & Android (see below).

---

## Quick start

### Requirements

- Windows 10 or 11
- PowerShell 5.1+ (built-in on every modern Windows)
- A SLIIT account

### 1. Clone the repo

```powershell
git clone https://github.com/<your-username>/sliit-wifi.git "C:\Users\$env:UserName\Desktop\sliit-wifi"
cd "C:\Users\$env:UserName\Desktop\sliit-wifi"
```

### 2. Run setup

Double-click **`setup.cmd`**, or:

```powershell
.\setup.cmd
```

You'll be prompted for:

```
SLIIT username (e.g. it12345678): <your username>
SLIIT password: ****************
```

Enter **your own** SLIIT credentials. They're saved to `creds.xml`, encrypted with Windows DPAPI — only **your** Windows user account can decrypt them.

`setup.cmd` then registers the Scheduled Task. **You're done.**

### 3. Connect to SLIIT-STD

Next time your laptop joins SLIIT Wi-Fi, you'll have internet within seconds. No clicks, no popups.

---

## 📱 Bonus: one-tap login on your phone (free, any device)

Phones can't run Scheduled Tasks, but a **bookmarklet** gets you within one tap of the same experience. Works on iPhone Safari and Android Chrome (Firefox too).

### The bookmarklet

```javascript
javascript:(function(){var u=document.querySelector('input[name="username"]')||document.querySelector('input[type="text"]');var p=document.querySelector('input[name="password"]')||document.querySelector('input[type="password"]');if(!u||!p){alert('Not on SLIIT login page');return;}u.value='YOUR_USERNAME';p.value='YOUR_PASSWORD';(u.form||document.forms[0]).submit();})();
```

Replace `YOUR_USERNAME` and `YOUR_PASSWORD` with your own.

> ⚠️ If your password contains `#`, escape it as `\x23` (URLs treat `#` as an anchor and would chop your bookmark in half).

### Setup

1. Bookmark any random page in your phone browser.
2. Edit the bookmark.
3. Replace the URL with the `javascript:...` line above (with your credentials).
4. Save it as `SLIIT Login`.

### Daily use

1. Connect to SLIIT-STD, **swipe away** the "Sign in to network" notification.
2. Open Chrome/Safari → type `neverssl.com` → you get redirected to the SLIIT portal.
3. Tap your bookmark → done.

> **Android Chrome quirk:** Chrome silently strips `javascript:` from bookmark URLs sometimes. If your bookmark doesn't fire, edit it and manually retype `javascript:` at the start of the URL. If even that fails, tap the address bar, type `SLIIT`, and tap the bookmark **suggestion** — that always works.

---

## Customizing for a different captive portal

This tool is built for SLIIT but the FortiGate `fgtauth` flow is **identical across many universities and offices**. To adapt it:

Open `login.ps1` and edit the **Configurable** section near the top:

```powershell
# Skip the login flow if the current Wi-Fi SSID doesn't match this wildcard.
$SsidFilter = '*SLIIT*'   # Change to '*YourUni*' or set to $null to disable
```

The portal URL is auto-discovered from the JS-redirect, so you usually don't need to change anything else. If your network's portal lives somewhere unusual:

- **Probe URL** (`$probeUrl`) — defaults to `http://www.msftconnecttest.com/connecttest.txt`. Change if your network whitelists this.
- **Token regex** — currently matches FortiGate's `name="magic"` field with a hex value. If your portal uses a different token name, edit the parsing block in the main login flow.

The architecture is designed to be portable. Open an issue if you hit a portal we don't handle.

---

## Commands cheatsheet

| What you want | Command |
|---|---|
| Force a login right now | `Start-ScheduledTask -TaskName 'SLIIT Wifi Auto-Login'` |
| See what the script did last | `Get-Content .\login.log -Tail 20` |
| Manual click-to-login | Double-click `login-now.cmd` |
| Dry-run (parse but don't submit) | `powershell -File .\login.ps1 -DryRun` |
| Change saved password | `powershell -File .\login.ps1 -Setup` |
| Re-install the scheduled task | `powershell -File .\login.ps1 -Install` |
| Disable auto-login temporarily | `Disable-ScheduledTask -TaskName 'SLIIT Wifi Auto-Login'` |
| Re-enable auto-login | `Enable-ScheduledTask -TaskName 'SLIIT Wifi Auto-Login'` |
| Remove everything | `powershell -File .\login.ps1 -Uninstall` |

---

## How it works (technical)

1. **Scheduled Task triggers** on either:
   - User logon, or
   - NetworkProfile event ID `10000` (fires on every Wi-Fi connect), with a 3-second delay so DHCP/DNS settle.
2. **Task runs `SLIIT Wifi.vbs`**, a tiny VBScript wrapper that invokes `login.ps1` with `wscript.exe -WindowStyle Hidden` — completely silent, no flashing window.
3. **`login.ps1` checks the SSID** via `netsh wlan show interfaces`. If it doesn't match `*SLIIT*`, exits immediately (~50 ms).
4. **Probe** `http://www.msftconnecttest.com/connecttest.txt`. Two outcomes:
   - Body is `Microsoft Connect Test` and no redirect → already online → exit.
   - Body is FortiGate's interception page (`<script>window.location="..."</script>`) → continue.
5. **Follow the JS redirect manually** to `https://auth.sliit.lk:1003/fgtauth?<magic>`.
6. **Parse the `magic` token** from the form HTML (or fall back to URL query string).
7. **POST** `{ magic, 4Tredir, username, password }` to `https://auth.sliit.lk:1003/`.
8. **Re-probe** the connectivity-test URL. Body of `Microsoft Connect Test` = success. Anything else = failure.
9. **Log the result** to `login.log` and exit.

Up to 3 retries with exponential backoff if the probe or POST fails.

---

## Exit codes

| Code | Meaning |
|-----:|---|
| `0` | Success — logged in, or already online, or off-network |
| `1` | Unexpected error (see log) |
| `2` | Portal rejected credentials — re-run `-Setup` |
| `3` | Couldn't find the FortiGate `magic` token — probably not on a SLIIT-style portal |

---

## File layout

```
sliit-wifi/
├── login.ps1           # Main script (login / -Setup / -Install / -Uninstall / -DryRun)
├── setup.cmd           # Double-click installer — runs -Setup then -Install
├── login-now.cmd       # Click-to-login launcher (visible window, manual override)
├── SLIIT Wifi.vbs      # Silent launcher (used by Scheduled Task; hides PowerShell window)
├── SLIIT Wifi.lnk      # Optional Desktop shortcut
├── creds.xml           # ⚠️ Generated — DPAPI-encrypted credentials (gitignored)
├── login.log           # ⚠️ Generated — rolling log (gitignored)
├── portal-debug.html   # ⚠️ Generated — first-run debug dump (gitignored)
├── README.md
└── .gitignore
```

---

## Security notes

- **`creds.xml` is sealed by Windows DPAPI to your user account.** Another user on the same PC cannot decrypt it. Copying the file to another machine makes it unusable.
- **Nothing is transmitted to third parties.** The script talks only to:
  - `msftconnecttest.com` (Windows' own connectivity probe, returns a 22-byte static response)
  - `auth.sliit.lk:1003` (the FortiGate portal — your credentials' destination)
- **The portal speaks HTTPS** (custom port 1003) — your password is encrypted in transit.
- **The bookmarklet stores credentials in your phone's bookmarks.** Treat it like any saved password — set a phone PIN/biometric.
- **Never commit `creds.xml`, `config.txt`, or `login.log`.** The bundled `.gitignore` handles this.

---

## Troubleshooting

**Log says `Login FAILED — post-login probe still gated`**
Wrong password or expired account. Fix with `powershell -File .\login.ps1 -Setup`.

**Log says `No magic token in response`**
SLIIT's portal HTML changed, or you're on a different network. Send the contents of `portal-debug.html` along with a few log lines and we'll patch the regex.

**Task runs but log doesn't update**
Check `Get-ScheduledTaskInfo -TaskName 'SLIIT Wifi Auto-Login'` → `LastTaskResult`. Anything non-zero means the launcher couldn't start. Usually an `ExecutionPolicy` issue — re-run `setup.cmd`.

**Bookmarklet does nothing on Android**
Chrome stripped the `javascript:` prefix. Edit the bookmark and manually retype `javascript:` at the start. If that fails, use the address-bar-suggestion trick: type the bookmark name in the URL bar and tap the suggestion (not the Go button).

**SSID filter says "does not match" while on SLIIT**
The actual SSID isn't `SLIIT-STD` on your campus. Check `netsh wlan show interfaces` for the real name and update `$SsidFilter` at the top of `login.ps1`.

---

## Uninstall

```powershell
powershell -File .\login.ps1 -Uninstall
```

This removes the Scheduled Task and prompts whether to delete `creds.xml`. Confirm `y` to wipe credentials, or `n` to keep them. Add `-Force` to skip the prompt.

---

## Contributing

Pull requests welcome — especially:

- Adapters for non-FortiGate portals (Cisco ISE, Aruba ClearPass, Meraki, etc.)
- macOS / Linux ports (the core logic is portable; just needs equivalent triggers)
- Better SSID detection on Wi-Fi 7 / multi-adapter setups

Please run `-DryRun` against your portal first and include the captured `portal-debug.html` (with sensitive bits redacted) in your PR.

---

## License

MIT — do whatever you want with it. No warranty.

---

<sub>Built because typing `it12345678` and a password every morning is no way to live. 🍵</sub>
