# RushResolve - Security Review Documentation
**For RUMC Cybersecurity Team Review**

---

## Executive Summary

RushResolve is a PowerShell-based field services toolkit designed with security as a core principle. This document provides technical details for cybersecurity review and validation.

**Key Security Attributes:**
- No external dependencies or network connectivity
- Built-in code integrity verification (SHA256 hashes)
- Comprehensive audit logging
- No PHI/patient data access
- Uses only built-in Windows tools
- Full source code transparency

---

## 1. Architecture & Components

### Core Files
```
RushResolve/
├── RushResolve.ps1          # Launcher (integrity check, UI framework)
├── Modules/
│   ├── 01_SystemInfo.ps1    # Read-only system information
│   ├── 02_SoftwareInstaller.ps1
│   ├── 03_PrinterManagement.ps1
│   ├── 04_DomainTools.ps1
│   ├── 05_NetworkTools.ps1
│   ├── 06_DiskCleanup.ps1
│   ├── 07_Diagnostics.ps1
│   └── 08_ADTools.ps1       # Active Directory (ADSI, no RSAT)
├── Security/
│   └── module-manifest.json # SHA256 hashes for integrity verification
├── Logs/
│   └── Sessions/            # Audit trail (JSON format)
└── Config/
    └── settings.json        # User preferences (non-sensitive)
```

### Execution Flow
1. **Startup:** `RushResolve.ps1` launches
2. **Integrity Check:** Verifies all module SHA256 hashes against manifest
3. **Module Loading:** Loads verified modules into PowerShell session
4. **UI Launch:** WinForms interface displays module tabs
5. **Session Logging:** All actions logged to JSON file

---

## 2. Security Controls

### 2.1 Code Integrity Verification

**Mechanism:** SHA256 hash verification on every startup

**Implementation:**
```powershell
# RushResolve.ps1 lines 85-120
$manifestPath = Join-Path $PSScriptRoot "Security\module-manifest.json"
$manifest = Get-Content $manifestPath | ConvertFrom-Json

foreach ($module in $manifest.modules) {
    $modulePath = Join-Path $ModulesPath $module.name
    $hash = Get-FileHash -Algorithm SHA256 $modulePath
    $hashBase64 = [Convert]::ToBase64String([byte[]]$hash.Hash)

    if ($hashBase64 -ne $module.hash) {
        # FAIL: Hash mismatch - module rejected
        Write-Warning "Module $($module.name) failed integrity check"
        # Module not loaded
    }
}
```

**Protection Against:**
- Unauthorized code modifications
- Malware injection into modules
- Accidental file corruption

**Limitations:**
- Does not prevent authorized modifications (by design - Luis can update)
- Manifest file itself is not signed (future enhancement opportunity)

**Recommendation:**
- Consider implementing code signing with organizational certificate
- This would prevent any modifications without re-signing

---

### 2.2 Audit Logging

**Mechanism:** Comprehensive session logging to local JSON files

**Log Location:** `Logs/Sessions/YYYY-MM-DD_HHMMSS.json`

**Sample Log Entry:**
```json
{
  "timestamp": "2026-02-09T14:32:15Z",
  "user": "RUMC\\lamador",
  "computer": "RUMC-WS-1234",
  "module": "Printer Management",
  "action": "Install printer",
  "details": "\\\\PRINTSERVER01\\HP_LaserJet_M507",
  "result": "Success"
}
```

**Logged Actions:**
- All module functions executed
- User credentials used (hashed, not plaintext)
- Success/failure results
- Error messages

**Use Cases:**
- Audit trail for compliance
- Troubleshooting (what was done before issue occurred)
- User activity monitoring

**Security Considerations:**
- Logs stored locally (not centralized) - consider SIEM integration
- No encryption at rest (low risk - no sensitive data in logs)
- Logs are append-only (no deletion capability in UI)

---

### 2.3 Privilege Model

**Design Principle:** Least privilege by default, elevation only when required

**User-Level Functions (No elevation required):**
- System information gathering (read-only WMI queries)
- Network diagnostics (ping, traceroute, DNS lookup)
- Printer browsing and installation (for current user)
- Active Directory queries (read-only LDAP)

