# What Is WinGet? (Simple Explanation)

**For techs familiar with Linux:** WinGet is basically `apt-get` or `yum` for Windows.

**For everyone else:** WinGet is a command-line tool that automatically installs, updates, and manages software on Windows.

---

## The Problem It Solves

**Old Way (Manual):**
1. Google "download chrome"
2. Click through multiple pages
3. Download installer
4. Run installer
5. Click through setup wizard
6. Delete installer file
7. Repeat for every app

**With WinGet:**
```powershell
winget install Google.Chrome
```
Done. One command.

---

## The apt-get Analogy

If you've used Linux:

| Linux | Windows (WinGet) |
|-------|------------------|
| `apt-get update` | `winget upgrade --all` |
| `apt-get install firefox` | `winget install Mozilla.Firefox` |
| `apt-get remove chrome` | `winget uninstall Google.Chrome` |
| `apt search` | `winget search` |

**Same concept, different OS.**

---

## Why RushResolve Uses It

### Problem at RUSH:
- Techs need to update software on machines regularly
- Group Policy (GPO) deployments are **slow** (can take days)
- Manual downloads are **tedious** and **error-prone** (wrong version, fake sites, etc.)

### WinGet Solution:
- **One-click updates** in RushResolve
- **Always gets the right version** from official sources
- **Fast** - no waiting for GPO
- **Safe** - packages are cryptographically signed

---

## How RushResolve Uses WinGet

### Step 1: Detection
RushResolve checks if WinGet is installed on the machine.

### Step 2: Auto-Install (if needed)
If WinGet is missing, RushResolve automatically installs it from the USB drive (10-15 seconds, one time only).

### Step 3: Scan for Updates
```powershell
winget upgrade --all
```
RushResolve runs this command in the background and shows you a nice list of outdated apps.

### Step 4: Update (Future Enhancement)
You'll be able to click a checkbox and hit "Update Selected" - WinGet installs updates silently in the background.

---

## What Gets Updated

WinGet knows about **1000+ common applications**:

**Browsers:**
- Google Chrome
- Mozilla Firefox
- Microsoft Edge

**Adobe Products:**
- Adobe Acrobat Reader
- Adobe Creative Cloud apps

**Productivity:**
- Microsoft Office (if licensed through Microsoft Store)
- Zoom
- Teams
- 7-Zip
- Notepad++

**Development Tools:**
- Visual Studio Code
- Git
- Python
- Node.js

**Media:**
- VLC Media Player
- Spotify
- iTunes

And many more...

---

## Security

### Is WinGet Safe?

**YES.** Here's why:

1. **Microsoft Official Tool**
   - Developed AND maintained by Microsoft Corporation
   - Specifically: Windows Developer Platform team at Microsoft
   - Open source: https://github.com/microsoft/winget-cli (Microsoft owns/maintains)
   - Part of Windows 11 by default (pre-installed)
   - Supported by Microsoft as part of Windows ecosystem

2. **Package Verification**
   - All packages are cryptographically signed
   - Microsoft validates publishers
   - Can't install malware through WinGet

3. **No Fake Downloads**
   - Always gets software from official vendor sources
   - No risk of downloading "Chrome" from "chr0me-downl0ad.sketchy-site.ru"

4. **Audit Trail**
   - Every installation is logged
   - Can see what was installed and when

---

## For IT Leadership / Cybersecurity

### Common Questions:

**Q: "Why not just use SCCM/Intune?"**
A: We do! But SCCM deployments can take days. Field techs need to update software **now** (e.g., security patch for Adobe Acrobat). WinGet complements SCCM, doesn't replace it.

**Q: "Can techs install anything they want?"**
A: Technically yes, but we can whitelist approved apps in RushResolve if needed (Phase 2 enhancement).

**Q: "What if a tech installs malware?"**
A: WinGet packages are signed and verified. Can't install non-approved packages. Much safer than techs Googling "download software" and clicking random links.

**Q: "Does it require admin rights?"**
A: Some installs do (system-wide apps), some don't (per-user apps). Same as manual installs.

