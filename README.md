# RushResolve

**Portable IT Technician Toolkit for Rush University Medical Center**

Version: 2.5.0 | License: Internal Use

---

## Overview

RushResolve is a modular PowerShell GUI application designed for IT field technicians at Rush University Medical Center. It provides a centralized toolkit for common IT tasks including system diagnostics, software deployment, printer management, Active Directory operations, and more.

### Key Features

- **🔄 Auto-Update Mechanism** - Click "Check for Updates" to safely upgrade from GitHub
- **🔒 Security-First Design** - PIN-protected credential caching, SHA256 verification, TLS 1.2+ enforcement
- **📦 Modular Architecture** - 8 specialized modules for different IT tasks
- **💾 Automatic Backup** - Creates backups before updates with auto-rollback on failure
- **🎯 Field-Tested** - Built for real-world hospital IT environments
- **📊 Session Logging** - Comprehensive logging for troubleshooting and auditing

---

## Installation

### Prerequisites

- **Operating System:** Windows 10 (build 1809+) or Windows 11
- **PowerShell:** 5.1 or later
- **Permissions:** Standard user (admin elevation handled per-operation)
- **.NET Framework:** 4.7.2 or later

### Quick Start

1. **Download the latest release:**
   ```powershell
   # Download from GitHub Releases
   # https://github.com/SecPrime8/RushResolve/releases/latest
   ```

2. **Extract to desired location:**
   ```powershell
   # Example: C:\Tools\RushResolveApp
   Expand-Archive -Path RushResolveApp_v2.4.0.zip -DestinationPath C:\Tools\
   ```

3. **Run the application:**
   ```powershell
   # Right-click RushResolve.ps1 → Run with PowerShell
   # OR from PowerShell console:
   cd C:\Tools\RushResolveApp
   .\RushResolve.ps1
   ```

### First-Time Setup

On first launch:
1. Accept execution policy (if prompted)
2. Configure settings via Tools → Settings
3. Optionally cache domain credentials (PIN-protected)
4. Review session log location: `Logs/`

---

## Auto-Update Feature (New in v2.4.0)

### How to Update

1. Click **Help → Check for Updates**
2. Review release notes in the dialog
3. Click **Update Now**
4. Wait for automatic backup, download, and installation (~30 seconds)
5. Application restarts with new version

### What Happens During Update

- ✅ Downloads latest release from GitHub
- ✅ Verifies SHA256 hash (if provided in release notes)
- ✅ Creates backup to `Safety/Backups/`
- ✅ Preserves your settings (`Config/settings.json`)
- ✅ Regenerates security manifests
- ✅ Auto-rolls back if any step fails

### Update Safety

- **Automatic backups** kept in `Safety/Backups/` (last 3 versions)
- **Settings preserved** across updates
- **Auto-rollback** on download failure, hash mismatch, or integrity errors
- **HTTPS enforcement** prevents man-in-the-middle attacks
- **Session logging** tracks all update operations

---

## Modules

### 1. System Info (Module 01)
- System specifications (CPU, RAM, disk, network)
- Windows version and license status
- Hardware inventory
- Export to CSV

### 2. Software Installer (Module 02)
- One-click installers for common applications
- Epic Hyperspace, Microsoft 365, Teams, Chrome, Acrobat
- Batch installation support
- Custom installer integration

### 3. Printer Management (Module 03)
- Add network printers by IP or hostname
- Search printer by location/name
- Driver installation
- Test page printing
- Printer status verification

### 4. Domain Tools (Module 04)
- Computer rename with AD update
- Domain trust repair
- Force Group Policy update
- DNS cache flush
- Credential cache with PIN protection

### 5. Network Tools (Module 05)
- IP configuration (static/DHCP)
- DNS server configuration
- Network adapter enable/disable
- Speed test
- Connectivity diagnostics

### 6. Disk Cleanup (Module 06)
- Automated cleanup routines
- Temp file removal
- Windows Update cache cleanup
- Disk space analysis
- Safe file deletion

