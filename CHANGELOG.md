# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] - 2026-04-29

First public release. Stable, in-production at SLIIT.

### Features

- **Zero-click auto-login** — Windows Scheduled Task fires on Wi-Fi connect events (`NetworkProfile` event 10000) and at user logon. Internet works within ~5 seconds of joining SLIIT-STD.
- **DPAPI-encrypted credentials** — `creds.xml` is sealed to the current Windows user account. Useless on any other machine.
- **FortiGate `fgtauth` portal support** — handles the JavaScript-based redirect that breaks every standard "follow redirects" library; extracts the session magic token; POSTs login over HTTPS.
- **SSID-aware** — script exits silently on non-SLIIT networks. No HTTP traffic, no log entries, zero impact when off-campus.
- **Robust verification** — confirms login by re-probing the network, not by string-matching error pages. Retries up to 3× with exponential backoff.
- **Native Windows toast notifications** — fire on success (with elapsed time), bad credentials, and portal-not-found. Silent when already authenticated. Suppress with `-Quiet`.
- **`-Doctor` health check** — single command that checks credentials, scheduled task state, current SSID match, and live connectivity. Each issue prints its remediation command.
- **`-DryRun` mode** — full parsing flow without submitting credentials. Useful for verifying portal compatibility on new networks.
- **Self-rotating logs** — `login.log` capped at 256 KB, automatically trimmed to last 500 lines.
- **One-time setup** — double-click `setup.cmd` to enter credentials and register the scheduled task. No admin rights required.
- **Click-to-login fallback** — `login-now.cmd` for manual triggering with visible output.
- **Phone bookmarklet** — included in README; works on any browser (iPhone Safari, Android Chrome, Firefox).

### Files

| File | Purpose |
|---|---|
| `login.ps1` | Main script — login, setup, install, uninstall, doctor, dry-run modes |
| `setup.cmd` | One-time installer — credentials + scheduled task |
| `login-now.cmd` | Manual click-to-login launcher |
| `SLIIT Wifi.vbs` | Silent launcher used by the scheduled task |
| `README.md` | Full documentation |
| `LICENSE` | MIT |
| `CHANGELOG.md` | This file |

### Known limitations

- **Windows only** — macOS/Linux ports are planned for v1.1.
- **FortiGate-specific** — adapter system for other captive portal vendors (Cisco ISE, Aruba, Meraki) is deferred until users request it.

### Tested on

- Windows 11 23H2 + PowerShell 5.1
- SLIIT-STD network (FortiGate captive portal at `https://auth.sliit.lk:1003`)

[1.0.0]: https://github.com/ShageeshanT/sliit-wifi/releases/tag/v1.0.0
