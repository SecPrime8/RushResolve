#Requires -RunAsAdministrator
<#
Fix-Teams-MultiUser_Offline_v2.ps1

Goal:
 - Remove Microsoft Teams (classic) so it DOES NOT come back for NEW user first logon
 - Install/Provision NEW Teams for ALL users using offline files:
     teamsbootstrapper.exe + MSTeams-x64.msix
 - Writes log to: C:\ProgramData\NewTeamsOffline\Fix-Teams.log

Place this PS1 in the SAME folder as:
 - teamsbootstrapper.exe
 - MSTeams-x64.msix
Then run as Administrator (CMD wrapper included).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$BootstrapperSrc  = Join-Path $ScriptDir 'teamsbootstrapper.exe'
$MsixSrc          = Join-Path $ScriptDir 'MSTeams-x64.msix'

$WorkDir          = Join-Path $env:ProgramData 'NewTeamsOffline'
$LogPath          = Join-Path $WorkDir 'Fix-Teams.log'

function Write-Log { param([string]$Message)
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Host "[$ts] $Message"
}
function Ensure-Folder { param([string]$Path)
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}
function Stop-TeamsProcesses {
  Write-Log "Stopping Teams processes..."
  $procNames = @('ms-teams','teams','Teams','Update','squirrel','TeamsUpdater','TeamsUpdate')
  foreach ($n in $procNames) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}

function Get-UninstallEntries {
  $roots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  )
  $all = @()
  foreach ($root in $roots) {
    if (Test-Path $root) {
      foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        try {
          $p = Get-ItemProperty $k.PSPath -ErrorAction Stop
          if ($p.DisplayName) {
            $all += [pscustomobject]@{
              KeyPath=$k.PSPath; KeyName=$k.PSChildName; DisplayName=$p.DisplayName
              DisplayVersion=$p.DisplayVersion; UninstallString=$p.UninstallString; QuietUninstallString=$p.QuietUninstallString
            }
          }
        } catch {}
      }
    }
  }
  return $all
}

function Uninstall-MsiByDisplayNameLike { param([string]$NameLike)
  $entries = Get-UninstallEntries | Where-Object { $_.DisplayName -like $NameLike }
  if (-not $entries) { Write-Log "No uninstall entry found for: $NameLike"; return }
  foreach ($e in $entries) {
    Write-Log "Uninstalling: $($e.DisplayName) $($e.DisplayVersion)"
    $guid = $null
    if ($e.KeyName -match '^\{[0-9A-Fa-f-]{36}\}$') { $guid = $e.KeyName }
    elseif ($e.UninstallString -match '\{[0-9A-Fa-f-]{36}\}') { $guid = $Matches[0] }
    if ($guid) {
      $p = Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart" -Wait -PassThru
      Write-Log "msiexec exit code: $($p.ExitCode)"
    } else { Write-Log "WARN: Could not detect MSI GUID; skipping entry." }
  }
}

function Remove-HKLMRunEntries {
  Write-Log "Removing HKLM Run entries that reinstall classic Teams..."
  $runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
  )
  $namesToRemove = @('TeamsMachineInstaller','com.squirrel.Teams.Teams','Teams','Microsoft Teams')
  foreach ($rk in $runKeys) {
    if (Test-Path $rk) {
      foreach ($n in $namesToRemove) {
        try {
          if ((Get-ItemProperty -Path $rk -Name $n -ErrorAction SilentlyContinue) -ne $null) {
            Remove-ItemProperty -Path $rk -Name $n -ErrorAction SilentlyContinue
            Write-Log "Removed HKLM Run value '$n' from $rk"
          }
        } catch {}
      }
    }
  }
}

function Set-PreventInstallationFromMsi {
  # Helps prevent Office/Teams MSI from reinstalling classic Teams per-user
  $key = 'HKLM:\SOFTWARE\Microsoft\Office\Teams'
  Ensure-Folder $key
  New-ItemProperty -Path $key -Name 'PreventInstallationFromMsi' -PropertyType DWord -Value 1 -Force | Out-Null
  Write-Log "Set HKLM\SOFTWARE\Microsoft\Office\Teams\PreventInstallationFromMsi = 1"
}