### 7. Diagnostics (Module 07)
- System event log analysis
- Performance monitoring
- Hardware diagnostics
- Network troubleshooting
- Error log collection

### 8. Active Directory Tools (Module 08)
- User account search and unlock
- Group membership management
- Password reset (with proper permissions)
- Computer object management
- OU navigation

---

## Security

### Security Architecture

- **PIN-Protected Credentials** - AES-256 encryption with PBKDF2 key derivation
- **Module Whitelisting** - SHA256 manifest prevents unauthorized module loading
- **TLS 1.2+ Enforcement** - All HTTPS connections use modern TLS
- **Command Injection Prevention** - Array-based argument passing
- **Brute-Force Protection** - Exponential backoff on failed PIN attempts (3s, 6s, 9s)
- **Session Logging** - All operations logged with timestamps

### Credential Caching

Cached credentials are:
- **Encrypted** with AES-256 using PIN-derived key
- **Protected** by 10,000 PBKDF2 iterations
- **Time-limited** - PIN re-verification after 15 minutes
- **Lockout** - 3 failed attempts = session lockout
- **Clipboard auto-clear** - 30 seconds after password copy

### Update Security

- **SHA256 verification** for downloaded updates
- **HTTPS-only downloads** - HTTP URLs rejected
- **Integrity checks** - File count and syntax validation
- **Automatic rollback** on security failures

See [SECURITY-FIXES.md](SECURITY-FIXES.md) for complete security audit report.

---

## Configuration

### Settings File

Location: `Config/settings.json`

```json
{
  "LastUser": "DOMAIN\\username",
  "CacheCredentials": false,
  "AutoCheckUpdates": false,
  "Theme": "Light",
  "LogRetentionDays": 30
}
```

### Module Customization

Modules are located in `Modules/` and follow naming convention:
- `01_SystemInfo.ps1`
- `02_SoftwareInstaller.ps1`
- etc.

Each module must define:
- `$script:ModuleName` - Display name
- `$script:ModuleDescription` - Tooltip text
- `Initialize-Module` function - Creates UI

See [docs/module-template.md](docs/module-template.md) for development guide.

---

## Logging

### Session Logs

Location: `Logs/SESSION-<ComputerName>-<Timestamp>.log`

Example:
```
[2026-02-09 14:35:22] Application started (v2.4.0)
[14:35:25] [Credentials] Cached credentials loaded successfully
[14:36:10] [Update] Check for updates initiated by user
[14:36:12] [Update] GitHub API response: latest version is v2.4.0
[14:36:13] [Update] You're running the latest version
```

### View Logs

Click **Help → View Session Logs** to open logs folder.

---

## Troubleshooting

### "Execution policy prevents script from running"

**Solution:**
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass
```

### "Module blocked by security manifest"

**Cause:** Module file was modified or not in whitelist

**Solution:**
```powershell
# Regenerate security manifests
# Tools → Security → Update Security Manifests
```

### "Cannot reach GitHub" during update

**Cause:** Firewall blocks api.github.com

**Solution:**
- Whitelist `api.github.com` and `github.com` in firewall
- Verify proxy settings
- Test: `Invoke-RestMethod -Uri https://api.github.com/repos/SecPrime8/RushResolve/releases/latest`

### "Hash verification failed"

**Cause:** Downloaded file doesn't match expected SHA256

**Solution:**
- Retry update (network corruption)
- If persists, verify GitHub account not compromised
- Manual download and verify hash:
  ```powershell
  (Get-FileHash .\RushResolveApp_v2.4.0.zip -Algorithm SHA256).Hash
  ```

### "Settings lost after update"

**Cause:** Bug in settings preservation (rare)

**Solution:**
- Restore from backup: `Safety/Backups/RushResolveApp_v2.3_backup_<timestamp>.zip`
- Extract only `Config/settings.json` from backup

---

## Development

### Building from Source

