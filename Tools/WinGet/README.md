# WinGet Portable Setup

This folder contains the WinGet installer for USB deployment.

## What to Download

Download these 3 files and place them in this folder:

### 1. WinGet Installer
**File:** `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle`
**Download from:** https://github.com/microsoft/winget-cli/releases/latest
- Look for "Assets" section
- Download the `.msixbundle` file (usually ~45 MB)

### 2. VCLibs Dependency
**File:** `Microsoft.VCLibs.x64.14.00.Desktop.appx`
**Download from:** https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx
- Direct download link (opens download immediately)
- File size: ~500 KB

### 3. UI.Xaml Dependency
**File:** `Microsoft.UI.Xaml.2.8.x64.appx` (or latest 2.x version)
**Download from:** https://github.com/microsoft/microsoft-ui-xaml/releases
- Look for latest 2.x release (e.g., 2.8.6)
- Download `Microsoft.UI.Xaml.2.8.x64.appx` from Assets
- File size: ~2-3 MB

---

## Folder Structure

After downloading, your folder should look like this:

```
Tools/WinGet/
├── README.md (this file)
├── Install-WinGet.ps1 (auto-installer script)
├── Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
├── Microsoft.VCLibs.x64.14.00.Desktop.appx
└── Microsoft.UI.Xaml.2.8.x64.appx
```

---

## How It Works

1. **Module 02 checks** if WinGet is already installed on the machine
2. **If not found**, runs `Install-WinGet.ps1` from this folder
3. **Installs per-user** (no admin rights required)
4. **Then runs** the update scan

This makes RushResolve fully portable - WinGet installs automatically from USB!

---

## Manual Installation (Optional)

If you want to pre-install WinGet on a machine:

```powershell
# Run from this directory
.\Install-WinGet.ps1
```

Or manually:
```powershell
Add-AppxPackage .\Microsoft.VCLibs.x64.14.00.Desktop.appx
Add-AppxPackage .\Microsoft.UI.Xaml.2.8.x64.appx
Add-AppxPackage .\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle
```

---

## Verification

After installation, verify WinGet works:
```powershell
winget --version
```

Should output something like: `v1.7.10861`

---

## Notes

- **Per-user install**: Each user on the machine needs WinGet installed separately
- **No admin required**: AppX packages can be installed per-user without elevation
- **Updates**: WinGet will auto-update itself via Microsoft Store (if Store enabled)
- **Offline compatible**: These files work without internet connection during install

---

## Troubleshooting

**"Add-AppxPackage : Deployment failed" error:**
- Check if Group Policy blocks AppX package installation
- Try running PowerShell as Administrator
- Verify files are not corrupted (re-download if needed)

**WinGet not found after install:**
- Restart PowerShell session (close and reopen)
- Check PATH: `$env:LOCALAPPDATA\Microsoft\WindowsApps`
- Log out and back in (refreshes user environment)

**"This app can't run on your PC" error:**
- Wrong architecture (download x64 version, not ARM)
- Windows 10 version too old (need 1809 or later)
