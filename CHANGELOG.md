# Rush Resolve Changelog

## v2.3 (2026-01-12)
### New Features
- **Session Logging** - All operations logged to `Logs/` folder
  - New log file per session: `session_YYYY-MM-DD_HHmmss.log`
  - Logs app start/close, module loads, credential operations
  - Logs domain operations (trust tests, repairs, joins)
  - Logs disk cleanup operations
  - Logs system reboot/shutdown commands
  - **No passwords or PINs logged** for security
  - View logs via Help > View Session Logs

## v2.2 (2026-01-12)
### New Features
- **Copy Password to Clipboard** - Tools > Credential Options > Copy Password to Clipboard
  - Unlock with PIN, copies password for pasting into other apps
  - Auto-clears clipboard after 30 seconds for security
- **Disk Cleanup Module** - New tab with two sub-tabs:
  - **Safe Cleanup**: 12 categories (temp files, browser caches, Windows Update cache, Recycle Bin, error dumps, old logs, installer leftovers)
  - **Large Unused Files**: Find files not accessed in 90+ days, sortable by size/date

## v2.1 (2026-01-07)
### Security Hardening
- Module whitelist with SHA256 hash verification
- Application integrity checking on startup
- Security mode controls (Enforced/Warn/Disabled)
- PIN complexity enforcement (6+ digits)
- First-run security initialization workflow
- Print server allowlist (hardcoded approved servers only)
- Dropdown-based server selection (prevents injection)
- Printer name sanitization

## v2.0 (2025-12-xx)
### Initial Modular Release
- Modular architecture with tab-based UI
- PIN-protected credential caching with DPAPI encryption
- 5 core modules:
  - System Info
  - Software Installer
  - Printer Management
  - Domain Tools
  - Network Tools
- Settings persistence (JSON)
- Elevated operations framework

## v1.x (Legacy)
- Standalone scripts in Tools/ folder
- No unified interface