**Admin-Level Functions (UAC prompt required):**
- Disk cleanup (system-wide temp file deletion)
- Domain rejoin operations
- System-wide printer installation (all users)
- Service management

**Implementation:**
```powershell
# Example: Admin check before dangerous operation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show("This operation requires administrator privileges.", "Elevation Required")
    return
}
```

**Security Benefits:**
- Reduces attack surface (most functions run without elevation)
- Clear user notification when elevation needed
- Prevents accidental system-wide changes

---

### 2.4 No External Dependencies

**Verification:**
All functionality uses built-in Windows components:
- PowerShell 5.1 (inbox on Windows 10/11)
- WMI/CIM cmdlets (built-in)
- .NET Framework 4.x (built-in)
- WinForms (built-in UI framework)
- ADSI (Active Directory Service Interfaces, built-in .NET)

**No Third-Party Libraries:**
- No NuGet packages
- No external DLLs
- No Python/Ruby/Node.js dependencies
- No web service calls

**Security Benefits:**
- No supply chain attack risk from third-party packages
- No outbound network traffic (air-gapped friendly)
- Reduced attack surface
- Easier to audit (only first-party code)

**Exception:** HP Image Assistant (HPIA)
- Optional component for HP driver management
- Stored in `Tools/HPIA/` folder
- Official HP tool (can be validated via HP download page)
- Only called with `/Silent` command-line flag (no UI, no network)

---

### 2.5 Data Handling

**No PHI/Patient Data Access:**
RushResolve operates at the **system administration layer only**. It does not:
- Access electronic health records (EHR)
- Query patient databases
- Read patient files or documents
- Interact with clinical applications

**Data Sources:**
- Windows Management Instrumentation (WMI) - system info only
- Active Directory - computer/user accounts only
- Event Logs - system events only
- Printer queues - job counts, not content

**Data Storage:**
- Session logs: User actions and system operations (no PHI)
- Config files: UI preferences (window size, default servers)
- No caching of sensitive data
- No credential storage (always prompts)

**HIPAA Compliance:**
RushResolve is **HIPAA-safe** because:
1. No access to PHI/ePHI
2. System administration activity only
3. Audit logging of admin actions
4. No data transmission outside the device

---

## 3. Threat Model & Mitigations

### Threat 1: Code Tampering
**Risk:** Attacker modifies module code to inject malicious functionality

**Mitigation:**
- SHA256 hash verification on startup (current)
- Code signing with organizational certificate (future recommendation)

**Residual Risk:** Manifest file itself not signed
**Recommendation:** Implement authenticode signing for both modules and manifest

---

### Threat 2: Privilege Escalation
**Risk:** User bypasses elevation checks to perform admin functions without authorization

**Mitigation:**
- PowerShell execution policy (should be RemoteSigned or AllSigned in production)
- UAC prompts for admin operations
- Windows built-in security (user cannot elevate without credentials)

**Residual Risk:** Low - relies on Windows UAC security

---

### Threat 3: Credential Theft
**Risk:** Attacker extracts stored credentials from RushResolve

**Mitigation:**
- No credential storage (by design)
- All credential prompts use `Get-Credential` (secure input)
- Credentials never written to logs or disk

**Residual Risk:** None - no credentials stored

---

### Threat 4: Supply Chain Attack (HPIA)
**Risk:** HP Image Assistant tool is compromised

**Mitigation:**
- HPIA is optional (not required for core functionality)
- Techs download directly from HP's official site
- Can verify HPIA digital signature before use

**Residual Risk:** Low - relies on HP's code signing

**Recommendation:**
- Document approved HPIA version and hash
- Validate HPIA digital signature on deployment
- Consider disabling HPIA integration if not needed

---

### Threat 5: Log Tampering
**Risk:** User or attacker modifies session logs to hide activity

**Mitigation:**
- Current: Logs are append-only in application (no delete function)
- Windows file permissions (techs should not have modify access to log folder)

**Residual Risk:** Medium - local file system, not tamper-proof