function Get-ProfileList {
  $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
  if (-not (Test-Path $profileList)) { return @() }
  $items = @()
  foreach ($sidKey in (Get-ChildItem $profileList -ErrorAction SilentlyContinue)) {
    $sid = $sidKey.PSChildName
    try {
      $p = Get-ItemProperty $sidKey.PSPath -ErrorAction Stop
      $path = $p.ProfileImagePath
      if (-not $path) { continue }
      if (-not (Test-Path $path)) { continue }
      if ($path -match '\\(Default|Default User|Public|All Users)$') { continue }
      if ($path -match '\\ServiceProfiles\\') { continue }
      $items += [pscustomobject]@{ Sid=$sid; Path=$path }
    } catch {}
  }
  $items | Sort-Object Path -Unique
}

function Remove-ClassicTeamsFoldersInProfile { param([string]$ProfilePath)
  $toRemove = @(
    (Join-Path $ProfilePath 'AppData\Local\Microsoft\Teams'),
    (Join-Path $ProfilePath 'AppData\Roaming\Microsoft\Teams'),
    (Join-Path $ProfilePath 'AppData\Roaming\Microsoft Teams'),
    (Join-Path $ProfilePath 'AppData\Local\SquirrelTemp'),
    (Join-Path $ProfilePath 'AppData\Local\Microsoft\TeamsMeetingAddin'),
    (Join-Path $ProfilePath 'AppData\Local\Microsoft\TeamsPresenceAddin')
  )
  foreach ($r in $toRemove) {
    try { if (Test-Path $r) { Remove-Item $r -Recurse -Force; Write-Log "Removed: $r" } }
    catch { Write-Log "WARN: Could not remove $r : $($_.Exception.Message)" }
  }
}

function Remove-ClassicTeamsRunFromHive { param([string]$HiveRoot, [string]$Who)
  $runKey = "Registry::$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Run"
  if (Test-Path $runKey) {
    $props = Get-ItemProperty $runKey -ErrorAction SilentlyContinue
    foreach ($name in @('com.squirrel.Teams.Teams','Teams','Microsoft Teams','TeamsMachineInstaller')) {
      if ($null -ne ($props.PSObject.Properties[$name])) {
        Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
        Write-Log "Removed Run entry '$name' for $Who"
      }
    }
  }
}

function Uninstall-ClassicTeamsPerUser {
  $profiles = Get-ProfileList
  foreach ($prof in $profiles) {
    $p = $prof.Path
    Write-Log "Processing existing profile: $p"

    $updateExe = Join-Path $p 'AppData\Local\Microsoft\Teams\Update.exe'
    if (Test-Path $updateExe) {
      try {
        Write-Log "Running Classic Teams uninstall (Update.exe) for: $p"
        $proc = Start-Process $updateExe -ArgumentList '--uninstall -s' -Wait -PassThru
        Write-Log "Update.exe exit code: $($proc.ExitCode)"
      } catch { Write-Log "WARN: Update.exe uninstall failed: $($_.Exception.Message)" }
    }

    Remove-ClassicTeamsFoldersInProfile -ProfilePath $p

    # Remove autorun from the user's registry hive
    $ntUser = Join-Path $p 'NTUSER.DAT'
    if (Test-Path $ntUser) {
      $tempHive = "HKU\TempHive_$($prof.Sid.Replace('-','_'))"
      $loaded = $false
      try {
        if (-not (Test-Path "Registry::$tempHive")) { & reg.exe load $tempHive $ntUser | Out-Null; $loaded = $true }
        Remove-ClassicTeamsRunFromHive -HiveRoot $tempHive -Who $p
      } catch { Write-Log "WARN: Could not edit Run key for $p : $($_.Exception.Message)" }
      finally { if ($loaded) { & reg.exe unload $tempHive | Out-Null } }
    }
  }
}

function Clean-DefaultUserProfile {
  # IMPORTANT: Prevent classic Teams appearing on FIRST login for new users
  $defaultPath = "$env:SystemDrive\Users\Default"
  Write-Log "Cleaning Default user profile to prevent classic Teams on first login..."
  if (-not (Test-Path $defaultPath)) { Write-Log "WARN: Default profile not found at $defaultPath"; return }

  Remove-ClassicTeamsFoldersInProfile -ProfilePath $defaultPath

  $defaultHive = Join-Path $defaultPath 'NTUSER.DAT'
  if (Test-Path $defaultHive) {
    $hiveName = "HKU\DefaultUserHive_TeamsFix"
    $loaded = $false
    try {
      if (-not (Test-Path "Registry::$hiveName")) { & reg.exe load $hiveName $defaultHive | Out-Null; $loaded = $true }
      Remove-ClassicTeamsRunFromHive -HiveRoot $hiveName -Who "Default User Profile"
    } catch { Write-Log "WARN: Could not edit Default user hive : $($_.Exception.Message)" }
    finally { if ($loaded) { & reg.exe unload $hiveName | Out-Null } }
  }
}

