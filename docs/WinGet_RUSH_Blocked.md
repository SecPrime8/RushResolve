# WinGet Blocked at RUSH - Analysis & Options

**Status:** WinGet is installed on RUSH machines but execution is blocked by IT policy.

---

## What's Blocked?

There are several ways RUSH could be blocking WinGet:

### 1. **AppLocker / WDAC (Application Control)**
- Blocks execution of specific executables
- Common in healthcare environments (HIPAA compliance)
- Test: `winget --version` returns "blocked by policy" or access denied

### 2. **Group Policy - Script Execution**
- PowerShell execution policy set to Restricted
- Blocks .ps1 scripts but might allow .exe
- Test: `Get-ExecutionPolicy` returns "Restricted"

### 3. **Network/Firewall Block**
- WinGet.exe runs but can't reach Microsoft's CDN
- Blocks downloads from winget.azureedge.net or cdn.winget.microsoft.com
- Test: `winget search chrome` returns network error

### 4. **App Execution Alias Disabled**
- WindowsApps folder execution disabled
- WinGet installed but shell can't find it
- Test: `winget` not recognized, but exe exists at path

---

## Diagnosis Commands

Run these on a RUSH machine to identify the block:

```powershell
# 1. Check if WinGet is installed
Get-AppxPackage -Name Microsoft.DesktopAppInstaller

# 2. Try to run WinGet directly
& "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" --version

# 3. Check execution policy
Get-ExecutionPolicy -List

# 4. Check AppLocker policy
Get-AppLockerPolicy -Effective -Xml

# 5. Test network access
Test-NetConnection winget.azureedge.net -Port 443
```

---

## Options for RUSH Deployment

### **Option A: Request WinGet Unblock (Recommended)**

**Pitch to RUSH IT/Cybersecurity:**

> "WinGet is Microsoft's official package manager, analogous to SCCM but for manual installations. It's installed by default on Windows 11 and is maintained by Microsoft.
>
> Currently field techs manually download software by Googling 'download chrome' which has security risks (fake sites, bundled malware). WinGet ensures they get software from official sources with cryptographic verification.
>
> Request: Whitelist `winget.exe` in AppLocker policy for field service technician accounts."

**What to ask for:**
- Whitelist: `%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe`
- Network access to: `winget.azureedge.net` and `cdn.winget.microsoft.com`
- Justification: Reduces security risk of manual downloads

---

### **Option B: Remove WinGet Feature from RushResolve**

If Cybersecurity won't approve WinGet:

**Action:** Remove "Check for Updates" feature from Module 02
- Core RushResolve functionality unaffected (printers, domain, diagnostics work fine)
- Document limitation in deployment guide
- Focus on proven value adds (printer management, domain tools)

**Benefits:**
- Avoids prolonged approval process
- Gets RushResolve deployed faster
- Can add WinGet later if policy changes

---

### **Option C: Manual Update Workflow (No WinGet)**

Keep the UI but change the workflow:

Instead of automated updates, provide **download links**:

```
Software Updates:
┌────────────────────────────────────────────────┐
│ Application     | Status   | Action           │
├────────────────────────────────────────────────┤
│ Google Chrome   | Outdated | [Download Link]  │
│ Adobe Acrobat   | Outdated | [Download Link]  │
│ 7-Zip           | Current  | -                │
└────────────────────────────────────────────────┘
```

**How it works:**
- RushResolve checks versions (registry + file properties)
- Shows outdated apps
- Provides official download links (opens in browser)
- Tech downloads and installs manually

**Implementation:**
- Remove WinGet dependency
- Add version checking scriptblocks (see `Custom_Update_Checker_Design.md`)
- Add download URL database for common apps

---

### **Option D: Offline Package Cache**

Bundle installers on USB drive:

```
RushResolve/
└── Packages/
    ├── Chrome/
    │   └── ChromeSetup.exe
    ├── Acrobat/
    │   └── AcroRdrDC.exe
    └── 7-Zip/
        └── 7z-x64.exe
```

**How it works:**
- Pre-download installers for common apps
- Store on USB drive (or network share)
- RushResolve checks versions, offers to install from cache
- No internet/WinGet required

**Pros:**
- Works completely offline
- No external dependencies
- Fast installs (local USB)

**Cons:**
- Cache gets outdated (manual maintenance)
- Larger USB drive needed (~2-3 GB)
- Doesn't cover all apps (only what we bundle)

---

## Recommendation

### **Phase 1: Try Option A (Request Unblock)**

**Timeline:** 1-2 weeks
- Draft request to RUSH Cybersecurity
- Explain security benefits (fewer fake downloads)
- Emphasize Microsoft official tool

### **If Approved:**
- WinGet feature works as designed
- Best user experience
- Maximum automation

### **If Denied:**
- Move to **Option B** (remove feature) for pilot deployment
- Focus on proven RushResolve features (printers, domain, diagnostics)
- Revisit WinGet in Phase 2 after pilot success proves value

---

## Updated Deployment Plan

### **Pilot Deployment (Now):**
1. **Test without WinGet** - Deploy RushResolve with Software Updates disabled
2. **Focus on core features:**
   - Printer Management (proven time-saver)
   - Domain Tools (standardized troubleshooting)
   - Diagnostics (proactive health checks)
   - Battery Monitoring (new!)

### **After Pilot Success:**
3. **Leverage pilot wins** to justify WinGet approval:
   > "RushResolve saved techs X hours/week on printer management alone. Adding WinGet would extend this to software updates, which currently take Y hours/week."

4. **Request WinGet whitelist** based on proven RushResolve value

---

## Communication Strategy

### **For Executive Brief:**

**Current version says:**
> "Software update scanner using WinGet"

**Revised version:**
> "Software management toolkit (pending Cybersecurity approval for automated updates; currently manual workflow)"

### **For Demo:**

**Option 1 (If WinGet works):**
- Show update scanning feature
- Emphasize automation

**Option 2 (If WinGet blocked):**
- Skip Software Updates tab
- Focus demo on printers, domain, diagnostics
- Mention software updates as "Phase 2 enhancement"

---

## Questions for RUSH IT

Before deployment, clarify:

1. **Is WinGet blocked intentionally?**
   - Yes → Need approval to whitelist
   - No → Configuration issue, can be fixed

2. **What's the blocker?**
   - AppLocker → Whitelist request
   - Network → Firewall rule request
   - Policy → Exception request

3. **Is there an approval process?**
   - Submit ticket to Cybersecurity?
   - Need business justification?
   - Timeline for approval?

4. **Fallback option acceptable?**
   - Can we deploy without WinGet feature?
   - Would manual workflow (Option C) be acceptable?

---

## Bottom Line

**WinGet being blocked is not a showstopper.**

RushResolve's core value is in:
- ✅ Printer Management (works without WinGet)
- ✅ Domain Tools (works without WinGet)
- ✅ Diagnostics (works without WinGet)
- ✅ Network Tools (works without WinGet)
- ✅ AD Tools (works without WinGet)

**Software Updates is a bonus feature, not critical path.**

**Recommendation:** Deploy without WinGet for pilot, prove value, then request approval for Phase 2.