**Q: "Can we track what gets installed?"**
A: Yes! RushResolve logs every WinGet action to session logs. Can integrate with SIEM if needed.

**Q: "What about licensing?"**
A: WinGet only installs free/trial versions. Licensed software (Office, Adobe CC) still requires license keys from IT.

---

## Technical Details

### How It Works (Under the Hood)

1. **Package Repository**
   - Microsoft hosts a central repository (like Debian's apt repos)
   - Contains metadata about 1000+ apps
   - URL: https://github.com/microsoft/winget-pkgs

2. **Package Manifest**
   - Each app has a manifest (YAML file)
   - Specifies download URL, version, hash, installer arguments

3. **Installation Process**
   ```
   winget install Google.Chrome
   ↓
   Looks up "Google.Chrome" in repository
   ↓
   Downloads installer from google.com/chrome (official source)
   ↓
   Verifies SHA256 hash
   ↓
   Runs installer with silent flags
   ```

4. **Updates**
   ```
   winget upgrade --all
   ↓
   Checks installed versions vs latest
   ↓
   Shows list of outdated apps
   ↓
   Can update one, some, or all
   ```

---

## For Training / Documentation

### Quick Demo Script:

**Show WinGet in action:**

```powershell
# Search for an app
winget search "notepad++"

# Show info about an app
winget show Notepad++.Notepad++

# Install an app
winget install Notepad++.Notepad++

# Check for updates
winget upgrade

# Update a specific app
winget upgrade Google.Chrome

# Update everything
winget upgrade --all
```

**In RushResolve:**
1. Open RushResolve
2. Go to "Software Installer" → "Check for Updates"
3. Click "Check for Updates"
4. See list of outdated apps
5. (Future) Check boxes → Click "Update Selected"

---

## Comparison to Other Package Managers

| Tool | Platform | Notes |
|------|----------|-------|
| **WinGet** | Windows | Microsoft official, built into Windows 11 |
| **Chocolatey** | Windows | Community-driven, been around longer, 10,000+ packages |
| **apt-get** | Debian/Ubuntu | Linux standard |
| **yum/dnf** | Red Hat/CentOS | Linux standard |
| **brew** | macOS | Community-driven |
| **npm** | Node.js | JavaScript packages only |
| **pip** | Python | Python packages only |

**WinGet is the "apt-get for Windows."**

---

## Benefits for RUSH

### For Field Techs:
✅ **Faster** - Update software in seconds instead of minutes
✅ **Easier** - One button instead of hunting for download links
✅ **Safer** - No risk of downloading wrong/fake versions
✅ **Consistent** - Same process every time

### For IT Leadership:
✅ **Audit Trail** - Full logging of what gets installed
✅ **Reduced Risk** - Verified packages, official sources
✅ **Cost Savings** - Less time wasted on manual updates
✅ **Compliance** - Can enforce approved software list

### For End Users:
✅ **Less Downtime** - Techs fix issues faster
✅ **More Secure** - Software stays up-to-date with security patches

---

## Future Enhancements

**Phase 1 (Current):** Detection and scanning
**Phase 2 (Next):** One-click updates
**Phase 3 (Future):** Pre-approved software whitelist
**Phase 4 (Advanced):** Offline package cache on USB

---

## References

**Official Documentation:**
- WinGet Overview: https://learn.microsoft.com/en-us/windows/package-manager/
- Command Reference: https://learn.microsoft.com/en-us/windows/package-manager/winget/
- GitHub Repo: https://github.com/microsoft/winget-cli

**Package Repository:**
- Browse packages: https://winget.run/
- GitHub packages: https://github.com/microsoft/winget-pkgs

---

## TL;DR (Too Long; Didn't Read)

**WinGet = apt-get for Windows**

- Microsoft's official package manager
- Installs/updates 1000+ apps automatically
- RushResolve uses it to scan for outdated software
- Saves techs time, reduces manual download errors
- Safe, verified, logged

**Bottom Line:** Makes software management on Windows as easy as Linux.
