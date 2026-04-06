# RushResolve — Technical Specification

**Version:** 3.0
**Author:** Luis Arauz / KILA Strategies
**Date:** April 2026
**Audience:** Developer adding or modifying modules and core features.

---

## Architecture Overview

RushResolve is a single-file launcher (`RushResolve.ps1`) that dot-sources module files at startup and builds a tabbed WinForms GUI. There is no build step — edit the file, run it.

```
RushResolve.ps1          # Main launcher: UI shell, security, credential system, logging, auto-update
    |
    +-- Security/
    |   +-- module-manifest.json    # SHA256 whitelist for all modules
    |   +-- integrity-manifest.json # Hash of settings.json and main script
    |
    +-- Modules/
    |   +-- 01_SystemInfo.ps1       # Dot-sourced at startup
    |   +-- 02_SoftwareInstaller.ps1
    |   +-- 03_PrinterManagement.ps1
    |   +-- 05_NetworkTools.ps1
    |   +-- 06_DiskCleanup.ps1
    |   +-- 07_Diagnostics.ps1
    |   +-- 08_AppLocker.ps1        # (planned)
    |
    +-- Config/
    |   +-- settings.json           # User settings persistence
    |   +-- favorites.json          # Saved favorites
    |
    +-- Lib/
    |   +-- QRCoder.dll             # Bundled, SHA256-verified at load
    |
    +-- Assets/
    |   +-- rush-logo.png
    |
    +-- Logs/                       # Session logs (one file per session)
    +-- Safety/Backups/             # Auto-update backup copies (keeps last 3)
```

**Module loading order:** alphabetical by filename. Use `NN_` prefix to control tab order.

---

## Module Interface Contract

Every module must implement exactly this interface. The main launcher dot-sources the module file, then calls `Initialize-Module`.

### Required variables (set at module scope)

```powershell
$script:ModuleName = "Display Name"           # Tab label
$script:ModuleDescription = "Tooltip text"    # Tab tooltip (optional but recommended)
```

### Required function

```powershell
function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )
    # Build all UI controls and attach to $tab
    # This function is called once at startup
}
```

### Minimal working module

```powershell
$script:ModuleName = "My Module"
$script:ModuleDescription = "Does the thing"

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    $script:myPanel = New-Object System.Windows.Forms.Panel
    $script:myPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:myButton = New-Object System.Windows.Forms.Button
    $script:myButton.Text = "Do Thing"
    $script:myButton.AutoSize = $true

    $script:myButton.Add_Click({
        $script:myPanel.BackColor = [System.Drawing.Color]::LightGreen
    })

    $script:myPanel.Controls.Add($script:myButton)
    $tab.Controls.Add($script:myPanel)
}
```

---

## Critical Coding Rules

These rules exist because of real bugs. Breaking them causes silent failures or frozen event handlers.

### Rule 1: Always use `$script:` scope for controls referenced in event handlers

```powershell
# CORRECT
$script:myTextBox = New-Object System.Windows.Forms.TextBox
$myButton.Add_Click({
    $script:myTextBox.Text = "Updated"    # Works — $script: is accessible in the closure
})

# WRONG
$myTextBox = New-Object System.Windows.Forms.TextBox
$myButton.Add_Click({
    $myTextBox.Text = "Updated"           # Broken — local var not in closure scope
})
```

### Rule 2: Never use `.GetNewClosure()`

It freezes variable values at the time the closure is created. Variables updated later won't be reflected.

```powershell
# NEVER do this
$myButton.Add_Click({ ... }.GetNewClosure())
```

### Rule 3: ASCII only in source files

No Unicode box-drawing characters (`─`, `│`, `┌`, etc.). Use `-`, `|`, `+` instead. Unicode causes encoding issues when files move between systems.

### Rule 4: No inline `if` statements inside hashtables

```powershell
# WRONG — PowerShell hashtable parser chokes on this
$props = @{
    Color = if ($active) { "Red" } else { "Blue" }
}

# CORRECT — calculate before the hashtable
$color = if ($active) { "Red" } else { "Blue" }
$props = @{
    Color = $color
}
```

### Rule 5: Button widths must be dynamic

