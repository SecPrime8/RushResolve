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

1. **Bundle QRCoder DLL** - Eliminates critical download vulnerability
2. **Fix Invoke-Elevated** - Eliminates command injection
3. **Fix printer path case** - Quick fix, high impact
4. **HPIA path update** - Quick config change
5. **Module Warn mode** - Security flow fix
6. **Clipboard timer** - Resource leak + UX fix
7. **Replace forfiles** - Eliminates injection vector
8. **LLDP validation** - Input sanitization
9. **Event log limits** - Performance/robustness
10. **QR null check** - Error handling
11. **UTC timestamps** - Edge case fix
12. **Domain rejoin warning** - UX improvement

---

## Accepted Risks

- **6-digit PIN** - See SECURITY.md for rationale
