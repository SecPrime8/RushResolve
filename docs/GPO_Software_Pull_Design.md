# GPO Software Pull - Design Document

**Concept:** Instead of WinGet, pull software from RUSH's existing Group Policy deployment infrastructure.

---

## The Problem

**Current State:**
- RUSH IT deploys software via Group Policy
- Software packages (.msi) are on network shares
- GPO pushes software to computers on schedule (slow - hours or days)
- Field techs need software **now**, not later

**Pain Point:**
> "There are apps in Active Directory to push updates but it's a pain to use because we have to open up AD, etc."

---

## The Solution

**RushResolve can:**
1. Query AD/GPO to see what software is assigned to the current computer
2. Show list of available packages (already approved by RUSH IT)
3. Install on-demand by either:
   - **Option A:** Force immediate GPO refresh (`gpupdate /force`)
   - **Option B:** Install directly from network share (bypass GPO entirely)

---

## Technical Implementation

### **Step 1: Query Assigned Software Packages**

PowerShell can read GPO software assignments:

```powershell
# Get GPO applied to this computer
$computer = $env:COMPUTERNAME
$computerDN = (Get-ADComputer $computer).DistinguishedName
$gpos = Get-GPResultantSetOfPolicy -ReportType Xml -Computer $computer

# Parse XML to find software installation policies
$xml = [xml]$gpos
$softwarePackages = $xml.SelectNodes("//q1:Software/q1:Package")

foreach ($package in $softwarePackages) {
    Write-Host "Package: $($package.Name)"
    Write-Host "  Path: $($package.Path)"  # Network share location!
    Write-Host "  State: $($package.State)"  # Installed or Available
}
```

**Output Example:**
```
Package: Google Chrome Enterprise
  Path: \\RUSH-FS01\SoftwareDist\Chrome\GoogleChromeStandaloneEnterprise64.msi
  State: Available

Package: Adobe Acrobat Reader DC
  Path: \\RUSH-FS01\SoftwareDist\Adobe\AcroRdrDC.msi
  State: Installed

Package: 7-Zip 23.01
  Path: \\RUSH-FS01\SoftwareDist\7-Zip\7z2301-x64.msi
  State: Available
```

---

### **Step 2: Force Install via GPO**

Two approaches:

#### **Method A: Force GPO Update**

```powershell
# Force immediate Group Policy refresh
gpupdate /force /wait:0

# Or more targeted (software installation only)
Invoke-GPUpdate -Computer $env:COMPUTERNAME -Target Computer
```

**Pros:**
- Uses existing GPO infrastructure
- No custom installation logic needed
- RUSH IT maintains control

**Cons:**
- Still requires GPO processing time (faster but not instant)
- Can trigger other GPO changes (registry, scripts, etc.)

---

#### **Method B: Direct Install from Network Share** ⭐ (Recommended)

```powershell
# Install directly from the network share
$msiPath = "\\RUSH-FS01\SoftwareDist\Chrome\GoogleChromeStandaloneEnterprise64.msi"

# Silent install
Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait -NoNewWindow

# Or with logging
Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart /l*v `"C:\Temp\install.log`"" -Wait -NoNewWindow
```

**Pros:**
- ⚡ **Instant** - no waiting for GPO refresh
- Uses RUSH's approved packages (same .msi files)
- Full control over install process
- Can show progress bar in RushResolve

**Cons:**
- Bypasses GPO tracking (install won't show in GPO reports)
- Need network share access (field techs should have this)

---

### **Step 3: UI in RushResolve**

```
┌─────────────────────────────────────────────────────────────┐
│ Software Packages (RUSH IT Approved)                       │
├─────────────────────────────────────────────────────────────┤
│ [Refresh List]                                              │
│                                                             │
│ Available Packages:                                         │
│ ☐ Google Chrome Enterprise 121.0.6167.140                  │
│ ☐ Adobe Acrobat Reader DC 24.001.20604                     │
│ ☐ 7-Zip 23.01                                              │
│                                                             │
│ Installed Packages:                                         │
│ ✓ Microsoft Office 2019 ProPlus                            │
│ ✓ Zoom Client 5.16.10                                      │
│                                                             │
│ [Install Selected]  [Force GPO Update]                     │
└─────────────────────────────────────────────────────────────┘
```

---

## Advantages Over WinGet

| Feature | WinGet | GPO Pull |
|---------|--------|----------|
| **Approval Required** | Yes (blocked by RUSH) | No (uses existing system) |
| **Software Source** | Microsoft repository | RUSH's approved packages |
| **IT Control** | External | RUSH IT maintains |
| **Network Shares** | Not needed | Uses existing shares |
| **Audit Trail** | WinGet logs | Windows Installer logs + RushResolve logs |
| **Offline Capable** | No | Yes (if on network) |
| **RUSH-Specific Apps** | No | Yes (custom MSIs) |

**Key Advantage:** Uses infrastructure RUSH **already has and trusts**!

---

## Security Considerations

### **Why This Is Safe:**

1. **Uses RUSH's Packages**
   - Same .msi files RUSH IT already deployed
   - Already vetted by Cybersecurity
   - Already approved software

2. **No External Dependencies**
   - Installs from RUSH's network shares
   - No internet downloads
   - No third-party repositories

3. **Audit Trail**
   - Windows Installer logs every installation
   - RushResolve logs actions to session log
   - Same logging as GPO deployment

4. **Permissions-Based**
   - Techs can only install packages they have access to
   - Network share permissions enforced
   - No elevation beyond what GPO would require

---

## Implementation Plan

### **Phase 1: Query GPO Packages**

Add to Module 02:
- Function to query GPO software assignments
- Parse XML from `Get-GPResultantSetOfPolicy`
- Display list of available/installed packages

### **Phase 2: Force GPO Update**

Simple button:
```powershell
gpupdate /force /target:computer /wait:0
```
Shows progress, waits for completion.

### **Phase 3: Direct Install** ⭐

Advanced feature:
- Parse network share paths from GPO
- Install selected packages via msiexec
- Show progress bar
- Log results

---

## Proof of Concept

### **Query Script:**

```powershell
# Get GPO Resultant Set of Policy
$rsop = Get-GPResultantSetOfPolicy -ReportType Xml -Computer $env:COMPUTERNAME