Do not set `Width` to a fixed pixel value. Use `AutoSize = $true` or calculate from text length.

```powershell
$btn = New-Object System.Windows.Forms.Button
$btn.Text = "Device Manager"
$btn.AutoSize = $true    # Grows to fit the label
```

---

## Security Model

### Module Whitelisting

All modules must be registered in `Security/module-manifest.json` before they will load. The manifest contains SHA256 hashes.

```json
{
  "version": "1.0",
  "modules": [
    { "name": "01_SystemInfo.ps1", "hash": "ABC123..." },
    { "name": "02_SoftwareInstaller.ps1", "hash": "DEF456..." }
  ]
}
```

**After editing a module:** run `Update-SecurityManifests` from within the app (or manually update the hash) — otherwise the module will be blocked on next launch.

Security modes:
- `Enforced` — unregistered/modified modules are blocked entirely
- `Warn` — loads with a warning dialog
- `Disabled` — no checking (development only)

### Credential Caching

- AES-256 encryption with PBKDF2 key derivation (10,000 iterations)
- PIN required to decrypt (6+ digits minimum)
- PIN re-verification after 15 minutes of inactivity
- 3 failed PIN attempts = session lockout with exponential backoff (3s, 6s, 9s)
- Clipboard auto-clears 30 seconds after password copy
- No passwords or PINs are ever written to session logs

### TLS / Network

- TLS 1.2+ enforced globally on startup: `[System.Net.ServicePointManager]::SecurityProtocol = Tls12 -bor Tls13`
- HTTPS-only for all downloads (HTTP URLs rejected)
- SHA256 verification on all downloaded files before execution

### QRCoder Library

`Lib/QRCoder.dll` is verified against a hardcoded SHA256 hash before loading. If the hash doesn't match, the DLL is not loaded (graceful degradation — QR features are disabled, rest of app works).

---

## Credential Elevation System

These functions are defined in `RushResolve.ps1` and available to all modules.

| Function | Purpose |
|----------|---------|
| `Get-ElevatedCredential` | Prompts for admin credentials, optional PIN-protected caching |
| `Invoke-Elevated` | Runs a PowerShell script block with cached/prompted credentials |
| `Start-ElevatedProcess` | Runs an executable with credentials; includes DoEvents polling for UI responsiveness |
| `Clear-CachedCredentials` | Clears in-memory credential cache |
| `Resolve-ToUNCPath` | Converts local/mapped paths to UNC paths for SMB operations |
| `Connect-NetworkShare` | Authenticates to a network share with credential caching |

### Example: install with elevation

```powershell
$result = Start-ElevatedProcess `
    -FilePath "msiexec.exe" `
    -ArgumentList @("/i", "`"$installerPath`"", "/qn") `
    -Wait `
    -Hidden `
    -OperationName "install MyApp"

if ($result.Success) {
    Write-SessionLog "Installed: MyApp"
} else {
    [System.Windows.Forms.MessageBox]::Show("Install failed: $($result.Error)")
}
```

**Important:** Pass arguments as an array, not a single string — prevents command injection.

---

## Session Logging

`Write-SessionLog` is available in all modules. It writes timestamped entries to the current session log file in `Logs/`.

```powershell
Write-SessionLog "Printer added: \\printserver\HP-LaserJet"
Write-SessionLog "ERROR: Failed to flush DNS - $($_.Exception.Message)"
```

Log filename format: `SESSION-COMPUTERNAME-2026-02-10_143522.log`

**Never log:** passwords, PINs, or credential material.

---

## Development Workflow

Claude Code runs on WSL with direct read/write access to the Windows filesystem via `/mnt/c/`. There is no push/pull cycle — edits land on Windows immediately.

```
Claude Code (WSL)           Windows
    |                           |
    +-- Edit /mnt/c/Users/      |
        luisa/KILA Strategies/  |
        projects/Rush_IT/       |
        RushResolve/            |
            |                   |
            +-------------------> Luis runs .\RushResolve.ps1
                                  (or Claude triggers via keyboard/screenshot)