```powershell
# Clone repository
git clone https://github.com/SecPrime8/RushResolve.git
cd RushResolve

# Run application
.\RushResolve.ps1

# Update security manifests after code changes
# Tools → Security → Update Security Manifests
```

### Creating a Module

1. Copy `docs/module-template.md`
2. Create new file: `Modules/09_YourModule.ps1`
3. Define `$script:ModuleName` and `Initialize-Module`
4. Update security manifests
5. Test in application

### Release Process

1. Update version number in `RushResolve.ps1` (line 165)
2. Update `CHANGELOG.md`
3. Commit changes
4. Create release ZIP:
   ```powershell
   Compress-Archive -Path * -DestinationPath RushResolveApp_v2.4.0.zip
   ```
5. Generate SHA256:
   ```powershell
   (Get-FileHash RushResolveApp_v2.4.0.zip -Algorithm SHA256).Hash
   ```
6. Create GitHub release:
   - Tag: `v2.4.0`
   - Upload ZIP
   - Include SHA256 in release notes

---

## File Structure

```
RushResolveApp/
├── RushResolve.ps1              # Main application
├── Config/
│   └── settings.json            # User settings
├── Modules/
│   ├── 01_SystemInfo.ps1        # Module: System Info
│   ├── 02_SoftwareInstaller.ps1 # Module: Software Installer
│   └── ...                      # Other modules
├── Lib/
│   └── QRCoder.dll             # QR code generation library
├── Security/
│   └── module-manifest.json    # Module whitelist with hashes
├── Safety/
│   └── Backups/                # Auto-update backups
├── Logs/                       # Session logs
├── Tools/                      # Helper scripts and installers
└── docs/                       # Documentation

```

---

## System Requirements

### Minimum

- Windows 10 (1809+)
- 4 GB RAM
- 500 MB disk space
- PowerShell 5.1
- .NET Framework 4.7.2

### Recommended

- Windows 11
- 8 GB RAM
- 1 GB disk space
- PowerShell 7.x
- .NET 6+

### Network

- Internet access for updates
- Access to `api.github.com` and `github.com`
- TLS 1.2+ support
- (Optional) Active Directory domain membership for AD tools

---

## Support

### Documentation

- [Installation Guide](docs/Demo_Script.md)
- [Security Review](SECURITY-FIXES.md)
- [Implementation Details](AUTO-UPDATE-IMPLEMENTATION.md)
- [Module Template](docs/module-template.md)

### Issues

Report issues at: https://github.com/SecPrime8/RushResolve/issues

### Contact

- **Organization:** Rush University Medical Center - IT Field Services
- **Repository:** https://github.com/SecPrime8/RushResolve

---

## Changelog

### [2.4.0] - 2026-02-09

#### Added
- **Auto-update mechanism** - "Check for Updates" in Help menu
- SHA256 hash verification for update packages
- Automatic backup before updates (rollback on failure)
- Settings preservation across updates
- TLS 1.2+ enforcement for HTTPS connections
- PIN brute-force protection with exponential backoff
- Command injection prevention in restart process
- HTTPS validation for downloads

#### Changed
- Help menu reorganized (updates at top)
- Session logging enhanced with `[Update]` category

#### Security
- All critical security vulnerabilities from pre-release audit resolved
- See [SECURITY-FIXES.md](SECURITY-FIXES.md) for complete details

### [2.3] - 2026-01-09
- Initial stable release
- 8 functional modules
- PIN-protected credential caching
- Module security whitelisting
- Session logging

See [CHANGELOG.md](CHANGELOG.md) for full history.

---

## License

**Internal Use Only** - Rush University Medical Center IT Field Services

This software is proprietary and confidential. Unauthorized copying, distribution, or modification is prohibited.

---

## Credits

**Development:** Rush IT Field Services Team
**Security Review:** KILA Strategies (Claude Code)
**Version:** 2.4.0
**Last Updated:** 2026-02-09

---

**Made with ❤️ for Rush University Medical Center IT Technicians**