function Remove-TeamsInstallerFolder {
  # Classic Teams machine-wide artifacts
  $paths = @(
    "$env:ProgramFiles\Teams Installer",
    "${env:ProgramFiles(x86)}\Teams Installer",
    "$env:ProgramData\Teams",
    "$env:ProgramData\Microsoft\Teams"
  )
  foreach ($p in $paths) {
    try {
      if ($p -and (Test-Path $p)) {
        Remove-Item $p -Recurse -Force -ErrorAction Stop
        Write-Log "Removed folder: $p"
      }
    } catch { Write-Log "WARN: Could not remove $p : $($_.Exception.Message)" }
  }
}

function Remove-ConsumerTeamsIfPresent {
  # On some Windows builds, consumer "Microsoft Teams (free)" can appear for new users.
  # We remove ONLY packages named "MicrosoftTeams" (consumer) and keep the new work/school MSTeams package.
  Write-Log "Checking for consumer MicrosoftTeams AppX (optional cleanup)..."
  try {
    $prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'MicrosoftTeams' }
    foreach ($p in $prov) {
      Write-Log "Removing provisioned consumer package: $($p.DisplayName)"
      Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName | Out-Null
    }
  } catch { Write-Log "WARN: Provisioned consumer Teams check failed: $($_.Exception.Message)" }

  try {
    $pkgs = Get-AppxPackage -AllUsers | Where-Object { $_.Name -eq 'MicrosoftTeams' }
    foreach ($p in $pkgs) {
      Write-Log "Removing installed consumer package for all users: $($p.PackageFullName)"
      Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }
  } catch { Write-Log "WARN: Installed consumer Teams removal failed: $($_.Exception.Message)" }
}

function Test-WebView2Runtime {
  [bool](Get-UninstallEntries | Where-Object { $_.DisplayName -like '*Microsoft Edge WebView2 Runtime*' })
}

function Provision-NewTeamsAllUsers { param([string]$BootstrapperPath,[string]$MsixPath)
  Write-Log "Provisioning NEW Teams (work/school) for ALL users (offline)..."
  $proc = Start-Process $BootstrapperPath -ArgumentList "-p -o `"$MsixPath`"" -Wait -PassThru
  Write-Log "teamsbootstrapper exit code: $($proc.ExitCode)"
}

# ---- MAIN ----
Ensure-Folder $WorkDir
Start-Transcript -Path $LogPath -Append | Out-Null
try {
  Write-Log "=== Fix Teams started (v2) ==="
  Stop-TeamsProcesses

  # Remove classic Teams machine-wide installer & run entries that reinstall it
  Uninstall-MsiByDisplayNameLike '*Teams Machine-Wide Installer*'
  Remove-HKLMRunEntries
  Set-PreventInstallationFromMsi
  Remove-TeamsInstallerFolder

  # Remove classic Teams from existing profiles and from Default profile (NEW USERS)
  Uninstall-ClassicTeamsPerUser
  Clean-DefaultUserProfile

  # Optional: remove consumer Teams (free) that can show up on new logons
  Remove-ConsumerTeamsIfPresent

  # Copy offline installers to stable location and provision New Teams for all users
  if (-not (Test-Path $BootstrapperSrc)) { throw "teamsbootstrapper.exe not found next to script: $BootstrapperSrc" }
  if (-not (Test-Path $MsixSrc)) { throw "MSTeams-x64.msix not found next to script: $MsixSrc" }

  Copy-Item $BootstrapperSrc (Join-Path $WorkDir 'teamsbootstrapper.exe') -Force
  Copy-Item $MsixSrc         (Join-Path $WorkDir 'MSTeams-x64.msix') -Force

  if (-not (Test-WebView2Runtime)) {
    Write-Log "WARN: WebView2 Runtime not detected. If NEW Teams opens then closes, install WebView2 Runtime and rerun."
  }

  Provision-NewTeamsAllUsers -BootstrapperPath (Join-Path $WorkDir 'teamsbootstrapper.exe') -MsixPath (Join-Path $WorkDir 'MSTeams-x64.msix')
  Write-Log "=== DONE (v2) ==="
} catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  throw
} finally {
  Stop-Transcript | Out-Null
}
