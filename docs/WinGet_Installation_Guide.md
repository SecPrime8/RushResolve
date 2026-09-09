# WinGet Installation Guide for Locked-Down Environments

**Problem:** Microsoft Store is blocked by IT policy, but RushResolve's Software Updates feature requires WinGet (App Installer).

**Solution:** Install WinGet manually without Microsoft Store access.

---

## Method 1: Direct .msixbundle Install (Recommended)

### Steps:

1. **Download the latest WinGet installer:**
   - Go to: https://github.com/microsoft/winget-cli/releases/latest
   - Download `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle`

2. **Download dependencies (required):**
   - VCLibs: https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx
   - UI.Xaml: https://github.com/microsoft/microsoft-ui-xaml/releases
     - Download `Microsoft.UI.Xaml.2.x.x64.appx` (latest 2.x version)

3. **Install via PowerShell (Admin required):**
   ```powershell
   # Install dependencies first
   Add-AppxPackage Microsoft.VCLibs.x64.14.00.Desktop.appx
   Add-AppxPackage Microsoft.UI.Xaml.2.8.x64.appx

   # Install WinGet
   Add-AppxPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
   ```

4. **Verify installation:**
   ```powershell
   winget --version
   ```

---

## Method 2: Chocolatey Alternative (If WinGet Blocked)

If WinGet installation is blocked by Group Policy, use Chocolatey instead:

### Install Chocolatey:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
```

### Modify RushResolve Module 02:
Replace WinGet commands with Chocolatey equivalents:
- `winget upgrade --include-unknown` → `choco outdated`
- `winget upgrade --id <AppId>` → `choco upgrade <PackageName>`

---

## Method 3: SCCM/Intune Deployment (Enterprise)

**For IT Admins deploying to all techs:**

1. Package WinGet + dependencies into .zip
2. Deploy via SCCM/Intune as a Win32 app
3. Installation script:
   ```powershell
   Add-AppxPackage -Path ".\Microsoft.VCLibs.x64.14.00.Desktop.appx"
   Add-AppxPackage -Path ".\Microsoft.UI.Xaml.2.8.x64.appx"
   Add-AppxPackage -Path ".\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
   ```

---

## Method 4: Manual Update Workflow (No WinGet)

If WinGet cannot be installed due to policy restrictions:

### Remove Software Updates Feature:
Comment out or remove the "Check for Updates" tab from `Module 02` to avoid confusion for techs.

### Alternative:
- Use Module 02's existing manual software installer capabilities
- Deploy software via SCCM/Intune instead
- Document this limitation in deployment guide

---

## For RushResolve Deployment at RUSH:

### Decision Required:
1. **Can WinGet be installed?**
   - Yes → Use Method 1 (manual install) or Method 3 (SCCM deployment)
   - No → Use Method 4 (remove feature) or consider Chocolatey

2. **Group Policy Check:**
   - Verify if AppX package installation is allowed
   - Check with Cybersecurity if WinGet is approved

3. **Fallback Plan:**
   - Software Updates tab can be hidden if WinGet unavailable
   - Core RushResolve functionality (printers, domain, diagnostics) unaffected

---

## Quick Test (Check if AppX packages allowed):

```powershell
# Try to get existing AppX packages (if this fails, AppX is blocked)
Get-AppxPackage -Name Microsoft.DesktopAppInstaller
```

If this command returns nothing or errors, AppX installation may be blocked by Group Policy.

---

**Recommendation for RUSH:**
Contact IT/Cybersecurity to request WinGet deployment via SCCM or approval for manual installation. If denied, remove Software Updates feature from Module 02 for deployment.
