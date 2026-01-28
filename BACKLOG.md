# Rush Resolve Feature Backlog

## Planned Modules

### AD Tools
- Password reset for users
- Account unlock
- Group membership lookup
- User info lookup (last logon, account status)

### ServiceNow Helper
- Auto-generate resolution notes from session log
- Copy formatted notes to clipboard for ticket closure
- Template-based notes (e.g., "Printer added", "Trust repaired")

### User Data Backup/Restore
- Quick backup of user profile data (Desktop, Documents, Downloads)
- Restore to new machine
- Progress indicator for large transfers

### Windows Update Management
- Check for pending updates
- Install updates (with reboot scheduling)
- Pause updates temporarily
- Clear Windows Update cache (already in Disk Cleanup)

### BitLocker Management
- View BitLocker status
- Retrieve recovery key from AD
- Suspend/resume BitLocker for maintenance

### Remote Tools
- Launch remote assistance
- Quick RDP to another machine
- Remote registry access

---

## Feature Ideas

### LLDP Network Discovery (Pending Hospital Approval)
- Enable/check LLDP agent status on workstation
- Display connected switch name and port
- Useful for cable tracing without physical inspection
- Requires: `Enable-NetLldpAgent` - needs approval from hospital IT
- Status: Awaiting approval (see proposals/RushResolve-Hospital-Approval.md)

### AppLocker / Security Policy Refresh
- Trigger gpupdate for AppLocker rules
- Force rerun of application blocking policies
- Status check for policy application

### Workorder / Service Receipt Printout
- Generate printable "proof of service" document
- Include:
  - Technician name
  - Date/time of visit
  - Computer name / asset tag
  - Summary of work performed (pull from session log)
  - Next steps / return date if applicable
  - Customer signature line
- Could tie into session logging - "Print Service Summary" button
- PDF or direct print option

---

## Completed (for reference)

- [x] System Info module
- [x] Software Installer module
- [x] Printer Management module
- [x] Domain Tools module
- [x] Network Tools module
- [x] Disk Cleanup module (v2.2)
- [x] Copy Password to Clipboard (v2.2)
- [x] Session Logging (v2.3)
- [x] Security hardening - module whitelist, hash verification (v2.1)
- [x] Print server allowlist (v2.2)

---

## Security Improvements (2026-01-27 Brainstorm)

| Priority | Improvement | Effort | Impact |
|----------|-------------|--------|--------|
| 1 | **Bundle QRCoder.dll** - eliminate runtime NuGet download | Low | High |
| 2 | **SHA256 verify software packages** before install | Medium | High |
| 3 | **Authenticode code signing** for distribution | Medium | High |
| 4 | **LAPS integration** - JIT credential fetch, eliminate stored creds | High | Very High |

---

## Efficiency Improvements (2026-01-27 Brainstorm)

| Priority | Improvement | Effort | Impact |
|----------|-------------|--------|--------|
| 1 | **Quick Actions panel** - 5 big buttons for common tasks | Low | Medium |
| 2 | **Software favorites** - save frequently-used installer paths | Low | Medium |
| 3 | **Export diagnostics to HTML** - shareable reports | Low | Medium |
| 4 | **Searchable printer dropdown** with fuzzy matching | Medium | Medium |

---

## UX Ideas (2026-01-27 Brainstorm)

- **Operation rollback** - undo last printer add, restore DNS settings
- **Pre-flight confirmation** for destructive ops (rejoin domain, disk cleanup)
- **Smart routing** - symptom input suggests relevant module
- **Centralized logging** to network share or SIEM
- **Configurable credential timeout** (5/10/15 min options)
- **Offline mode** with sync queue for network-unavailable scenarios
- **Tech stats** - tickets resolved, time saved (optional gamification)

**Asymmetric move:** ServiceNow integration is highest leverage (~50 hrs/week total savings when combined with existing app benefits)

---

## Notes

- Modules should follow existing patterns in `docs/module-template.md`
- All operations should use `Write-SessionLog` for audit trail
- Elevated operations use `Get-ElevatedCredential` / `Invoke-Elevated`
- No passwords logged, ever
