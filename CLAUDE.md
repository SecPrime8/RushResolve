# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

RushResolve is a portable PowerShell GUI toolkit for IT Field Services technicians at Rush University Medical Center. It runs from a USB drive on end-user workstations — no installation required. Full product context is in `docs/PRD.md`. Technical spec is in `docs/SPEC.md`.

## Development Workflow

Claude Code runs on WSL with direct filesystem access to `C:\` via `/mnt/c/`. Edits land on Windows immediately — no push/pull cycle needed. Luis runs `.\RushResolve.ps1` on Windows to test, or Claude can verify UI via screenshot/keyboard using the `verify` skill.

**After editing any module file**, update its SHA256 hash in `Security/module-manifest.json` or the module will be blocked on next launch:
```powershell
# Run on Windows to get the new hash:
(Get-FileHash -Path "Modules\02_SoftwareInstaller.ps1" -Algorithm SHA256).Hash
```

## Architecture

`RushResolve.ps1` (3800+ lines) is the entire application. It:
1. Loads WinForms, enforces TLS 1.2+, initializes security/credential/logging systems
2. Calls `Load-Module` for each `.ps1` file in `Modules/` (alphabetical order = tab order)
3. `Load-Module` verifies SHA256 against `Security/module-manifest.json`, dot-sources the file, calls `Initialize-Module -tab $tab`

Modules are **completely isolated** — each builds its own UI within the tab page it receives. The only shared surface is `$script:` variables set in `RushResolve.ps1` (credential functions, `Write-SessionLog`, etc.).

### Module interface (required)

```powershell
$script:ModuleName = "Tab Label"
$script:ModuleDescription = "Tooltip"

function Initialize-Module {
    param([System.Windows.Forms.TabPage]$tab)
    # Build UI, attach to $tab
}
```

### Non-negotiable coding rules

1. **`$script:` scope** on every control referenced in an event handler — local variables are not accessible inside WinForms event closures
2. **No `.GetNewClosure()`** — freezes variable values at closure creation time
3. **ASCII only** — no Unicode box-drawing characters (`─│┌`) in source files
4. **No inline `if` in hashtables** — calculate the value first, then use the variable
5. **`AutoSize = $true` on all buttons** — fixed pixel widths cut off text

## Current Module Status

| File | Tab | Status |
|------|-----|--------|
| `01_SystemInfo.ps1` | System Info | Solid; remove AD/SCCM launcher buttons |
| `02_SoftwareInstaller.ps1` | Software Installer | Works; HPIA needs auto-config if not set up |
| `03_PrinterManagement.ps1` | Printer Management | Regression — printer discovery broken in v2.6 (works in v2.5). Test on Rush network. |
| `05_NetworkTools.ps1` | Network Tools | Solid; WLAN report button added |
| `06_DiskCleanup.ps1` | Disk Cleanup | Rough; needs rework |
| `07_Diagnostics.ps1` | Diagnostics | Works; DISM removed (EUT deemed unsafe), SFC kept |
| `08_AppLocker.ps1` | AppLocker Troubleshooting | **Planned** — replaces removed AD Tools module |

## Security Manifest

`Security/module-manifest.json` — SHA256 whitelist for modules.
`Security/integrity-manifest.json` — Hash of `settings.json` and `RushResolve.ps1` itself.

Security modes in `Config/settings.json`: `Enforced` (blocks unregistered modules), `Warn`, `Disabled`.

## Key Constraints

- **GPO blocks:** WinGet, DISM RestoreHealth (use WIM-based repair instead)
- **Windows Updates:** Managed by hospital — do not add update functionality
- **Elevation:** Never assume admin. Use `Start-ElevatedProcess` / `Invoke-Elevated` for privileged ops — prompts for credentials with optional PIN-protected caching
- **Arguments:** Always pass as arrays to `Start-ElevatedProcess`, never interpolated strings
