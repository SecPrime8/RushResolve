# RushResolve

**Portable IT Technician Toolkit for Rush University Medical Center**

Version: 2.6.0 | License: Internal Use

---

## Overview

RushResolve is a modular PowerShell GUI application designed for IT field technicians at Rush University Medical Center. It provides a centralized toolkit for common IT tasks including system diagnostics, software deployment, printer management, Active Directory operations, and more.

### Key Features

- 🔒 **Security-First Design** - PIN-protected credential caching, SHA256 verification, TLS 1.2+ enforcement
- 📦 **Modular Architecture** - 8 specialized modules for different IT tasks
- 🎯 **Field-Tested** - Built for real-world hospital IT environments
- 📊 **Session Logging** - Comprehensive logging for troubleshooting and auditing

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
   Expand-Archive -Path RushResolveApp_v2.6.0.zip -DestinationPath C:\Tools\
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

### [2.6.0] - 2026-02-18

#### Added
- **Module 7** - Inline DISM/SFC output with UAC RunAs elevation (no external windows)
- **Module 3** - Rewritten printer add with `printui.dll` and activity log panel
- **Module 2** - Fixed HPIA driver parsing and two-phase install workflow
- **Core** - `Resolve-ToUNCPath`, `Connect-NetworkShare` for SMB auth

#### Fixed
- **Module 3** - UI hang and privilege escalation on Windows 10
- **Module 7** - Removed internet-dependent RestoreHealth (blocked by GPO)

### [2.5.0] - 2026-02-10
- Session logging with computer info headers
- Sortable printer columns, backup/restore printers
- LLDP alternative method for network tools
- RSAT check for Active Directory button

See [CHANGELOG.md](CHANGELOG.md) for full history.

---

## License

**Internal Use Only** - Rush University Medical Center IT Field Services

This software is proprietary and confidential. Unauthorized copying, distribution, or modification is prohibited.

---

## Credits

**Development:** Rush IT Field Services Team
**Security Review:** KILA Strategies (Claude Code)
**Version:** 2.6.0
**Last Updated:** 2026-02-18

---

**Made with ❤️ for Rush University Medical Center IT Technicians**
