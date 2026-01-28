# RushResolve Security Remediation Plan

**Audit Date:** 2026-01-28
**Status:** Planning

---

## Priority 1: Critical Fixes

### 1.1 Bundle QRCoder DLL (replaces runtime download)

**Current:** Downloads QRCoder.dll from NuGet at runtime without integrity verification.

**Plan:**
- Download QRCoder 1.4.3 DLL once and commit to `projects/Rush_IT/RushResolveApp/Lib/QRCoder.dll`
- Update RushResolve.ps1 to load from local path: `$qrCoderPath = Join-Path $PSScriptRoot "Lib\QRCoder.dll"`
- Remove all Invoke-WebRequest/download logic for QRCoder
- Add the DLL's SHA256 hash to SECURITY.md for verification reference

**Files:** RushResolve.ps1

---

### 1.2 Fix Invoke-Elevated Argument Injection

**Current:** Arguments are concatenated with `-join ' '` and embedded in script string without escaping.

**Plan:**
- Serialize arguments to XML using `Export-Clixml` to a temp file
- In the elevated script, deserialize with `Import-Clixml`
- Pass the temp file path (validated) instead of raw arguments
- Clean up temp file after execution

**Files:** RushResolve.ps1 (Invoke-Elevated function)

---

### 1.3 Fix Printer Path Case Sensitivity

**Current:** Uses `-contains` which is case-sensitive. Bypass via `\\rudwv-ps401` vs `\\RUDWV-PS401`.

**Plan:**
- Normalize both the input server name and allowlist entries to uppercase before comparison
- Use `.ToUpper()` on both sides of the comparison

**Files:** Modules/03_PrinterManagement.ps1

---

## Priority 2: High Severity Fixes

### 2.1 Fix Clipboard Timer Race Condition

**Current:** Creates orphaned background jobs; no cancellation if user copies something else.

**Plan:**
- Track the clipboard job in `$script:ClipboardClearJob`
- Before starting new timer, stop and remove any existing job
- Store a hash of the password; only clear clipboard if content still matches
- Clean up job on application exit

**Files:** RushResolve.ps1 (Start-ClipboardClearTimer)

---

### 2.2 Fix Module Security Warn Mode

**Current:** In Warn mode, module is dot-sourced BEFORE user sees warning (code already executed).

**Plan:**
- Show Yes/No confirmation dialog BEFORE dot-sourcing
- Only load module if user explicitly approves
- Log all security warnings to session log regardless of user choice

**Files:** RushResolve.ps1 (module loading section)

---

### 2.3 Add LLDP Input Validation

**Current:** Adapter name from dropdown passed directly to elevated cmdlet.

**Plan:**
- Validate adapter name against regex pattern (alphanumeric, spaces, hyphens, underscores, parentheses only)
- Verify adapter exists in current system's adapter list before passing to cmdlet

**Files:** Modules/05_NetworkTools.ps1

---

### 2.4 Replace Forfiles with PowerShell

**Current:** Uses `forfiles.exe` with path parameter vulnerable to special character injection.

**Plan:**
- Replace forfiles with `Get-ChildItem -Recurse | Where-Object { $_.LastWriteTime -lt $cutoffDate }`
- Eliminates cmd.exe shell escaping issues entirely
- Use `-LiteralPath` for all path operations

**Files:** Modules/06_DiskCleanup.ps1

---

## Priority 3: Medium Severity Fixes

### 3.1 Add QR Bitmap Null Check

**Plan:** Add null check after `New-QRCodeBitmap` call, show error dialog if null.

**Files:** RushResolve.ps1

---

### 3.2 Use UTC for PIN Timeout

**Plan:** Change `Get-Date` to `(Get-Date).ToUniversalTime()` for both setting and checking PIN verification time.

**Files:** RushResolve.ps1

---

### 3.3 Add Event Log Query Limits

**Plan:** Add `-MaxEvents 100` to all `Get-WinEvent` calls in diagnostics module.

**Files:** Modules/07_Diagnostics.ps1

---

### 3.4 Enhance Domain Rejoin Warning

**Plan:** Update confirmation message to explicitly warn about computer account deletion, potential data loss, and requirement for domain admin credentials.

**Files:** Modules/04_DomainTools.ps1

---

## Feature: Diagnostics Quick Tools

### Add Quick Tools Panel to Diagnostics Tab

**Rationale:** When diagnostics show recommendations like "run chkdsk /f /r", techs should be able to launch the tool directly from RushResolve instead of opening separate windows.

**Plan:**
- Add a "Quick Tools" GroupBox to Diagnostics tab (below or beside existing buttons)
- Include buttons for common diagnostic/repair tools that match recommendations:

| Tool | Command | Elevation | Notes |
|------|---------|-----------|-------|
| Check Disk | `chkdsk C: /f /r` | Yes | Schedule on reboot for system drive |
| Memory Diagnostic | `mdsched.exe` | Yes | Schedules test on next reboot |
| System File Checker | `sfc /scannow` | Yes | Opens in elevated console |
| DISM Repair | `DISM /Online /Cleanup-Image /RestoreHealth` | Yes | Opens in elevated console |
| Disk Cleanup | `cleanmgr /d C:` | No | Standard cleanup wizard |
| Event Viewer | `eventvwr.msc` | No | For detailed log review |
| Device Manager | `devmgmt.msc` | No | For driver issues |
| Reliability Monitor | `perfmon /rel` | No | Crash/failure history |

**Behavior:**
- Elevated tools use existing `Invoke-Elevated` (after it's fixed)
- Console-based tools (sfc, DISM) open in visible PowerShell window so tech can watch progress
- chkdsk on system drive shows dialog explaining reboot requirement
- Log tool launches to session log

**Files:** Modules/07_Diagnostics.ps1

---

## Configuration Enhancement

### HPIA Path Configuration

**Current:** Checks hardcoded paths for HPImageAssistant.exe.

**Plan:**
- Add `projects/Rush_IT/RushResolveApp/Tools/HPIA/` as first checked path
- Update `$script:GetHPIAPath` to check repo location before system paths
- Document that HPIA can be placed in repo for portable deployment

**Files:** Modules/07_Diagnostics.ps1

---

## Implementation Order

**Phase 1: Critical Security**
1. **Bundle QRCoder DLL** - Eliminates critical download vulnerability
2. **Fix Invoke-Elevated** - Eliminates command injection (needed before Quick Tools)
3. **Fix printer path case** - Quick fix, high impact

**Phase 2: Features & Config**
4. **HPIA path update** - Quick config change
5. **Diagnostics Quick Tools** - Add tool launcher buttons (depends on #2)

**Phase 3: High Severity Security**
6. **Module Warn mode** - Security flow fix
7. **Clipboard timer** - Resource leak + UX fix
8. **Replace forfiles** - Eliminates injection vector
9. **LLDP validation** - Input sanitization

**Phase 4: Polish**
10. **Event log limits** - Performance/robustness
11. **QR null check** - Error handling
12. **UTC timestamps** - Edge case fix
13. **Domain rejoin warning** - UX improvement

---

## Accepted Risks

- **6-digit PIN** - See SECURITY.md for rationale