# Parse XML
[xml]$xml = $rsop

# Define XML namespace
$ns = @{q1 = "http://www.microsoft.com/GroupPolicy/Rsop"}

# Find software packages
$packages = $xml.SelectNodes("//q1:Software[@type='MsiApplication']", $ns)

foreach ($pkg in $packages) {
    [PSCustomObject]@{
        Name = $pkg.Name
        Version = $pkg.VersionString
        PackageCode = $pkg.PackageCode
        ProductCode = $pkg.ProductCode
        State = $pkg.State  # "Installed" or "Available"
        AssignmentType = $pkg.AssignmentType  # "Assigned" or "Published"
        ScriptPath = $pkg.Path  # Network share!
    }
}
```

### **Install Script:**

```powershell
function Install-GPOPackage {
    param(
        [string]$MsiPath,
        [string]$PackageName
    )

    Write-Host "Installing $PackageName from $MsiPath..."

    $logPath = "$env:TEMP\RushResolve_Install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    $arguments = @(
        "/i"
        "`"$MsiPath`""
        "/quiet"
        "/norestart"
        "/l*v"
        "`"$logPath`""
    )

    $process = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -eq 0) {
        Write-Host "Installation succeeded!"
        return $true
    }
    else {
        Write-Host "Installation failed with exit code: $($process.ExitCode)"
        Write-Host "Log: $logPath"
        return $false
    }
}

# Usage:
Install-GPOPackage -MsiPath "\\RUSH-FS01\SoftwareDist\Chrome\GoogleChromeStandaloneEnterprise64.msi" -PackageName "Google Chrome"
```

---

## Testing on RUSH Machine

Before building into RushResolve, test these commands on a RUSH computer:

### **Test 1: Can we query GPO software?**
```powershell
Get-GPResultantSetOfPolicy -ReportType Xml -Computer $env:COMPUTERNAME
```

### **Test 2: Can we access the network share?**
```powershell
# Try to access typical software distribution share
Test-Path "\\RUSH-FS01\SoftwareDist"
# Or wherever RUSH stores .msi files
```

### **Test 3: Can we install from network share?**
```powershell
# Try installing something small (7-Zip is usually safe to test)
msiexec.exe /i "\\[NETWORK_SHARE]\7-Zip\7z-x64.msi" /quiet /norestart
```

---

## Questions for RUSH IT

Before implementation, clarify:

1. **Where are .msi files stored?**
   - Network share path?
   - Do field techs have read access?

2. **GPO Software Deployment Structure:**
   - How are packages organized?
   - Which OUs have software assigned?
   - Are packages assigned or published?

3. **Permissions:**
   - Can techs run `Get-GPResultantSetOfPolicy`?
   - Can techs access software distribution share?
   - Can techs run `msiexec` for installs?

4. **Approval:**
   - Is this approach allowed?
   - Does it bypass any audit requirements?
   - Should we log to central location?

---

## Next Steps

1. **Test on RUSH machine:**
   - Run proof-of-concept scripts
   - Confirm GPO query works
   - Verify network share access

2. **Get IT feedback:**
   - Show concept to RUSH IT
   - Confirm this is acceptable
   - Identify any policy blockers

3. **Build into Module 02:**
   - Add "GPO Software Packages" tab
   - Query and display available packages
   - Implement install functionality

4. **Pilot test:**
   - Deploy to 1-2 techs
   - Verify installations work
   - Gather feedback

---

## Summary

**This approach is BETTER than WinGet for RUSH because:**

✅ No approval needed (uses existing infrastructure)
✅ RUSH IT maintains control (their packages, their shares)
✅ No external dependencies (completely internal)
✅ Already approved software (same MSIs as GPO)
✅ Faster than GPO wait times (on-demand install)
✅ Works offline (if on RUSH network)
✅ Can include RUSH-specific custom apps

**Bottom Line:** This is "WinGet but for RUSH's internal software repository" - and it doesn't need Cybersecurity approval because it uses infrastructure they already trust!
