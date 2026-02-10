New Teams Offline Package (v2)

What this fixes:
- Existing users: removes Teams (classic) and installs New Teams
- NEW users (first login): prevents Teams (classic) from coming back by cleaning Default profile + disabling MSI reinstall

Files required in the SAME folder:
- Fix-Teams-MultiUser_Offline_v2.ps1
- Run-Fix-Teams_v2.cmd
- teamsbootstrapper.exe
- MSTeams-x64.msix

Run (recommended):
1) Copy these files to your USB folder:
   D:\Rush software\Teams
2) On the target computer:
   Right-click Run-Fix-Teams_v2.cmd -> Run as administrator

Logs:
- C:\ProgramData\NewTeamsOffline\Fix-Teams.log

Notes:
- Script sets: HKLM\SOFTWARE\Microsoft\Office\Teams\PreventInstallationFromMsi = 1
  This helps stop classic Teams from reinstalling per-user.
- Script also removes consumer "MicrosoftTeams" AppX (Teams free) if present.
  It does NOT remove the work/school MSTeams package.