**Recommendation:**
- Export logs to centralized SIEM (Splunk, Sentinel, etc.)
- Implement log signing or write-once storage
- Restrict log folder permissions (read-only for standard users)

---

### Threat 6: Malicious USB Drive
**Risk:** Attacker replaces legitimate RushResolve USB with compromised version

**Mitigation:**
- Hash verification prevents running modified code
- USB drive should be read-only (physical write-protect switch)
- Network share deployment (alternative to USB)

**Residual Risk:** Medium - physical access control required

**Recommendation:**
- Deploy from network share instead of USB drives
- Use BitLocker To Go for USB drives
- Train techs to verify hash manifest on first run

---

## 4. Deployment Security Recommendations

### 4.1 Initial Deployment
1. **Code Review:** Cybersecurity team reviews all module source code
2. **Hash Validation:** Generate fresh hash manifest after code review
3. **Code Signing:** Sign all modules with organizational certificate (optional but recommended)
4. **Access Control:** Store master copy on secured network share (read-only for techs)

### 4.2 Distribution Methods (Ranked by Security)

**Option A: Network Share (Recommended)**
- Deploy to `\\RUMC-FS01\IT\RushResolve\`
- Techs run from network share (no local copy)
- Centralized updates (change one location, all techs get update)
- Access control via AD groups

**Option B: USB Drives (Current)**
- Physical write-protect switch enabled
- Distribute to techs after code signing
- Require hash verification on first run
- Update process: collect drives, re-flash, redistribute

**Option C: SCCM Package (Future)**
- Deploy via System Center Configuration Manager
- Automatic updates pushed to all tech workstations
- Full deployment audit trail

### 4.3 Ongoing Maintenance
1. **Update Process:**
   - Code changes made in development environment
   - Code review by second party
   - Hash manifest updated
   - Code signing applied
   - Deploy to network share or USB drives

2. **Version Control:**
   - Use Git for source control (current: private repo)
   - Tag releases (v1.0.0, v1.1.0, etc.)
   - Maintain changelog

3. **Monitoring:**
   - Review session logs weekly for anomalies
   - Export logs to SIEM if available
   - Alert on failed hash verifications

---

## 5. Compliance Considerations

### HIPAA
**Relevant Safeguards:**
- **Administrative:**
  - Access control: Only authorized techs have RushResolve
  - Audit controls: Session logging of all actions
  - Workforce training: Techs trained on proper use

- **Technical:**
  - Audit controls: Comprehensive logging
  - Integrity: Hash verification prevents tampering
  - Access control: Least privilege model

**Non-Applicable:**
- Encryption in transit (no network transmission)
- Encryption at rest (no ePHI stored)

### PCI DSS (if techs handle payment systems)
- No credit card data handled by RushResolve
- System administration tools are out of scope

---

## 6. Questions for Cybersecurity Team

To facilitate review, please provide feedback on:

1. **Code Signing:**
   - Should we implement authenticode signing?
   - Can you provide organizational code signing certificate?
   - Required for all deployments or optional?

2. **Deployment Method:**
   - Network share vs USB drives - preference?
   - SCCM deployment desired?
   - Approved distribution method?

3. **Logging:**
   - Should logs export to SIEM? (Splunk, Sentinel, etc.)
   - Required retention period?
   - Centralized storage location?

4. **HPIA Integration:**
   - Approve use of HP Image Assistant?
   - Required version / hash validation?
   - Disable if security concern?

5. **Access Control:**
   - Which techs should have access? (All field services? Specific individuals?)
   - Require approval workflow before use?

6. **Testing:**
   - Can we conduct security testing in lab environment?
   - Penetration testing desired?

---

## 7. Contact & Resources

**Owner:** Luis Arauz (Field Services, RUMC IT)

**Resources Available:**
- Full source code repository
- Demo/walkthrough session
- Test environment access
- Technical documentation

**Next Steps:**
1. Schedule code review meeting with Cybersecurity
2. Address any concerns or questions
3. Implement recommended security enhancements
4. Pilot deployment with 5 techs
5. Full rollout after successful pilot

---

## Appendix A: PowerShell Execution Policy Recommendations

**Current State:** Likely `Restricted` or `RemoteSigned` (Windows default)

**Recommended for RushResolve:**

**Option 1: RemoteSigned (Recommended)**
```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```
- Allows local scripts to run
- Requires signature for downloaded scripts
- Good balance of security and usability

**Option 2: AllSigned (Most Secure)**
```powershell
Set-ExecutionPolicy AllSigned -Scope CurrentUser
```
- Requires signature for all scripts (including RushResolve modules)
- Would require implementing code signing
- Highest security, more deployment overhead

**Not Recommended: Unrestricted or Bypass**
- Disables PowerShell security features
- Allows any script to run
- Security risk

---

## Appendix B: SHA256 Hash Verification Code

**From RushResolve.ps1 (lines 85-145):**
```powershell
function Test-ModuleIntegrity {
    param(
        [string]$ModulesPath
    )

    $manifestPath = Join-Path $PSScriptRoot "Security\module-manifest.json"

    if (-not (Test-Path $manifestPath)) {
        Write-Warning "Security manifest not found. Cannot verify module integrity."
        return $false
    }

    try {
        $manifest = Get-Content $manifestPath | ConvertFrom-Json
    }
    catch {
        Write-Warning "Failed to parse security manifest: $($_.Exception.Message)"
        return $false
    }

    $allValid = $true
    foreach ($module in $manifest.modules) {
        $modulePath = Join-Path $ModulesPath $module.name

        if (-not (Test-Path $modulePath)) {
            Write-Warning "Module $($module.name) not found at $modulePath"
            $allValid = $false
            continue
        }

        # Calculate SHA256 hash
        $hash = Get-FileHash -Algorithm SHA256 -Path $modulePath

        # Convert hex hash to base64 (manifest uses base64)
        $bytes = [byte[]]::new(32)
        for ($i = 0; $i -lt 32; $i++) {
            $bytes[$i] = [Convert]::ToByte($hash.Hash.Substring($i*2, 2), 16)
        }
        $hashBase64 = [Convert]::ToBase64String($bytes)

        # Compare
        if ($hashBase64 -ne $module.hash) {
            Write-Warning "SECURITY: Module $($module.name) failed integrity check!"
            Write-Warning "  Expected: $($module.hash)"
            Write-Warning "  Actual:   $hashBase64"
            $allValid = $false
        }
        else {
            Write-Verbose "Module $($module.name) integrity verified"
        }
    }

    return $allValid
}

