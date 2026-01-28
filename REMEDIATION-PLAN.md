# RushResolve Security Remediation Plan

**Audit Date:** 2026-01-28
**Status:** Phase 1 & 2 Complete

---

## Priority 1: Critical Fixes

### 1.1 Bundle QRCoder DLL (replaces runtime download) - COMPLETE

**Status:** Implemented 2026-01-28

**Implementation:**
- Bundled QRCoder 1.4.3 DLL to `Lib/QRCoder.dll`
- Added SHA256 hash verification on load (fails if hash mismatch)
- Removed all runtime download logic
- Hash documented in SECURITY.md

**Commit:** `b99be8ce security(Rush_IT): Bundle QRCoder DLL with hash verification`

---

### 1.2 Fix Invoke-Elevated Argument Injection - COMPLETE

**Status:** Implemented 2026-01-28

**Implementation:**
- Arguments serialized via `Export-Clixml` to secure temp file
- Elevated script deserializes with `Import-Clixml`
- Temp file cleaned up after execution
- No string concatenation of user-controlled input

**Commit:** `b8e0ac24 security(Rush_IT): Fix Invoke-Elevated argument injection`

---

### 1.3 Fix Printer Path Case Sensitivity - NO FIX NEEDED

**Status:** Already secure

**Finding:** Code already uses `-ieq` (case-insensitive equals) for server comparison.
The audit finding was based on incomplete code review.

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

## Feature: Diagnostics Quick Tools - COMPLETE

### Add Quick Tools Panel to Diagnostics Tab

**Status:** Implemented 2026-01-28

**Implementation:**
- Added "Quick Tools" GroupBox to Diagnostics tab below diagnostic buttons
- Implemented all planned tool buttons:

| Tool | Command | Status |
|------|---------|--------|
| Check Disk | `chkdsk C: /f /r` | Implemented (with reboot warning) |
| Memory Diagnostic | `mdsched.exe` | Existing button in main panel |
| System File Checker | `sfc /scannow` | Implemented (elevated console) |
| DISM Repair | `DISM /Online /Cleanup-Image /RestoreHealth` | Implemented (elevated console) |
| Disk Cleanup | `cleanmgr /d C:` | Implemented |
| Event Viewer | `eventvwr.msc` | Implemented |
| Device Manager | `devmgmt.msc` | Implemented |
| Reliability Monitor | `perfmon /rel` | Implemented |

**Commit:** `b5102c95 feat(Rush_IT): Add Quick Tools panel + HPIA path config`

---

## Configuration Enhancement - COMPLETE

### HPIA Path Configuration

**Status:** Implemented 2026-01-28

**Implementation:**
- `$script:GetHPIAPath` now checks `Tools/HPIA/HPImageAssistant.exe` first
- Falls back to system paths if not found in repo
- HPIA can now be bundled for portable deployment

**Commit:** `b5102c95 feat(Rush_IT): Add Quick Tools panel + HPIA path config`

---

## Implementation Order

**Phase 1: Critical Security** - COMPLETE
1. ~~**Bundle QRCoder DLL**~~ - DONE
2. ~~**Fix Invoke-Elevated**~~ - DONE
3. ~~**Fix printer path case**~~ - Already secure (no fix needed)

**Phase 2: Features & Config** - COMPLETE
4. ~~**HPIA path update**~~ - DONE
5. ~~**Diagnostics Quick Tools**~~ - DONE

**Phase 3: High Severity Security** - PENDING
6. **Module Warn mode** - Security flow fix
7. **Clipboard timer** - Resource leak + UX fix
8. **Replace forfiles** - Eliminates injection vector
9. **LLDP validation** - Input sanitization

**Phase 4: Polish** - PENDING
10. **Event log limits** - Performance/robustness
11. **QR null check** - Error handling
12. **UTC timestamps** - Edge case fix
13. **Domain rejoin warning** - UX improvement

---

## Accepted Risks

- **6-digit PIN** - See SECURITY.md for rationale
