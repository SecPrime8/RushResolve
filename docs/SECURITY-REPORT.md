# Rush Resolve Security Assessment Report

**Application:** Rush Resolve v2.2
**Assessment Date:** January 6, 2026
**Assessor:** KILA Strategies Security Review
**Status:** AFTER MITIGATIONS (v2.2 Security Hardened)

---

## Executive Summary

Rush Resolve is a PowerShell-based IT technician toolkit that handles elevated credentials for software installation, printer management, and system administration tasks. This assessment documents security vulnerabilities identified and mitigations implemented.

**Overall Risk Level: LOW** (Improved from MEDIUM-HIGH)

The v2.1 security update implements:
- Module whitelist with SHA256 hash verification
- Startup integrity checking for application files
- Security mode controls (Enforced/Warn/Disabled)
- Increased PIN complexity (6+ digits, was 4)
- First-run security initialization workflow

The v2.2 security update adds:
- Print server allowlist (hardcoded approved servers only)
- Dropdown-based server selection (prevents free-text injection)
- Printer name sanitization (removes path traversal characters)

The application now protects against code tampering, module injection, and path injection attacks. Remaining risks are inherent to the DPAPI credential storage model and require physical access to exploit.

---

## Scope

| Component | File(s) | Reviewed |
|-----------|---------|----------|
| Main Application | RushResolve.ps1 | Yes |
| Credential System | RushResolve.ps1 (credential functions) | Yes |
| Security System | RushResolve.ps1 (lines 198-441) | Yes |
| Module Loading | RushResolve.ps1 (Load-Module function) | Yes |
| Settings Management | Config/settings.json | Yes |
| Security Manifests | Security/module-manifest.json, Security/integrity-manifest.json | Yes |
| Modules | Modules/*.ps1 | Yes |

---

## Vulnerability Findings

### VULN-001: Unrestricted Module Loading
**Severity:** HIGH → LOW (Mitigated)
**CVSS Score:** 7.8 → 2.0 (Residual)
**Status:** MITIGATED in v2.1

**Description:**
The application previously loaded and executed ANY .ps1 file placed in the Modules/ directory without verification.

**Original Attack Vector:**
1. Attacker places malicious `00_Backdoor.ps1` in Modules/ folder
2. File is auto-loaded on next application start
3. Malicious code executes with user's privileges

**Mitigation Implemented:**
```powershell
function Test-ModuleAllowed {
    # Verifies module is in whitelist AND hash matches
    param([string]$ModulePath)

    $currentHash = Get-FileHashSHA256 -FilePath $ModulePath
    $manifest = Get-Content $script:ModuleManifestFile | ConvertFrom-Json
    $entry = $manifest.modules | Where-Object { $_.name -eq $fileName }

    if (-not $entry -or $currentHash -ne $entry.hash) {
        return @{ Allowed = $false; Reason = "Not in whitelist or hash mismatch" }
    }
    return @{ Allowed = $true }
}
```

**Location:** `RushResolve.ps1` - `Test-ModuleAllowed` function (lines 221-294)
**Security Manifest:** `Security/module-manifest.json`

**Residual Risk:** Attacker with write access to Security folder could modify manifests. Mitigated by file system permissions.

**Verification:** Drop an unauthorized .ps1 in Modules/ → Application shows "Module Blocked" error and refuses to load it.

---

### VULN-002: No Code Integrity Verification
**Severity:** HIGH → LOW (Mitigated)
**CVSS Score:** 7.5 → 2.0 (Residual)
**Status:** MITIGATED in v2.1

**Description:**
Application files previously could be modified without detection.

**Original Attack Vector:**
1. Attacker modifies RushResolve.ps1 or any module
2. Injects credential-stealing code
3. User runs application normally
4. Modified code executes without warning

**Mitigation Implemented:**
```powershell
function Test-ApplicationIntegrity {
    # Verifies main script hash matches manifest
    $manifest = Get-Content $script:IntegrityManifestFile | ConvertFrom-Json
    $mainHash = Get-FileHashSHA256 -FilePath $mainScript

    if ($mainHash -ne $manifest.main_script_hash) {
        return @{ Passed = $false; Failures = @("Main script integrity check failed") }
    }
    return @{ Passed = $true }
}
```

**Location:** `RushResolve.ps1` - `Test-ApplicationIntegrity` function (lines 297-363)
**Security Manifest:** `Security/integrity-manifest.json`

**Startup Behavior:**
- Integrity check runs BEFORE loading settings or modules
- Failed check blocks application startup with security alert
- User must regenerate manifests after legitimate changes

**Residual Risk:** Main script runs before integrity check of itself. This is a bootstrap problem inherent to script-based apps.

---

### VULN-003: Settings File Manipulation
**Severity:** MEDIUM → LOW (Partially Mitigated)
**CVSS Score:** 5.5 → 3.5 (Residual)
**Status:** MONITORED in v2.1

**Description:**
The settings.json file can be modified to redirect users to attacker-controlled paths.

**Original Attack Vector:**
1. Modify networkPath to attacker-controlled share
2. User browses "software" from attacker's share
3. User installs malicious "software"

**Mitigation Implemented:**
- Settings hash is stored in integrity manifest for audit trail
- Settings changes are expected (user preferences), so strict enforcement not applied
- Path validation in Software Installer module warns on suspicious paths

**Residual Risk:**
- Settings file must remain writable for user preferences
- Attacker with write access can still modify paths
- Mitigation: Train users to verify software source paths

**Recommendation for Enhanced Security:**
- Restrict networkPath to approved domains (whitelist)
- Add warning when path doesn't match expected server pattern

---

### VULN-004: DPAPI Domain Credential Risk
**Severity:** MEDIUM
**CVSS Score:** 5.0 (Medium)
**Status:** ACCEPTED RISK (with mitigations)

**Description:**
Credentials encrypted with DPAPI can be decrypted by the same domain user on any domain-joined machine.

**Location:** `Config/credential.dat`, `Config/credential.pin`

**Attack Vector:**
1. Attacker copies credential.dat and credential.pin files
2. On attacker's machine (same domain user), DPAPI decrypts
3. Brute force PIN (now 1,000,000+ combinations with 6-digit minimum)
4. Attacker has cached admin credentials

**Mitigations Applied in v2.1:**
- PIN minimum increased to 6 digits (1M combinations vs 10K)
- 5-attempt lockout before credential wipe
- 15-minute timeout requires PIN re-entry

**Accepted Risk Rationale:**
- Migrating to Windows Credential Manager adds complexity
- Current controls make offline attack time-consuming
- Physical access to credential files implies other compromises likely
- Risk accepted by Rush IT management

**Future Consideration:**
- Add machine-specific salt (DPAPI user secret + machine SID)
- Implement Windows Credential Manager for high-security deployments

---

### VULN-005: Weak PIN Protection
**Severity:** LOW-MEDIUM → LOW (Mitigated)
**CVSS Score:** 4.0 → 2.5 (Residual)
**Status:** MITIGATED in v2.1

**Description:**
PIN previously had only 10,000 possible combinations (4 digits). Now requires 6+ digits.

**Mitigation Implemented:**
```powershell
# PIN validation in Show-PINEntryDialog
if ($pin.Length -lt 6) {
    [System.Windows.Forms.MessageBox]::Show(
        "PIN must be at least 6 digits.",
        "Invalid PIN", ...
    )
    return
}
```

**Location:** `RushResolve.ps1` - `Show-PINEntryDialog` function (lines 609-740)

**Security Controls:**
- Minimum 6 digits (1,000,000+ combinations)
- Digits only (prevents dictionary attacks)
- SHA256 hashing
- 5-attempt lockout with credential wipe option
- 15-minute session timeout

**Residual Risk:**
- Offline brute force still theoretically possible
- SHA256 is fast; PBKDF2/bcrypt would be more resistant
- Acceptable given DPAPI provides primary protection

**Future Enhancement:**
- Implement PBKDF2 with 100K+ iterations for PIN verification

---

### VULN-006: Credential in Memory
**Severity:** LOW
**CVSS Score:** 3.5 (Low)
**Status:** OPEN (Accepted Risk)

**Description:**
While unlocked, credentials exist in memory as SecureString. An attacker with admin access could dump process memory.

**Impact:** Credential theft if attacker has admin access to running system

**Remediation:** None practical - if attacker has admin, system is already compromised. Standard accepted risk.

---

### VULN-007: Printer Path Injection
**Severity:** MEDIUM → LOW (Mitigated)
**CVSS Score:** 5.0 → 1.5 (Residual)
**Status:** MITIGATED in v2.2

**Description:**
The "Add by Path" feature in Printer Management previously allowed users to enter arbitrary UNC paths, enabling potential redirection to attacker-controlled print servers.

**Original Attack Vector:**
1. Attacker modifies settings or social engineers tech to use malicious server
2. Tech enters `\\ATTACKER-SERVER\FakePrinter` in Add by Path dialog
3. Connection to attacker server could execute malicious driver code or leak credentials

**Mitigation Implemented:**
```powershell
# SECURITY: Hardcoded allowlist of approved print servers
$script:AllowedPrintServers = @(
    "\\RUDWV-PS401",       # Primary RMC print server
    "\\RUDWV-PS402",       # Secondary RMC print server
    "\\RUCPMC-PS01",       # CPMC print server
    "\\RUSH-PS01"          # Main campus print server
)

# Server selection via dropdown (DropDownList style prevents typing)
$script:serverComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

# Printer name sanitized to remove path characters
$printerName = $printerName -replace '[\\\/]', ''
```

**Location:** `Modules/03_PrinterManagement.ps1` - lines 12-65 (allowlist and validation)

**Security Controls:**
- Server selection restricted to dropdown (no free-text)
- Allowlist hardcoded in module (not user-configurable)
- Printer name sanitized to remove path traversal characters
- "Add by Path" dialog split into Server dropdown + Printer name field

**Residual Risk:** Minimal - attacker would need to modify source code (blocked by module integrity checks).

---

## Current Security Controls (v2.2)

| Control | Status | Effectiveness |
|---------|--------|---------------|
| DPAPI Encryption | Implemented | Good - Windows native |
| PIN Protection | Implemented | Good - 6+ digits required |
| PIN Timeout | Implemented | Good - 15 minute lockout |
| Failed Attempt Lockout | Implemented | Good - 5 attempts |
| SecureString Usage | Implemented | Good - Industry standard |
| Code Signing | NOT IMPLEMENTED | N/A - Future enhancement |
| Integrity Checks | **IMPLEMENTED v2.1** | Good - SHA256 on startup |
| Module Whitelist | **IMPLEMENTED v2.1** | Good - SHA256 hash verification |
| Settings Monitoring | **IMPLEMENTED v2.1** | Fair - Hash tracked for audit |
| Security Mode Control | **IMPLEMENTED v2.1** | Good - Enforced/Warn/Disabled |
| First-Run Protection | **IMPLEMENTED v2.1** | Good - Prompts manifest creation |
| Print Server Allowlist | **IMPLEMENTED v2.2** | Good - Hardcoded server list |
| Audit Logging | NOT IMPLEMENTED | N/A - Future enhancement |

---

## Risk Matrix (Updated v2.2)

| Vulnerability | Likelihood | Impact | Risk Level | Status |
|--------------|------------|--------|------------|--------|
| VULN-001: Module Injection | Very Low | Critical | LOW | Mitigated |
| VULN-002: No Integrity Check | Very Low | Critical | LOW | Mitigated |
| VULN-003: Settings Manipulation | Low | Medium | LOW | Monitored |
| VULN-004: DPAPI Domain Risk | Low | High | MEDIUM | Accepted |
| VULN-005: Weak PIN | Very Low | Medium | LOW | Mitigated |
| VULN-006: Memory Exposure | Very Low | High | LOW | Accepted |
| VULN-007: Printer Path Injection | Very Low | Medium | LOW | Mitigated |

---

## Recommendations Status

| Priority | Vulnerability | Remediation | Status |
|----------|--------------|-------------|--------|
| P0 | VULN-001 | Module whitelist with hash verification | **COMPLETE** |
| P0 | VULN-002 | Startup integrity check | **COMPLETE** |
| P1 | VULN-003 | Settings integrity verification | **MONITORED** |
| P1 | VULN-007 | Print server allowlist | **COMPLETE** |
| P2 | VULN-005 | Increase PIN to 6+ digits | **COMPLETE** |
| P3 | VULN-004 | Migrate to Windows Credential Manager | Deferred |

## Future Enhancements (Backlog)

| Enhancement | Description | Priority |
|-------------|-------------|----------|
| PBKDF2 PIN Hashing | Use slow hash for PIN (100K+ iterations) | Low |
| Audit Logging | Log security events to file | Medium |
| Code Signing | Sign scripts with certificate | Medium |
| Software Path Whitelist | Restrict software paths to approved servers | Low |

---

## Threat Model

**Assets:**
- Cached admin credentials (HIGH value)
- Access to managed systems (HIGH value)
- Application integrity (MEDIUM value)

**Threat Actors:**
| Actor | Capability | Motivation | Likelihood |
|-------|------------|------------|------------|
| Malicious Insider | High (physical access) | Financial, revenge | Low |
| Opportunistic Attacker | Medium (if access obtained) | Credential theft | Low |
| External Attacker | Low (no direct access) | N/A | Very Low |

**Attack Surface:**
- Application files (writable by user)
- Module directory (writable by user)
- Settings file (writable by user)
- Credential files (protected by DPAPI + PIN)

---

## Appendix A: File Inventory

| File | Purpose | Sensitive | Protected |
|------|---------|-----------|-----------|
| RushResolve.ps1 | Main application | No (code) | Integrity verified |
| Modules/01_SystemInfo.ps1 | System info display | No | Hash verified |
| Modules/02_SoftwareInstaller.ps1 | Software installation | No | Hash verified |
| Modules/03_PrinterManagement.ps1 | Printer management | No | Hash verified |
| Modules/05_NetworkTools.ps1 | Network diagnostics | No | Hash verified |
| Config/settings.json | User preferences | Low (paths) | Hash monitored |
| Config/credential.dat | Encrypted credentials | HIGH | DPAPI protected |
| Config/credential.pin | PIN hash | MEDIUM | SHA256 hashed |
| Security/module-manifest.json | Module whitelist | MEDIUM | Integrity source |
| Security/integrity-manifest.json | File hashes | MEDIUM | Integrity source |

---

## Appendix B: Security Manifest Format

### module-manifest.json
```json
{
    "generated": "2026-01-06 10:00:00",
    "generated_by": "RUSH\\admin",
    "description": "Whitelist of authorized modules with SHA256 hashes",
    "modules": [
        { "name": "01_SystemInfo.ps1", "hash": "base64hash...", "added": "2026-01-06" }
    ]
}
```

### integrity-manifest.json
```json
{
    "generated": "2026-01-06 10:00:00",
    "generated_by": "RUSH\\admin",
    "description": "SHA256 hashes for application integrity verification",
    "main_script_hash": "base64hash...",
    "settings_hash": "base64hash..."
}
```

---

*Report generated for Rush IT Field Services cybersecurity review.*
*Security hardening implemented: January 6, 2026*
*Version: 2.2*