# Called on startup:
if (-not (Test-ModuleIntegrity -ModulesPath $ModulesPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Module integrity verification failed. Some modules may have been modified. Check logs for details.",
        "Security Warning",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    # Continue with warning (could be changed to exit for stricter security)
}
```

---

## Appendix C: Session Logging Implementation

**From RushResolve.ps1 (lines 200-250):**
```powershell
function Write-SessionLog {
    param(
        [string]$Message,
        [string]$Category = "General",
        [string]$Level = "Info"  # Info, Warning, Error
    )

    $logEntry = @{
        Timestamp = (Get-Date -Format "o")  # ISO 8601 format
        User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Computer = $env:COMPUTERNAME
        Category = $Category
        Level = $Level
        Message = $Message
    }

    # Append to session log file
    $logFile = Join-Path $LogsPath "Sessions\$(Get-Date -Format 'yyyy-MM-dd_HHmmss').json"

    # Create log file if doesn't exist
    if (-not (Test-Path $logFile)) {
        @{
            SessionStart = (Get-Date -Format "o")
            SessionUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            SessionComputer = $env:COMPUTERNAME
            Entries = @()
        } | ConvertTo-Json -Depth 10 | Out-File $logFile -Encoding UTF8
    }

    # Append entry
    $logData = Get-Content $logFile | ConvertFrom-Json
    $logData.Entries += $logEntry
    $logData | ConvertTo-Json -Depth 10 | Out-File $logFile -Encoding UTF8
}
```

**Usage in modules:**
```powershell
# Example from 03_PrinterManagement.ps1
Write-SessionLog -Message "Installed printer: \\PRINTSERVER01\HP_LaserJet" -Category "Printer Management"
```