```

### After editing a module

1. Update the module's SHA256 hash in `Security/module-manifest.json`, OR
2. Temporarily set `SecurityMode = "Warn"` in settings for testing, then re-enforce when done

### Running tests

```powershell
# From the RushResolve directory on Windows:
.\Run-Tests.ps1           # All tests
.\Run-Tests.ps1 -Unit     # Unit tests only
.\Run-Tests.ps1 -Integration  # Integration tests only
```

139 Pester tests across 20 test files. Tests live in `Tests/Unit/`, `Tests/Integration/`, `Tests/Mocks/`.

### UI verification

Claude can verify UI work by taking screenshots of the running application and using keyboard input. Use the `verify` skill to trigger this workflow.

---

## Auto-Update Mechanism

Accessed via Help → Check for Updates.

1. Queries GitHub API: `api.github.com/repos/SecPrime8/RushResolve/releases/latest`
2. Shows release notes dialog before downloading
3. Downloads ZIP with progress indicator
4. Verifies SHA256 hash (parsed from release notes body — must be present)
5. Backs up current version to `Safety/Backups/` (keeps last 3)
6. Extracts new version, preserves `Config/settings.json`
7. Validates file count + PowerShell syntax
8. Rolls back automatically on any failure
9. Restarts application

**Publishing a release:** The SHA256 hash of the release ZIP must appear in the GitHub release notes body. The update mechanism parses it from there.

---

## Adding a New Module

1. Create `Modules/NN_ModuleName.ps1` where `NN` is the desired tab order (e.g., `08_AppLocker.ps1`)

2. Implement the interface contract (see above)

3. Register the module in `Security/module-manifest.json`:
   ```powershell
   # Get the hash:
   (Get-FileHash -Path "Modules\08_AppLocker.ps1" -Algorithm SHA256).Hash
   ```

4. Test: run `RushResolve.ps1` — new tab should appear

5. Run the test suite: `.\Run-Tests.ps1`

### Module template

```powershell
<#
.SYNOPSIS
    [Module Name] for Rush Resolve
.DESCRIPTION
    [What this module does]
#>

$script:ModuleName = "[Display Name]"
$script:ModuleDescription = "[Tooltip text]"

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Main container
    $script:mainPanel = New-Object System.Windows.Forms.Panel
    $script:mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    # Output log (recommended pattern for async/elevated operations)
    $script:logBox = New-Object System.Windows.Forms.TextBox
    $script:logBox.Multiline = $true
    $script:logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:logBox.ReadOnly = $true
    $script:logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:logBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    # Action button
    $script:actionButton = New-Object System.Windows.Forms.Button
    $script:actionButton.Text = "Run"
    $script:actionButton.AutoSize = $true

    $script:actionButton.Add_Click({
        $script:logBox.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Starting...`r`n")
        Write-SessionLog "[$script:ModuleName] Action triggered"

        # Your logic here
        # Use Start-ElevatedProcess or Invoke-Elevated for admin operations
    })

    # Layout
    $script:buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $script:buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $script:buttonPanel.AutoSize = $true
    $script:buttonPanel.Controls.Add($script:actionButton)

    $script:mainPanel.Controls.Add($script:logBox)
    $script:mainPanel.Controls.Add($script:buttonPanel)
    $tab.Controls.Add($script:mainPanel)
}
```

---

## Future Architecture Notes

### M365 Telemetry Layer

When the reporting layer is implemented, the pattern should:
- Write session data to a local JSON file during the session
- On session close, upload to SharePoint via `Invoke-RestMethod` with M365 OAuth (or PnP PowerShell)
- No new ports required — uses existing M365 HTTPS endpoints
- Graceful degradation: if upload fails (offline), queue locally and retry next session

### Guided Workflow Engine (v3)

The long-term architecture replaces static module buttons with a decision-tree engine:
- Workflow definitions stored as JSON (or fetched from SharePoint)
- Each step can be: instruction, question, action (runs PowerShell), or branch
- Cryptographic signature on workflow files: ECDSA or RSA signature from a known public key, verified before loading
- New workflows pushed to techs automatically via the existing auto-update channel

This is a v3 architectural shift. Current modules remain compatible — they become the "action" implementations that workflows call.

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| 3.0 | 2026-04-05 | Initial spec — written from codebase review + requirements interview |
