# WinGet USB Deployment Setup Guide

**Goal:** Make RushResolve fully portable with WinGet running from USB drive.

---

## How It Works

RushResolve now includes **automatic WinGet installation** from USB:

1. **First Run:** Module 02 checks if WinGet is installed on the machine
2. **If Missing:** Automatically installs WinGet from bundled files in `Tools/WinGet/`
3. **Per-User Install:** No admin rights required
4. **Then Scans:** Runs update scan immediately after installation

**Result:** WinGet installs once per user, then works forever on that machine.

---

## Setup Instructions (One-Time)

### Step 1: Download WinGet Files

Download these 3 files from Microsoft:

#### 1. WinGet Installer (~45 MB)
- **URL:** https://github.com/microsoft/winget-cli/releases/latest
- **File:** `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle`
- **How:** Click "Assets" → Download `.msixbundle` file

#### 2. VCLibs Dependency (~500 KB)
- **URL:** https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx
- **File:** `Microsoft.VCLibs.x64.14.00.Desktop.appx`
- **How:** Direct download (opens immediately)

#### 3. UI.Xaml Dependency (~2-3 MB)
- **URL:** https://github.com/microsoft/microsoft-ui-xaml/releases
- **File:** `Microsoft.UI.Xaml.2.8.x64.appx` (or latest 2.x version)
- **How:** Find latest 2.x release → Assets → Download `.appx` file

---

### Step 2: Copy to USB Drive

Copy the 3 downloaded files to:
```
RushResolveApp/
└── Tools/
    └── WinGet/
        ├── README.md (already there)
        ├── Install-WinGet.ps1 (already there)
        ├── Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle ← COPY HERE
        ├── Microsoft.VCLibs.x64.14.00.Desktop.appx ← COPY HERE
        └── Microsoft.UI.Xaml.2.8.x64.appx ← COPY HERE
```

**That's it!** RushResolve is now fully portable.

---

## Usage

### For Field Techs:

1. **Plug in USB** with RushResolve
2. **Run RushResolve.ps1**
3. **Go to Software Installer → Check for Updates tab**
4. **Click "Check for Updates"**

**First Time:**
- Sees "WinGet not found. Attempting to install from USB..."
- Installs automatically (takes ~10-15 seconds)
- Then runs update scan

**Every Time After:**
- WinGet is already installed
- Scan runs immediately

---

## What Gets Installed

**Location:** Per-user AppX package
- Installed to: `%LOCALAPPDATA%\Microsoft\WindowsApps\`
- Visible to: Only the current user
- Admin required: No
- Persists: Yes (stays after USB unplugged)

**Why per-user?**
- No admin rights needed
- Doesn't affect other users on shared machines
- Complies with RUSH security policies (no system-wide changes)

---

## Troubleshooting

### "WinGet installation failed"

**Possible Causes:**
1. **Group Policy blocks AppX installation**
   - Contact RUSH IT to check Group Policy settings
   - May need exception for field tech accounts

2. **Windows 10 version too old**
   - Requires Windows 10 1809 or later
   - Run `winver` to check version
   - Update Windows if needed

3. **Files missing or corrupted**
   - Verify all 3 files are in `Tools\WinGet\` folder
   - Re-download files from URLs above
   - Check file sizes match expected sizes

### "Installation completed but WinGet command not found"

**Solution:** Restart PowerShell
- Close RushResolve
- Reopen RushResolve
- WinGet should now work

**Why:** PATH environment variable needs refresh

### "Access denied" during installation

**Solution:** Check disk permissions
- USB drive should not be read-only
- User should have permission to install AppX packages
- Try running RushResolve as Administrator (one time only)

---

## Verification

Test WinGet installation manually:

```powershell
# Check if WinGet is available
winget --version

# Should output something like: v1.7.10861
```

If this works, RushResolve's update scanner will work too.

---

## Deployment to Multiple USB Drives

### For RUSH IT Deployment:

1. **Set up one USB drive** (master) with all 3 WinGet files
2. **Test thoroughly** on 2-3 machines
3. **Clone to other USB drives:**
   ```
   Copy entire RushResolveApp folder to each USB
   ```
4. **Distribute to field techs**

**Each tech's first use:**
- WinGet installs automatically from USB
- Takes 10-15 seconds
- Works forever after that

---

## Network Share Alternative

Instead of USB drives, can deploy from network share:

1. **Copy RushResolve to:** `\\RUMC-FS01\IT\RushResolve\`
2. **Set permissions:** Read-only for field techs
3. **Techs run from:** Network share (no USB needed)
4. **WinGet installs:** Same process, from network location

**Benefit:** Centralized updates (change one place, all techs get it)

---

## Security Notes

### Why This Is Safe:

✅ **Microsoft Official Files:** All 3 files are from Microsoft's official sources (GitHub/Microsoft servers)
✅ **Code Signing:** Files are cryptographically signed by Microsoft
✅ **Per-User Install:** No system-wide changes, no admin elevation
✅ **No Internet Required:** Installation works completely offline
✅ **Auditable:** Cybersecurity can verify file signatures and hashes

### File Verification (Optional):

Verify files are authentic:

```powershell
# Check digital signature
Get-AuthenticodeSignature .\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle

# Should show:
# SignerCertificate: CN=Microsoft Corporation, ...
# Status: Valid
```

---

## Cybersecurity Approval Talking Points

When requesting approval from RUSH Cybersecurity:

1. **Microsoft Official Tool**
   - WinGet is Microsoft's package manager (like PowerShell)
   - Not third-party software

2. **No External Dependencies**
   - Installs completely from USB (no internet downloads during install)
   - Files can be validated before deployment

3. **Per-User Install**
   - No system-wide changes
   - Doesn't require admin rights
   - Each user has their own instance

4. **Security Benefits**
   - Reduces risk of techs downloading software from fake websites
   - All packages are cryptographically signed
   - Better than manual .exe downloads from Google searches

5. **Portable Deployment**
   - No installation on servers or domain infrastructure
   - USB-based, techs carry their own toolkit
   - Easy to update (just update master USB, re-clone)

---

## Future Enhancements

Once WinGet is working:

### Phase 2: Auto-Install Updates
- Add "Update Selected" button functionality
- One-click silent installation of outdated apps
- Progress bar and logging

### Phase 3: Pre-Approved Software
- Whitelist of RUSH-approved applications
- Block installation of non-approved software
- Compliance with RUSH software policies

### Phase 4: Offline Package Cache
- Cache frequently-updated apps (Chrome, Acrobat, etc.) on USB
- Install from local cache instead of downloading
- Faster installations in offline scenarios

---

## Summary

**Setup Time:** 10 minutes (one-time download + copy to USB)
**Tech First-Use:** 15 seconds (auto-install)
**Ongoing Use:** Instant (WinGet already installed)
**Admin Rights:** Not required
**Internet:** Not required for installation

**Result:** Fully portable RushResolve with automatic software update detection!
