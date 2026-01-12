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

## Notes

- Modules should follow existing patterns in `docs/module-template.md`
- All operations should use `Write-SessionLog` for audit trail
- Elevated operations use `Get-ElevatedCredential` / `Invoke-Elevated`
- No passwords logged, ever
