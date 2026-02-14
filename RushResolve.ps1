<#
.SYNOPSIS
    Rush Resolve - Portable IT Technician Toolbox
.DESCRIPTION
    Modular PowerShell GUI application for IT technicians.
    Runs as standard user with on-demand credential elevation.
.NOTES
    Version: 2.0
    Author: Rush IT Field Services
    Requires: PowerShell 5.1+, Windows 10/11
#>

#region Assembly Loading
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# SECURITY: Enforce TLS 1.2+ for all HTTPS connections (prevents downgrade attacks)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

# QRCoder Library - bundled for QR code generation
# DLL is included in Lib folder - no runtime download needed
$script:QRCoderPath = Join-Path $PSScriptRoot "Lib\QRCoder.dll"
$script:QRCoderExpectedHash = "561ACFE4B1A14C837B189FB9FC5C6D3E82440184BBDE61912DE723D62D6368B3"
$script:QRGeneratorAvailable = $false

function Initialize-QRCoder {
    # Check if already loaded
    if ($script:QRGeneratorAvailable) { return $true }

    # Verify DLL exists
    if (-not (Test-Path $script:QRCoderPath)) {
        Write-Warning "QRCoder.dll not found at: $script:QRCoderPath"
        return $false
    }

    # Verify integrity (SHA256 hash)
    try {
        $actualHash = (Get-FileHash -Path $script:QRCoderPath -Algorithm SHA256).Hash
        if ($actualHash -ne $script:QRCoderExpectedHash) {
            Write-Warning "QRCoder.dll integrity check failed - hash mismatch"
            return $false
        }
    }
    catch {
        Write-Warning "Failed to verify QRCoder.dll integrity: $_"
        return $false
    }

    # Load the assembly
    try {
        Add-Type -Path $script:QRCoderPath -ErrorAction Stop
        $script:QRGeneratorAvailable = $true
        return $true
    }
    catch {
        Write-Warning "Failed to load QRCoder: $_"
        return $false
    }
}

# Generate QR code bitmap using QRCoder
function New-QRCodeBitmap {
    param(
        [string]$Text,
        [int]$PixelsPerModule = 20
    )

    if (-not (Initialize-QRCoder)) {
        throw "QRCoder library not available"
    }

    $qrGenerator = New-Object QRCoder.QRCodeGenerator
    $qrData = $qrGenerator.CreateQrCode($Text, [QRCoder.QRCodeGenerator+ECCLevel]::M)
    $qrCode = New-Object QRCoder.QRCode($qrData)
    $bitmap = $qrCode.GetGraphic($PixelsPerModule)

    # Cleanup
    $qrCode.Dispose()
    $qrData.Dispose()
    $qrGenerator.Dispose()

    return $bitmap
}

# Try to initialize QRCoder at startup (non-blocking)
try {
    Initialize-QRCoder | Out-Null
}
catch {
    # Will retry when QR code is actually needed
}
#endregion

#region Splash Screen
$script:SplashForm = $null
$script:SplashLabel = $null
$script:SplashProgress = $null

function Show-SplashScreen {
    $script:SplashForm = New-Object System.Windows.Forms.Form
    $script:SplashForm.Text = ""
    $script:SplashForm.Size = New-Object System.Drawing.Size(400, 200)
    $script:SplashForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $script:SplashForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $script:SplashForm.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $script:SplashForm.TopMost = $true

    # Rush Logo (top-left corner)
    $logoPath = Join-Path $script:AppPath "Assets/Rush-logo.png"
    if (Test-Path $logoPath) {
        try {
            $logoPictureBox = New-Object System.Windows.Forms.PictureBox
            $logoPictureBox.Image = [System.Drawing.Image]::FromFile($logoPath)
            $logoPictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
            $logoPictureBox.Size = New-Object System.Drawing.Size(60, 60)
            $logoPictureBox.Location = New-Object System.Drawing.Point(20, 20)
            $logoPictureBox.BackColor = [System.Drawing.Color]::Transparent
            $script:SplashForm.Controls.Add($logoPictureBox)
        }
        catch {
            # If logo fails to load, continue without it
            Write-Verbose "Failed to load Rush logo: $_"
        }
    }

    # App name (adjusted position to accommodate logo)
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Rush Resolve"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(100, 40)
    $script:SplashForm.Controls.Add($titleLabel)

    # Subtitle
    $subLabel = New-Object System.Windows.Forms.Label
    $subLabel.Text = "IT Technician Toolkit"
    $subLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $subLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    $subLabel.AutoSize = $true
    $subLabel.Location = New-Object System.Drawing.Point(130, 85)
    $script:SplashForm.Controls.Add($subLabel)

    # Status label
    $script:SplashLabel = New-Object System.Windows.Forms.Label
    $script:SplashLabel.Text = "Starting..."
    $script:SplashLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:SplashLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
    $script:SplashLabel.AutoSize = $true
    $script:SplashLabel.Location = New-Object System.Drawing.Point(20, 130)
    $script:SplashForm.Controls.Add($script:SplashLabel)

    # Progress bar
    $script:SplashProgress = New-Object System.Windows.Forms.ProgressBar
    $script:SplashProgress.Location = New-Object System.Drawing.Point(20, 155)
    $script:SplashProgress.Size = New-Object System.Drawing.Size(360, 20)
    $script:SplashProgress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $script:SplashProgress.MarqueeAnimationSpeed = 30
    $script:SplashForm.Controls.Add($script:SplashProgress)

    $script:SplashForm.Show()
    $script:SplashForm.Refresh()
}

function Update-SplashStatus {
    param([string]$Status)
    if ($script:SplashLabel) {
        $script:SplashLabel.Text = $Status
        $script:SplashForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Close-SplashScreen {
    if ($script:SplashForm) {
        $script:SplashForm.Close()
        $script:SplashForm.Dispose()
        $script:SplashForm = $null
    }
}
#endregion

#region Script Variables
$script:AppName = "Rush Resolve"
$script:AppVersion = "2.5.1"  # Bug fix: Software Installer module display
$script:AppPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ModulesPath = Join-Path $script:AppPath "Modules"
$script:ConfigPath = Join-Path $script:AppPath "Config"
$script:SecurityPath = Join-Path $script:AppPath "Security"
$script:SettingsFile = Join-Path $script:ConfigPath "settings.json"
$script:ModuleManifestFile = Join-Path $script:SecurityPath "module-manifest.json"
$script:IntegrityManifestFile = Join-Path $script:SecurityPath "integrity-manifest.json"
$script:SecurityMode = "Enforced"  # "Enforced", "Warn", or "Disabled"

# Credential caching with PIN protection
$script:CachedCredential = $null          # Encrypted credential blob (or decrypted PSCredential when unlocked)
$script:CacheCredentials = $false         # Whether caching is enabled
$script:CredentialPINHash = $null         # SHA256 hash of PIN
$script:PINLastVerified = $null           # DateTime of last successful PIN entry
$script:PINTimeout = 15                   # Minutes before PIN re-required
$script:PINFailCount = 0                  # Track failed PIN attempts
$script:CredentialFile = Join-Path $script:ConfigPath "credential.dat"
$script:PINFile = Join-Path $script:ConfigPath "credential.pin"
$script:ConnectedSharePath = $null       # UNC root of active net use session
$script:NetworkShareCredential = $null   # Session-cached PSCredential for share access (separate from elevation creds)

# Session logging
$script:LogsPath = Join-Path $script:AppPath "Logs"
$script:SessionLogFile = $null
#endregion

#region Session Logging

<#
.SYNOPSIS
    Collects essential system information for session log header.
.DESCRIPTION
    Gathers OS, CPU, RAM, and domain information to be logged at session start.
.OUTPUTS
    Hashtable with system information
#>
function Get-SessionStartInfo {
    try {
        $info = @{}

        # Get CIM instances
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

        # Computer info
        $info['ComputerName'] = $env:COMPUTERNAME

        # OS info
        if ($os) {
            $info['OS'] = $os.Caption
            $info['OSVersion'] = $os.Version
            $info['Build'] = $os.BuildNumber
            $info['Architecture'] = $os.OSArchitecture
        }

        # CPU info
        if ($cpu) {
            $info['CPU'] = $cpu.Name.Trim()
            $info['Cores'] = $cpu.NumberOfCores
            $info['Threads'] = $cpu.NumberOfLogicalProcessors
        }

        # RAM info
        if ($cs) {
            $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            $info['RAM'] = "$ramGB GB"

            # Domain info
            if ($cs.PartOfDomain) {
                $info['Domain'] = $cs.Domain
                $info['DomainJoined'] = $true
            } else {
                $info['Workgroup'] = $cs.Workgroup
                $info['DomainJoined'] = $false
            }
        }

        # Network adapters (basic count)
        $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        $info['ActiveAdapters'] = $adapters.Count

        return $info
    }
    catch {
        # Return minimal info if gathering fails
        return @{
            ComputerName = $env:COMPUTERNAME
            Error = $_.Exception.Message
        }
    }
}

function Initialize-SessionLog {
    <#
    .SYNOPSIS
        Creates a new session log file with header information.
    #>
    try {
        # Create Logs folder if it doesn't exist
        if (-not (Test-Path $script:LogsPath)) {
            New-Item -Path $script:LogsPath -ItemType Directory -Force | Out-Null
        }

        # Generate filename with computer name and timestamp
        # Format: SESSION-COMPUTERNAME-2026-02-09_143522.log
        $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
        $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'UNKNOWN' }
        $script:SessionLogFile = Join-Path $script:LogsPath "SESSION-$computerName-$timestamp.log"

        # Gather system information
        $sysInfo = Get-SessionStartInfo

        # Build header with system information
        $headerBuilder = [System.Text.StringBuilder]::new()
        [void]$headerBuilder.AppendLine("=" * 80)
        [void]$headerBuilder.AppendLine("RUSH RESOLVE SESSION LOG")
        [void]$headerBuilder.AppendLine("=" * 80)
        [void]$headerBuilder.AppendLine("Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        [void]$headerBuilder.AppendLine("User: $env:USERDOMAIN\$env:USERNAME")
        [void]$headerBuilder.AppendLine("Computer: $env:COMPUTERNAME")
        [void]$headerBuilder.AppendLine("Version: $($script:AppVersion)")
        [void]$headerBuilder.AppendLine("")

        [void]$headerBuilder.AppendLine("SYSTEM INFORMATION:")
        [void]$headerBuilder.AppendLine("-" * 80)

        if ($sysInfo.ContainsKey('Error')) {
            [void]$headerBuilder.AppendLine("Error gathering system info: $($sysInfo.Error)")
        } else {
            if ($sysInfo.OS) {
                [void]$headerBuilder.AppendLine("OS: $($sysInfo.OS)")
                [void]$headerBuilder.AppendLine("Version: $($sysInfo.OSVersion)")
                [void]$headerBuilder.AppendLine("Build: $($sysInfo.Build)")
                [void]$headerBuilder.AppendLine("Architecture: $($sysInfo.Architecture)")
            }

            if ($sysInfo.CPU) {
                [void]$headerBuilder.AppendLine("CPU: $($sysInfo.CPU)")
                [void]$headerBuilder.AppendLine("Cores: $($sysInfo.Cores) cores, $($sysInfo.Threads) threads")
            }

            if ($sysInfo.RAM) {
                [void]$headerBuilder.AppendLine("RAM: $($sysInfo.RAM)")
            }

            if ($sysInfo.DomainJoined) {
                [void]$headerBuilder.AppendLine("Domain: $($sysInfo.Domain)")
            } elseif ($sysInfo.Workgroup) {
                [void]$headerBuilder.AppendLine("Workgroup: $($sysInfo.Workgroup)")
            }

            if ($sysInfo.ActiveAdapters) {
                [void]$headerBuilder.AppendLine("Active Network Adapters: $($sysInfo.ActiveAdapters)")
            }
        }

        [void]$headerBuilder.AppendLine("=" * 80)
        [void]$headerBuilder.AppendLine("")

        Set-Content -Path $script:SessionLogFile -Value $headerBuilder.ToString() -Force
        Write-SessionLog "Application started"
    }
    catch {
        # Logging failure shouldn't crash the app
        $script:SessionLogFile = $null
    }
}

function Write-SessionLog {
    <#
    .SYNOPSIS
        Writes a timestamped entry to the session log.
    .PARAMETER Message
        The message to log (operation name or description).
    .PARAMETER Category
        Optional category prefix (e.g., "Credentials", "Disk Cleanup").
    .PARAMETER Result
        Optional result of the operation (e.g., "Success", "Failed: reason", "Freed 2.5 GB").
        When provided, appended as " - Result" to the message.
    .EXAMPLE
        Write-SessionLog -Message "Domain join" -Category "DomainTools" -Result "Success"
        Output: [10:30:45] [DomainTools] Domain join - Success
    .EXAMPLE
        Write-SessionLog -Message "Temp files removed" -Category "DiskCleanup" -Result "Freed 2.5 GB"
        Output: [10:30:45] [DiskCleanup] Temp files removed - Freed 2.5 GB
    #>
    param(
        [string]$Message,
        [string]$Category = "",
        [string]$Result = ""
    )

    if (-not $script:SessionLogFile) { return }

    try {
        $timestamp = Get-Date -Format "HH:mm:ss"

        # Build log entry with optional result
        $fullMessage = if ($Result) {
            "$Message - $Result"
        } else {
            $Message
        }

        $logEntry = if ($Category) {
            "[$timestamp] [$Category] $fullMessage"
        } else {
            "[$timestamp] $fullMessage"
        }

        Add-Content -Path $script:SessionLogFile -Value $logEntry
    }
    catch {
        # Silently fail - logging shouldn't crash the app
    }
}

function Close-SessionLog {
    <#
    .SYNOPSIS
        Writes closing entry to the session log.
    #>
    if (-not $script:SessionLogFile) { return }

    try {
        Write-SessionLog "Application closed"
        $footer = @"

================================================================================
Session ended: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
================================================================================
"@
        Add-Content -Path $script:SessionLogFile -Value $footer
    }
    catch {
        # Silently fail
    }
}

function Open-SessionLogsFolder {
    <#
    .SYNOPSIS
        Opens the Logs folder in Windows Explorer.
    #>
    if (Test-Path $script:LogsPath) {
        Start-Process explorer.exe -ArgumentList $script:LogsPath
    }
    else {
        [System.Windows.Forms.MessageBox]::Show(
            "No logs folder found. Logs are created when you run operations.",
            "No Logs",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
}
#endregion

#region Settings Management
function Get-DefaultSettings {
    return @{
        global = @{
            cacheCredentials = $true
            defaultDomain = "RUSH"
            windowWidth = 900
            windowHeight = 700
            lastTab = "System Info"
        }
        modules = @{}
    }
}

function Load-Settings {
    $defaults = Get-DefaultSettings

    if (Test-Path $script:SettingsFile) {
        try {
            $content = Get-Content $script:SettingsFile -Raw
            $script:Settings = $content | ConvertFrom-Json

            # Merge missing global settings with defaults
            foreach ($key in $defaults.global.Keys) {
                if (-not $script:Settings.global.PSObject.Properties[$key]) {
                    $script:Settings.global | Add-Member -NotePropertyName $key -NotePropertyValue $defaults.global[$key]
                }
            }

            # Ensure modules object exists
            if (-not $script:Settings.modules) {
                $script:Settings | Add-Member -NotePropertyName "modules" -NotePropertyValue @{}
            }

            $script:CacheCredentials = $script:Settings.global.cacheCredentials
        }
        catch {
            Write-Warning "Failed to load settings, using defaults: $_"
            $script:Settings = $defaults
        }
    }
    else {
        $script:Settings = $defaults
        Save-Settings
    }
}

function Save-Settings {
    try {
        if (-not (Test-Path $script:ConfigPath)) {
            New-Item -Path $script:ConfigPath -ItemType Directory -Force | Out-Null
        }
        $script:Settings | ConvertTo-Json -Depth 5 | Set-Content $script:SettingsFile -Force
    }
    catch {
        Write-Warning "Failed to save settings: $_"
    }
}

function Get-ModuleSetting {
    param(
        [string]$ModuleName,
        [string]$Key,
        $Default = $null
    )
    if ($script:Settings.modules.$ModuleName -and $script:Settings.modules.$ModuleName.$Key) {
        return $script:Settings.modules.$ModuleName.$Key
    }
    return $Default
}

function Set-ModuleSetting {
    param(
        [string]$ModuleName,
        [string]$Key,
        $Value
    )
    if (-not $script:Settings.modules.$ModuleName) {
        $script:Settings.modules | Add-Member -NotePropertyName $ModuleName -NotePropertyValue @{} -Force
    }
    $script:Settings.modules.$ModuleName | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    Save-Settings
}
#endregion

#region Security - Integrity Verification

function Get-FileHashSHA256 {
    <#
    .SYNOPSIS
        Computes SHA256 hash of a file.
    #>
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) { return $null }

    try {
        $stream = [System.IO.File]::OpenRead($FilePath)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($stream)
        $stream.Close()
        return [Convert]::ToBase64String($hashBytes)
    }
    catch {
        return $null
    }
}

function Test-ModuleAllowed {
    <#
    .SYNOPSIS
        Checks if a module file is in the whitelist and matches its expected hash.
    .OUTPUTS
        Hashtable with Allowed, Reason, and Hash.
    #>
    param([string]$ModulePath)

    $result = @{
        Allowed = $false
        Reason = ""
        Hash = $null
    }

    # If security is disabled, allow all
    if ($script:SecurityMode -eq "Disabled") {
        $result.Allowed = $true
        $result.Reason = "Security disabled"
        return $result
    }

    # Compute current file hash
    $currentHash = Get-FileHashSHA256 -FilePath $ModulePath
    $result.Hash = $currentHash

    if (-not $currentHash) {
        $result.Reason = "Could not compute hash"
        return $result
    }

    # Check if manifest exists
    if (-not (Test-Path $script:ModuleManifestFile)) {
        if ($script:SecurityMode -eq "Warn") {
            Write-Warning "Module manifest not found - running in warning mode"
            $result.Allowed = $true
            $result.Reason = "Manifest missing (warn mode)"
        }
        else {
            $result.Reason = "Module manifest not found"
        }
        return $result
    }

    # Load manifest
    try {
        $manifest = Get-Content $script:ModuleManifestFile -Raw | ConvertFrom-Json
    }
    catch {
        $result.Reason = "Failed to read module manifest"
        return $result
    }

    # Get module filename
    $fileName = Split-Path $ModulePath -Leaf

    # Check if module is in whitelist
    $entry = $manifest.modules | Where-Object { $_.name -eq $fileName }

    if (-not $entry) {
        $result.Reason = "Module '$fileName' not in whitelist"
        return $result
    }

    # Verify hash matches
    if ($currentHash -ne $entry.hash) {
        $result.Reason = "Hash mismatch for '$fileName' - file may have been tampered"
        return $result
    }

    # All checks passed
    $result.Allowed = $true
    $result.Reason = "Verified"
    return $result
}

function Test-ApplicationIntegrity {
    <#
    .SYNOPSIS
        Verifies integrity of all application files on startup.
    .OUTPUTS
        Hashtable with Passed, Failures (array), and Warnings (array).
    #>

    $result = @{
        Passed = $true
        Failures = @()
        Warnings = @()
    }

    # If security is disabled, skip
    if ($script:SecurityMode -eq "Disabled") {
        return $result
    }

    # Check if integrity manifest exists
    if (-not (Test-Path $script:IntegrityManifestFile)) {
        if ($script:SecurityMode -eq "Warn") {
            $result.Warnings += "Integrity manifest not found"
        }
        else {
            $result.Passed = $false
            $result.Failures += "Integrity manifest not found - run Update-SecurityManifests to create"
        }
        return $result
    }

    # Load manifest
    try {
        $manifest = Get-Content $script:IntegrityManifestFile -Raw | ConvertFrom-Json
    }
    catch {
        $result.Passed = $false
        $result.Failures += "Failed to read integrity manifest"
        return $result
    }

    # Verify settings.json integrity
    if ($manifest.settings_hash) {
        if (Test-Path $script:SettingsFile) {
            $settingsHash = Get-FileHashSHA256 -FilePath $script:SettingsFile
            # Note: Settings file hash will change when user modifies settings
            # We store it to detect unauthorized external modifications
            # In production, you might skip this check or use a different approach
        }
    }

    # Verify main script integrity
    $mainScript = Join-Path $script:AppPath "RushResolve.ps1"
    if ($manifest.main_script_hash) {
        $mainHash = Get-FileHashSHA256 -FilePath $mainScript
        if ($mainHash -ne $manifest.main_script_hash) {
            if ($script:SecurityMode -eq "Warn") {
                $result.Warnings += "Main script hash mismatch - file may have been modified"
            }
            else {
                $result.Passed = $false
                $result.Failures += "Main script integrity check failed - possible tampering"
            }
        }
    }

    return $result
}

function Update-SecurityManifests {
    <#
    .SYNOPSIS
        Generates/updates security manifests with current file hashes.
        Run this after making legitimate changes to modules or the main script.
    #>

    # Create Security folder if needed
    if (-not (Test-Path $script:SecurityPath)) {
        New-Item -Path $script:SecurityPath -ItemType Directory -Force | Out-Null
    }

    # Generate module manifest
    $moduleManifest = @{
        generated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        generated_by = "$env:USERDOMAIN\$env:USERNAME"
        description = "Whitelist of authorized modules with SHA256 hashes"
        modules = @()
    }

    $moduleFiles = Get-ChildItem -Path $script:ModulesPath -Filter "*.ps1" -ErrorAction SilentlyContinue
    foreach ($file in $moduleFiles) {
        $hash = Get-FileHashSHA256 -FilePath $file.FullName
        $moduleManifest.modules += @{
            name = $file.Name
            hash = $hash
            added = (Get-Date).ToString("yyyy-MM-dd")
        }
    }

    $moduleManifest | ConvertTo-Json -Depth 5 | Set-Content $script:ModuleManifestFile -Force

    # Generate integrity manifest
    $mainScript = Join-Path $script:AppPath "RushResolve.ps1"
    $mainHash = Get-FileHashSHA256 -FilePath $mainScript

    $integrityManifest = @{
        generated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        generated_by = "$env:USERDOMAIN\$env:USERNAME"
        description = "SHA256 hashes for application integrity verification"
        main_script_hash = $mainHash
        settings_hash = if (Test-Path $script:SettingsFile) { Get-FileHashSHA256 -FilePath $script:SettingsFile } else { $null }
    }

    $integrityManifest | ConvertTo-Json -Depth 5 | Set-Content $script:IntegrityManifestFile -Force

    return @{
        ModulesRegistered = $moduleManifest.modules.Count
        ManifestPath = $script:SecurityPath
    }
}

function Show-SecurityWarning {
    <#
    .SYNOPSIS
        Displays a security warning dialog to the user.
    #>
    param(
        [string]$Title,
        [string]$Message,
        [switch]$Critical
    )

    $icon = if ($Critical) {
        [System.Windows.Forms.MessageBoxIcon]::Error
    } else {
        [System.Windows.Forms.MessageBoxIcon]::Warning
    }

    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon
    )
}
#endregion

#region PIN-Protected Credential Cache

# Add required assembly for DPAPI
Add-Type -AssemblyName System.Security

function Get-PINHash {
    <#
    .SYNOPSIS
        Generates SHA256 hash of PIN for secure storage/comparison.
    #>
    param([string]$PIN)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PIN)
    $hash = $sha256.ComputeHash($bytes)
    return [Convert]::ToBase64String($hash)
}

function Protect-Credential {
    <#
    .SYNOPSIS
        Encrypts a PSCredential using AES-256 with PIN-derived key.
        Portable across computers.
    #>
    param(
        [PSCredential]$Credential,
        [string]$PIN
    )

    try {
        # SECURITY NOTE: Plaintext password must be extracted temporarily for encryption
        # This is a PowerShell limitation - minimize exposure window
        $username = $Credential.UserName
        $password = $Credential.GetNetworkCredential().Password
        $data = "$username|$password"
        $dataBytes = [System.Text.Encoding]::UTF8.GetBytes($data)

        # Clear plaintext password from memory immediately
        $password = $null
        $data = $null

        # 1. Generate random Salt (16 bytes) and IV (16 bytes)
        $salt = New-Object byte[] 16
        $iv = New-Object byte[] 16
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
        $rng.GetBytes($salt)
        $rng.GetBytes($iv)
        $rng.Dispose()

        # 2. Derive Key from PIN + Salt (PBKDF2)
        # 10000 iterations is a reasonable balance for this use case
        $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($PIN, $salt, 10000)
        $key = $deriveBytes.GetBytes(32) # AES-256 requires 32-byte key
        $deriveBytes.Dispose()

        # 3. Encrypt with AES
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

        $encryptor = $aes.CreateEncryptor()
        $encryptedBytes = $encryptor.TransformFinalBlock($dataBytes, 0, $dataBytes.Length)
        
        $aes.Dispose()
        $encryptor.Dispose()

        # 4. Pack result: Salt (16) + IV (16) + Ciphertext
        $result = New-Object byte[] ($salt.Length + $iv.Length + $encryptedBytes.Length)
        [Array]::Copy($salt, 0, $result, 0, $salt.Length)
        [Array]::Copy($iv, 0, $result, $salt.Length, $iv.Length)
        [Array]::Copy($encryptedBytes, 0, $result, ($salt.Length + $iv.Length), $encryptedBytes.Length)

        return $result
    }
    catch {
        Write-Warning "Failed to encrypt credential: $_"
        return $null
    }
}

function Unprotect-Credential {
    <#
    .SYNOPSIS
        Decrypts credential blob using AES-256 with PIN-derived key.
    #>
    param(
        [byte[]]$EncryptedData,
        [string]$PIN
    )

    try {
        if ($EncryptedData.Length -lt 32) { return $null } # Min length (Salt+IV)

        # 1. Extract Salt and IV
        $salt = New-Object byte[] 16
        $iv = New-Object byte[] 16
        [Array]::Copy($EncryptedData, 0, $salt, 0, 16)
        [Array]::Copy($EncryptedData, 16, $iv, 0, 16)

        # 2. Extract Ciphertext
        $cipherLen = $EncryptedData.Length - 32
        $cipherText = New-Object byte[] $cipherLen
        [Array]::Copy($EncryptedData, 32, $cipherText, 0, $cipherLen)

        # 3. Derive Key from PIN + Salt
        $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($PIN, $salt, 10000)
        $key = $deriveBytes.GetBytes(32)
        $deriveBytes.Dispose()

        # 4. Decrypt
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

        $decryptor = $aes.CreateDecryptor()
        try {
            $decryptedBytes = $decryptor.TransformFinalBlock($cipherText, 0, $cipherText.Length)
            $data = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
            
            $parts = $data -split '\|', 2
            if ($parts.Count -eq 2) {
                $securePassword = ConvertTo-SecureString $parts[1] -AsPlainText -Force
                return New-Object System.Management.Automation.PSCredential($parts[0], $securePassword)
            }
        }
        catch {
            # Decryption failed (wrong PIN or corrupted data)
            return $null
        }
        finally {
            $aes.Dispose()
            $decryptor.Dispose()
        }

        return $null
    }
    catch {
        return $null
    }
}

function Save-EncryptedCredential {
    <#
    .SYNOPSIS
        Saves encrypted credential and PIN hash to disk.
    #>
    param(
        [byte[]]$EncryptedData,
        [string]$PINHash
    )

    try {
        if (-not (Test-Path $script:ConfigPath)) {
            New-Item -Path $script:ConfigPath -ItemType Directory -Force | Out-Null
        }

        # Save encrypted credential
        [System.IO.File]::WriteAllBytes($script:CredentialFile, $EncryptedData)

        # Save PIN hash
        Set-Content -Path $script:PINFile -Value $PINHash -Force

        return $true
    }
    catch {
        Write-Warning "Failed to save credential: $_"
        return $false
    }
}

function Load-EncryptedCredential {
    <#
    .SYNOPSIS
        Loads encrypted credential and PIN hash from disk.
    .OUTPUTS
        Hashtable with EncryptedData and PINHash, or $null if not found.
    #>

    if ((Test-Path $script:CredentialFile) -and (Test-Path $script:PINFile)) {
        try {
            $encryptedData = [System.IO.File]::ReadAllBytes($script:CredentialFile)
            $pinHash = Get-Content -Path $script:PINFile -Raw
            return @{
                EncryptedData = $encryptedData
                PINHash = $pinHash.Trim()
            }
        }
        catch {
            Write-Warning "Failed to load credential: $_"
        }
    }
    return $null
}

function Remove-EncryptedCredential {
    <#
    .SYNOPSIS
        Removes saved credential files from disk.
    #>
    if (Test-Path $script:CredentialFile) { Remove-Item $script:CredentialFile -Force }
    if (Test-Path $script:PINFile) { Remove-Item $script:PINFile -Force }
    $script:CachedCredential = $null
    $script:CredentialPINHash = $null
    $script:PINLastVerified = $null
    $script:PINFailCount = 0
    Update-CredentialStatusIndicator
}

function Test-PINTimeout {
    <#
    .SYNOPSIS
        Checks if PIN needs to be re-entered (timeout expired).
    #>
    if (-not $script:PINLastVerified) { return $true }
    $elapsed = (Get-Date) - $script:PINLastVerified
    return $elapsed.TotalMinutes -ge $script:PINTimeout
}

function Show-PINEntryDialog {
    <#
    .SYNOPSIS
        Shows dialog to enter PIN. Returns PIN if valid, $null if cancelled.
    .PARAMETER IsNewPIN
        If true, shows "Set PIN" dialog with confirmation. If false, shows "Enter PIN" dialog.
    #>
    param(
        [bool]$IsNewPIN = $false,
        [string]$Title = ""
    )

    $dialogTitle = if ($IsNewPIN) { "Set PIN" } else { if ($Title) { $Title } else { "Enter PIN" } }
    $dialogHeight = if ($IsNewPIN) { 200 } else { 150 }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $dialogTitle
    $form.Size = New-Object System.Drawing.Size(350, $dialogHeight)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $yPos = 15

    $label = New-Object System.Windows.Forms.Label
    $labelText = if ($IsNewPIN) { "Create a 6+ digit PIN to protect your credentials:" } else { "Enter your PIN:" }
    $label.Text = $labelText
    $label.Location = New-Object System.Drawing.Point(15, $yPos)
    $label.AutoSize = $true
    $form.Controls.Add($label)
    $yPos += 25

    $pinBox = New-Object System.Windows.Forms.TextBox
    $pinBox.Location = New-Object System.Drawing.Point(15, $yPos)
    $pinBox.Width = 300
    $pinBox.UseSystemPasswordChar = $true
    $pinBox.MaxLength = 20
    $form.Controls.Add($pinBox)
    $yPos += 30

    $confirmBox = $null
    if ($IsNewPIN) {
        $confirmLabel = New-Object System.Windows.Forms.Label
        $confirmLabel.Text = "Confirm PIN:"
        $confirmLabel.Location = New-Object System.Drawing.Point(15, $yPos)
        $confirmLabel.AutoSize = $true
        $form.Controls.Add($confirmLabel)
        $yPos += 22

        $confirmBox = New-Object System.Windows.Forms.TextBox
        $confirmBox.Location = New-Object System.Drawing.Point(15, $yPos)
        $confirmBox.Width = 300
        $confirmBox.UseSystemPasswordChar = $true
        $confirmBox.MaxLength = 20
        $form.Controls.Add($confirmBox)
        $yPos += 35
    }
    else {
        $yPos += 15
    }

    $resultPIN = $null

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "OK"
    $okBtn.Location = New-Object System.Drawing.Point(150, $yPos)
    $okBtn.Width = 75
    $okBtn.Add_Click({
        $pin = $pinBox.Text

        # Validate PIN length
        if ($pin.Length -lt 6) {
            [System.Windows.Forms.MessageBox]::Show(
                "PIN must be at least 6 digits.",
                "Invalid PIN",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        # Validate digits only
        if ($pin -notmatch '^\d+$') {
            [System.Windows.Forms.MessageBox]::Show(
                "PIN must contain only digits.",
                "Invalid PIN",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        # If new PIN, check confirmation
        if ($IsNewPIN -and $confirmBox) {
            if ($pin -ne $confirmBox.Text) {
                [System.Windows.Forms.MessageBox]::Show(
                    "PINs do not match.",
                    "Mismatch",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                return
            }
        }

        $script:DialogResultPIN = $pin
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(235, $yPos)
    $cancelBtn.Width = 75
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelBtn)

    $form.AcceptButton = $okBtn
    $form.CancelButton = $cancelBtn

    $script:DialogResultPIN = $null

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $result = $script:DialogResultPIN
        $form.Dispose()
        return $result
    }

    $form.Dispose()
    return $null
}

function Update-CredentialStatusIndicator {
    <#
    .SYNOPSIS
        Updates the status bar credential indicator.
    #>
    if (-not $script:credStatusLabel) { return }

    $hasCredential = (Test-Path $script:CredentialFile) -or ($script:CachedCredential -is [PSCredential])

    if (-not $hasCredential) {
        $script:credStatusLabel.Text = "No Creds"
        $script:credStatusLabel.ForeColor = [System.Drawing.Color]::Gray
        $script:credStatusLabel.ToolTipText = "No credentials cached"
    }
    elseif (Test-PINTimeout) {
        # Locked (PIN timeout expired)
        $script:credStatusLabel.Text = "Locked"
        $script:credStatusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
        $script:credStatusLabel.ToolTipText = "Credentials cached - PIN required"
    }
    else {
        # Unlocked
        $script:credStatusLabel.Text = "Creds OK"
        $script:credStatusLabel.ForeColor = [System.Drawing.Color]::Green
        $script:credStatusLabel.ToolTipText = "Credentials cached - PIN verified"
    }
}

function Lock-CachedCredentials {
    <#
    .SYNOPSIS
        Forces PIN re-entry on next credential use.
    #>
    $script:PINLastVerified = $null
    Update-CredentialStatusIndicator
    Write-SessionLog -Message "Credentials locked manually" -Category "Credentials"
    [void][System.Windows.Forms.MessageBox]::Show(
        "Credentials locked. PIN required for next elevated operation.",
        "Locked",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

function Copy-PasswordToClipboard {
    <#
    .SYNOPSIS
        Copies the cached password to clipboard after PIN verification.
        Auto-clears clipboard after 30 seconds for security.
    .OUTPUTS
        $true if password was copied, $false otherwise.
    #>

    # Check if we have saved credentials
    $savedCred = Load-EncryptedCredential
    if (-not $savedCred) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "No credentials are saved. Use an elevated operation first to save credentials.",
            "No Credentials",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return $false
    }

    # Check if we have an unlocked credential in memory and PIN hasn't timed out
    if ($script:CachedCredential -is [PSCredential] -and -not (Test-PINTimeout)) {
        # Already unlocked - copy directly
        $password = $script:CachedCredential.GetNetworkCredential().Password
        [System.Windows.Forms.Clipboard]::SetText($password)
        Write-SessionLog -Message "Password copied to clipboard (already unlocked)" -Category "Credentials"

        [void][System.Windows.Forms.MessageBox]::Show(
            "Password copied to clipboard.`n`nClipboard will be cleared in 30 seconds for security.",
            "Password Copied",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        # Schedule clipboard clear after 30 seconds
        Start-ClipboardClearTimer
        return $true
    }

    # Need to prompt for PIN
    $attemptsLeft = 3 - $script:PINFailCount

    while ($attemptsLeft -gt 0) {
        $pin = Show-PINEntryDialog -Title "Enter PIN to copy password ($attemptsLeft attempts left)"
        if (-not $pin) {
            # User cancelled
            return $false
        }

        # Verify PIN hash
        $enteredHash = Get-PINHash -PIN $pin
        if ($enteredHash -eq $savedCred.PINHash) {
            # PIN correct - decrypt credential
            $decrypted = Unprotect-Credential -EncryptedData $savedCred.EncryptedData -PIN $pin
            if ($decrypted) {
                # Update cached state
                $script:CachedCredential = $decrypted
                $script:CredentialPINHash = $savedCred.PINHash
                $script:PINLastVerified = Get-Date
                $script:PINFailCount = 0
                Update-CredentialStatusIndicator

                # SECURITY NOTE: Plaintext password required for clipboard API
                # Minimize exposure window by clearing immediately after use
                $password = $decrypted.GetNetworkCredential().Password
                [System.Windows.Forms.Clipboard]::SetText($password)
                $password = $null  # Clear plaintext from memory
                Write-SessionLog -Message "Credentials unlocked with PIN, password copied to clipboard" -Category "Credentials"

                [void][System.Windows.Forms.MessageBox]::Show(
                    "Password copied to clipboard.`n`nClipboard will be cleared in 30 seconds for security.",
                    "Password Copied",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )

                # Schedule clipboard clear after 30 seconds
                Start-ClipboardClearTimer
                return $true
            }
            else {
                Write-SessionLog -Message "Failed to decrypt credentials - file may be corrupted" -Category "Credentials"
                [void][System.Windows.Forms.MessageBox]::Show(
                    "Failed to decrypt credentials. File may be corrupted.",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
                return $false
            }
        }
        else {
            # Wrong PIN
            $script:PINFailCount++
            $attemptsLeft = 3 - $script:PINFailCount

            # SECURITY: Add exponential backoff to prevent brute-force attacks
            $delaySeconds = 3 * $script:PINFailCount  # 3s, 6s, 9s
            if ($delaySeconds -gt 0) {
                Start-Sleep -Seconds $delaySeconds
            }

            if ($attemptsLeft -gt 0) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    "Incorrect PIN. $attemptsLeft attempts remaining.",
                    "Wrong PIN",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
            }
            else {
                [void][System.Windows.Forms.MessageBox]::Show(
                    "Maximum PIN attempts reached.",
                    "Locked Out",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                return $false
            }
        }
    }

    return $false
}

function Start-ClipboardClearTimer {
    <#
    .SYNOPSIS
        Starts a background job to clear clipboard after 30 seconds.
    #>
    # Use a simple approach with Start-Job for clipboard clearing
    # Note: This runs in background and clears clipboard after delay
    $null = Start-Job -ScriptBlock {
        Start-Sleep -Seconds 30
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Clipboard]::Clear()
    }
}

function Show-QRCodeAuthenticator {
    <#
    .SYNOPSIS
        Displays a QR code containing credentials for barcode scanner input.
    .DESCRIPTION
        Shows a popup with QR code encoding: username[TAB]password
        When scanned by a HID barcode scanner, it will type:
        1. Username
        2. Tab key (moves to password field)
        3. Password
        Window auto-closes after 60 seconds.
    #>

    # Check if QR generator is available
    if (-not $script:QRGeneratorAvailable) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "QR Code generator is not available on this system.",
            "Feature Unavailable",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    # Check if we have saved credentials
    $savedCred = Load-EncryptedCredential
    if (-not $savedCred) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "No credentials are saved. Use 'Set/Update Credentials' first.",
            "No Credentials",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }

    # Get decrypted credentials (either from cache or by prompting for PIN)
    $credential = $null

    # Check if we have an unlocked credential in memory and PIN hasn't timed out
    if ($script:CachedCredential -is [PSCredential] -and -not (Test-PINTimeout)) {
        $credential = $script:CachedCredential
    }
    else {
        # Need to prompt for PIN
        $attemptsLeft = 3 - $script:PINFailCount

        while ($attemptsLeft -gt 0 -and -not $credential) {
            $pin = Show-PINEntryDialog -Title "Enter PIN for QR Code ($attemptsLeft attempts left)"
            if (-not $pin) {
                return
            }

            # Verify PIN hash
            $enteredHash = Get-PINHash -PIN $pin
            if ($enteredHash -eq $savedCred.PINHash) {
                # PIN correct - decrypt credential
                $decrypted = Unprotect-Credential -EncryptedData $savedCred.EncryptedData -PIN $pin
                if ($decrypted) {
                    $script:CachedCredential = $decrypted
                    $script:CredentialPINHash = $savedCred.PINHash
                    $script:PINLastVerified = Get-Date
                    $script:PINFailCount = 0
                    Update-CredentialStatusIndicator
                    $credential = $decrypted
                }
                else {
                    [void][System.Windows.Forms.MessageBox]::Show(
                        "Failed to decrypt credentials. File may be corrupted.",
                        "Error",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    )
                    return
                }
            }
            else {
                $script:PINFailCount++
                $attemptsLeft = 3 - $script:PINFailCount

                # SECURITY: Add exponential backoff to prevent brute-force attacks
                $delaySeconds = 3 * $script:PINFailCount  # 3s, 6s, 9s
                if ($delaySeconds -gt 0) {
                    Start-Sleep -Seconds $delaySeconds
                }

                if ($attemptsLeft -gt 0) {
                    [void][System.Windows.Forms.MessageBox]::Show(
                        "Incorrect PIN. $attemptsLeft attempts remaining.",
                        "Wrong PIN",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                }
                else {
                    [void][System.Windows.Forms.MessageBox]::Show(
                        "Maximum PIN attempts reached.",
                        "Locked Out",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                    return
                }
            }
        }
    }

    if (-not $credential) { return }

    # Generate QR code string: password only
    $password = $credential.GetNetworkCredential().Password
    $qrString = $password

    Write-SessionLog -Message "QR Code Authenticator displayed" -Category "Credentials"

    # Generate QR code bitmap using QRCoder (20 pixels per module for scanner readability)
    try {
        $qrBitmap = New-QRCodeBitmap -Text $qrString -PixelsPerModule 20
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Failed to generate QR code: $($_.Exception.Message)",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return
    }

    # Get QR code dimensions to size form dynamically
    $qrWidth = $qrBitmap.Width
    $qrHeight = $qrBitmap.Height
    $formWidth = [Math]::Max(400, $qrWidth + 80)
    $formHeight = $qrHeight + 200

    # Create popup form
    $qrForm = New-Object System.Windows.Forms.Form
    $qrForm.Text = "QR Code Authenticator"
    $qrForm.Size = New-Object System.Drawing.Size($formWidth, $formHeight)
    $qrForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $qrForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $qrForm.MaximizeBox = $false
    $qrForm.MinimizeBox = $false
    $qrForm.TopMost = $true
    $qrForm.BackColor = [System.Drawing.Color]::White

    # Title label (centered)
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Scan with barcode scanner"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(([int](($formWidth - 220) / 2)), 15)
    $qrForm.Controls.Add($titleLabel)

    # QR code PictureBox (centered)
    $pictureBox = New-Object System.Windows.Forms.PictureBox
    $pictureBox.Image = $qrBitmap
    $pictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::AutoSize
    $pictureBox.Location = New-Object System.Drawing.Point(([int](($formWidth - $qrWidth) / 2)), 50)
    $qrForm.Controls.Add($pictureBox)

    # Info label (below QR code)
    $infoY = 50 + $qrHeight + 15
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "Contains: Password only`nEnter username first, then scan for password."
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $infoLabel.ForeColor = [System.Drawing.Color]::DarkGray
    $infoLabel.AutoSize = $true
    $infoLabel.Location = New-Object System.Drawing.Point(([int](($formWidth - 280) / 2)), $infoY)
    $qrForm.Controls.Add($infoLabel)

    # Instruction label
    $countdownLabel = New-Object System.Windows.Forms.Label
    $countdownLabel.Text = "Press OK or close when done"
    $countdownLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $countdownLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
    $countdownLabel.AutoSize = $true
    $countdownLabel.Location = New-Object System.Drawing.Point(([int](($formWidth - 180) / 2)), ($infoY + 45))
    $qrForm.Controls.Add($countdownLabel)

    # OK button (centered)
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Width = 100
    $okButton.Height = 30
    $okButton.Location = New-Object System.Drawing.Point(([int](($formWidth - 100) / 2)), ($infoY + 75))
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $qrForm.Controls.Add($okButton)
    $qrForm.AcceptButton = $okButton

    # Show form (waits for user to close)
    $qrForm.ShowDialog() | Out-Null

    # Cleanup
    $qrBitmap.Dispose()
    $qrForm.Dispose()
}
#endregion

#region Credential Elevation Helpers

# Check if currently running as administrator
function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Cache the elevation status at startup
$script:IsElevated = Test-IsElevated

function Get-ElevatedCredential {
    <#
    .SYNOPSIS
        Prompts for administrator credentials with PIN protection.
    .PARAMETER Message
        Custom message to display in the credential dialog.
    .PARAMETER Force
        Bypass cached credentials and always prompt.
    .OUTPUTS
        PSCredential object or $null if cancelled.
    #>
    param(
        [string]$Message = "Enter administrator credentials",
        [switch]$Force
    )

    # If caching disabled, just prompt directly
    if (-not $script:CacheCredentials) {
        try {
            $cred = Get-Credential -Message $Message
            if (-not $cred) { return $null }

            # Auto-prepend default domain if username doesn't include domain
            $username = $cred.UserName
            if ($username -notmatch '\\' -and $username -notmatch '@') {
                $defaultDomain = if ($script:Settings.global.defaultDomain) { $script:Settings.global.defaultDomain } else { "" }
                if ($defaultDomain) {
                    $newUsername = "$defaultDomain\$username"
                    $cred = New-Object System.Management.Automation.PSCredential($newUsername, $cred.Password)
                }
            }
            return $cred
        }
        catch {
            return $null
        }
    }

    # Check if we have an in-memory unlocked credential and PIN hasn't timed out
    if (-not $Force -and $script:CachedCredential -is [PSCredential] -and -not (Test-PINTimeout)) {
        return $script:CachedCredential
    }

    # Try to load from disk if not in memory
    $savedCred = Load-EncryptedCredential
    if ($savedCred) {
        # We have saved credentials - need PIN to unlock
        $attemptsLeft = 3 - $script:PINFailCount

        while ($attemptsLeft -gt 0) {
            $pin = Show-PINEntryDialog -Title "Unlock Credentials ($attemptsLeft attempts left)"
            if (-not $pin) {
                # User cancelled - offer to reset
                $reset = [System.Windows.Forms.MessageBox]::Show(
                    "Would you like to clear saved credentials and enter new ones?",
                    "Reset Credentials",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($reset -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Remove-EncryptedCredential
                    break
                }
                return $null
            }

            # Verify PIN hash
            $enteredHash = Get-PINHash -PIN $pin
            if ($enteredHash -eq $savedCred.PINHash) {
                # PIN correct - decrypt credential
                $decrypted = Unprotect-Credential -EncryptedData $savedCred.EncryptedData -PIN $pin
                if ($decrypted) {
                    $script:CachedCredential = $decrypted
                    $script:CredentialPINHash = $savedCred.PINHash
                    $script:PINLastVerified = Get-Date
                    $script:PINFailCount = 0
                    Update-CredentialStatusIndicator
                    Write-SessionLog -Message "Credentials unlocked with PIN for: $($decrypted.UserName)" -Category "Credentials"
                    return $decrypted
                }
                else {
                    [void][System.Windows.Forms.MessageBox]::Show(
                        "Failed to decrypt credentials. File may be corrupted.",
                        "Error",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    )
                    Remove-EncryptedCredential
                    break
                }
            }
            else {
                # Wrong PIN
                $script:PINFailCount++
                $attemptsLeft = 3 - $script:PINFailCount

                # SECURITY: Add exponential backoff to prevent brute-force attacks
                $delaySeconds = 3 * $script:PINFailCount  # 3s, 6s, 9s
                if ($delaySeconds -gt 0) {
                    Start-Sleep -Seconds $delaySeconds
                }

                if ($attemptsLeft -gt 0) {
                    [void][System.Windows.Forms.MessageBox]::Show(
                        "Incorrect PIN. $attemptsLeft attempts remaining.",
                        "Wrong PIN",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                }
                else {
                    # Max attempts reached
                    $reset = [System.Windows.Forms.MessageBox]::Show(
                        "Maximum PIN attempts reached. Clear saved credentials and start over?",
                        "Locked Out",
                        [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                    if ($reset -eq [System.Windows.Forms.DialogResult]::Yes) {
                        Remove-EncryptedCredential
                    }
                    else {
                        return $null
                    }
                }
            }
        }
    }

    # No saved credential (or was cleared) - prompt for new one
    try {
        $cred = Get-Credential -Message $Message
        if (-not $cred) { return $null }

        # Auto-prepend default domain if username doesn't include domain
        $username = $cred.UserName
        if ($username -notmatch '\\' -and $username -notmatch '@') {
            $defaultDomain = if ($script:Settings.global.defaultDomain) { $script:Settings.global.defaultDomain } else { "" }
            if ($defaultDomain) {
                $newUsername = "$defaultDomain\$username"
                $cred = New-Object System.Management.Automation.PSCredential($newUsername, $cred.Password)
            }
        }

        # Prompt for new PIN
        $pin = Show-PINEntryDialog -IsNewPIN $true
        if (-not $pin) {
            # User cancelled PIN setup - still return credential but don't cache
            return $cred
        }

        # Encrypt and save
        $encrypted = Protect-Credential -Credential $cred -PIN $pin
        if ($encrypted) {
            $pinHash = Get-PINHash -PIN $pin
            if (Save-EncryptedCredential -EncryptedData $encrypted -PINHash $pinHash) {
                $script:CachedCredential = $cred
                $script:CredentialPINHash = $pinHash
                $script:PINLastVerified = Get-Date
                $script:PINFailCount = 0

                Write-SessionLog -Message "New credentials saved for: $($cred.UserName)" -Category "Credentials"

                [void][System.Windows.Forms.MessageBox]::Show(
                    "Credentials saved and encrypted with your PIN.",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                Update-CredentialStatusIndicator
            }
        }

        return $cred
    }
    catch {
        return $null
    }
}

function Invoke-Elevated {
    <#
    .SYNOPSIS
        Runs a PowerShell script block with elevated credentials.
    .PARAMETER ScriptBlock
        The script block to execute.
    .PARAMETER Credential
        PSCredential to use. Will prompt if not provided.
    .PARAMETER ArgumentList
        Arguments to pass to the script block.
    .PARAMETER OperationName
        Friendly name for the operation (shown in credential prompt).
    .OUTPUTS
        Hashtable with Success, Error, Output, and ExitCode.
    #>
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$ScriptBlock,
        [PSCredential]$Credential,
        [object[]]$ArgumentList,
        [string]$OperationName = "this operation"
    )

    $result = @{
        Success = $false
        Error = $null
        Output = $null
        ExitCode = -1
    }

    # Get credentials if not provided
    if (-not $Credential) {
        $Credential = Get-ElevatedCredential -Message "Enter administrator credentials to $OperationName"
        if (-not $Credential) {
            $result.Error = "Operation cancelled by user"
            return $result
        }
    }

    $tempArgsFile = $null
    try {
        # Create temp folder if it doesn't exist
        $tempFolder = "C:\Temp\RushResolve_Install"
        if (-not (Test-Path $tempFolder)) {
            New-Item -Path $tempFolder -ItemType Directory -Force | Out-Null
        }
        $tempScript = Join-Path $tempFolder "RushResolve_$(Get-Random).ps1"

        # Serialize arguments to temp file (secure - no string injection possible)
        $tempArgsFile = Join-Path $tempFolder "RushResolve_Args_$(Get-Random).xml"
        if ($ArgumentList) {
            $ArgumentList | Export-Clixml -Path $tempArgsFile -Force
        }

        # Build the script content - arguments loaded from serialized file
        $scriptContent = @"
`$ErrorActionPreference = 'Stop'
try {
    # Import arguments from secure serialized file
    `$args = @()
    if (Test-Path '$tempArgsFile') {
        `$args = @(Import-Clixml -Path '$tempArgsFile')
    }

    # Define and execute the scriptblock with arguments
    `$sb = {
        $($ScriptBlock.ToString())
    }
    `$output = & `$sb @args
    `$output | ConvertTo-Json -Depth 10 | Write-Output
    exit 0
}
catch {
    Write-Error `$_.Exception.Message
    exit 1
}
"@
        Set-Content -Path $tempScript -Value $scriptContent -Force

        # Run the script with credentials
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "powershell.exe"
        $processInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.CreateNoWindow = $true
        $processInfo.UserName = $Credential.UserName
        $processInfo.Password = $Credential.Password
        $processInfo.Domain = if ($Credential.UserName -match '\\') {
            ($Credential.UserName -split '\\')[0]
        } elseif ($Credential.UserName -match '@') {
            ($Credential.UserName -split '@')[1]
        } else {
            $env:USERDOMAIN
        }

        # Adjust username if domain was extracted
        if ($Credential.UserName -match '\\') {
            $processInfo.UserName = ($Credential.UserName -split '\\')[1]
        }
        elseif ($Credential.UserName -match '@') {
            $processInfo.UserName = ($Credential.UserName -split '@')[0]
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $process.Start() | Out-Null

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $result.ExitCode = $process.ExitCode

        if ($process.ExitCode -eq 0) {
            $result.Success = $true
            if ($stdout) {
                try {
                    $result.Output = $stdout | ConvertFrom-Json
                }
                catch {
                    $result.Output = $stdout
                }
            }
        }
        else {
            $result.Error = if ($stderr) { $stderr.Trim() } else { "Operation failed with exit code $($process.ExitCode)" }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        # Clean up temp files
        if ($tempScript -and (Test-Path $tempScript)) {
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        }
        if ($tempArgsFile -and (Test-Path $tempArgsFile)) {
            Remove-Item $tempArgsFile -Force -ErrorAction SilentlyContinue
        }
    }

    return $result
}

function Start-ElevatedProcess {
    <#
    .SYNOPSIS
        Runs an executable with elevated credentials.
    .PARAMETER FilePath
        Path to the executable.
    .PARAMETER ArgumentList
        Arguments to pass to the executable.
    .PARAMETER Credential
        PSCredential to use. Will prompt if not provided.
    .PARAMETER Wait
        Wait for process to complete.
    .PARAMETER Hidden
        Run process hidden (no window).
    .PARAMETER OperationName
        Friendly name for the operation (shown in credential prompt).
    .OUTPUTS
        Hashtable with Success, Error, and ExitCode.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string]$ArgumentList = "",
        [PSCredential]$Credential,
        [switch]$Wait,
        [switch]$Hidden,
        [string]$OperationName = "this operation"
    )

    $result = @{
        Success = $false
        Error = $null
        ExitCode = -1
    }

    # If already running as admin, run directly
    if ($script:IsElevated) {
        try {
            $startParams = @{
                FilePath = $FilePath
                PassThru = $true
            }
            if ($ArgumentList) { $startParams.ArgumentList = $ArgumentList }
            if ($Hidden) { $startParams.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden }
            # Don't use -Wait switch, we'll wait manually with DoEvents
            # if ($Wait) { $startParams.Wait = $true }

            $process = Start-Process @startParams
            if ($Wait -and $process) {
                # Wait for process with UI responsiveness
                while (-not $process.HasExited) {
                    Start-Sleep -Milliseconds 100
                    [System.Windows.Forms.Application]::DoEvents()
                }
                $result.ExitCode = $process.ExitCode
                $result.Success = ($process.ExitCode -eq 0)
                if (-not $result.Success) { $result.Error = "Process exited with code $($process.ExitCode)" }
            }
            else {
                $result.Success = $true
                $result.ExitCode = 0
            }
        }
        catch {
            $result.Error = $_.Exception.Message
        }
        return $result
    }

    # Get credentials if not provided
    if (-not $Credential) {
        $Credential = Get-ElevatedCredential -Message "Enter administrator credentials to $OperationName"
        if (-not $Credential) {
            $result.Error = "Operation cancelled by user"
            return $result
        }
    }

    # Method 1: Try Start-Process -Credential (works in many environments)
    try {
        # Set working directory to the file's folder (alternate credentials may not access current dir)
        $workDir = Split-Path $FilePath -Parent
        if (-not $workDir -or -not (Test-Path $workDir)) {
            $workDir = "C:\Windows\System32"
        }

        $startParams = @{
            FilePath = $FilePath
            Credential = $Credential
            WorkingDirectory = $workDir
            PassThru = $true
            ErrorAction = 'Stop'
        }
        if ($ArgumentList) { $startParams.ArgumentList = $ArgumentList }
        if ($Hidden) { $startParams.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden }
        # Don't use -Wait switch, we'll wait manually with DoEvents
        # if ($Wait) { $startParams.Wait = $true }

        $process = Start-Process @startParams

        if ($Wait -and $process) {
            # Wait for process with UI responsiveness
            while (-not $process.HasExited) {
                Start-Sleep -Milliseconds 100
                [System.Windows.Forms.Application]::DoEvents()
            }
            $result.ExitCode = $process.ExitCode
            $result.Success = ($process.ExitCode -eq 0)
            if (-not $result.Success) { $result.Error = "Process exited with code $($process.ExitCode)" }
        }
        else {
            $result.Success = $true
            $result.ExitCode = 0
        }
        return $result
    }
    catch {
        # Method 1 failed, try Method 2
    }

    # Method 2: Use PowerShell job with credentials (better special char handling)
    try {
        $scriptBlock = {
            param($FilePath, $ArgumentList, $Hidden, $Wait, $WorkDir)
            # Change to a directory the user can access
            Set-Location $WorkDir
            $startParams = @{ FilePath = $FilePath; PassThru = $true; WorkingDirectory = $WorkDir }
            if ($ArgumentList) { $startParams.ArgumentList = $ArgumentList }
            if ($Hidden) { $startParams.WindowStyle = 'Hidden' }
            if ($Wait) { $startParams.Wait = $true }
            $proc = Start-Process @startParams
            if ($Wait -and $proc) { return $proc.ExitCode }
            return 0
        }

        # Determine safe working directory
        $workDir = Split-Path $FilePath -Parent
        if (-not $workDir -or $workDir -like "\\*") {
            $workDir = "C:\Windows\System32"
        }

        $job = Start-Job -ScriptBlock $scriptBlock -Credential $Credential -ArgumentList $FilePath, $ArgumentList, $Hidden, $Wait, $workDir

        # Poll with DoEvents to keep UI responsive (replaces blocking Wait-Job)
        $jobStart = Get-Date
        while ($job.State -eq 'Running') {
            Start-Sleep -Milliseconds 100
            [System.Windows.Forms.Application]::DoEvents()
            if (((Get-Date) - $jobStart).TotalMinutes -gt 5) {
                Stop-Job $job -ErrorAction SilentlyContinue
                Remove-Job $job -Force -ErrorAction SilentlyContinue
                throw "Elevated process timed out after 5 minutes"
            }
        }
        $jobResult = Receive-Job $job
        Remove-Job $job -Force

        if ($null -eq $jobResult) { $jobResult = 0 }
        $result.ExitCode = $jobResult
        $result.Success = ($jobResult -eq 0)
        if (-not $result.Success) { $result.Error = "Process exited with code $jobResult" }
        return $result
    }
    catch {
        $result.Error = "Elevation failed: $($_.Exception.Message). Try running the toolkit as administrator."
    }

    return $result
}

function Resolve-ToUNCPath {
    <#
    .SYNOPSIS
        Converts a mapped drive letter to its UNC path.
    .PARAMETER Path
        The path to resolve (e.g., "K:\FLDTECH\..." or "\\server\share\...")
    .OUTPUTS
        Returns the UNC path if the drive is a network drive, or $null if it's not.
    #>
    param([string]$Path)

    # Already UNC? Return as-is
    if ($Path -match '^\\\\') { return $Path }

    # Extract drive letter
    if ($Path -notmatch '^([A-Z]):') { return $null }
    $driveLetter = $matches[1] + ':'

    try {
        $drive = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$driveLetter'" -ErrorAction Stop
        if ($drive.DriveType -eq 4) {  # Network drive
            # Replace drive letter with UNC path
            $uncPath = $Path -replace "^$([regex]::Escape($driveLetter))", $drive.ProviderName
            return $uncPath
        }
    }
    catch {
        Write-SessionLog -Message "Failed to resolve drive $driveLetter to UNC: $($_.Exception.Message)" -Category "NetworkShare" -Level "Warning"
    }

    return $null
}

function Connect-NetworkShare {
    <#
    .SYNOPSIS
        Establishes an authenticated SMB session to a network share using net use.
    .PARAMETER SharePath
        Full UNC path to connect to (e.g., "\\server\share\folder\file.exe")
    .PARAMETER Credential
        Optional PSCredential to use. If not provided, will try cached session creds or prompt.
    .OUTPUTS
        Hashtable with Success (bool), Error (string), ShareRoot (string)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SharePath,
        [PSCredential]$Credential = $null
    )

    $result = @{
        Success = $false
        Error = $null
        ShareRoot = $null
    }

    # Extract share root (\\server\share)
    if ($SharePath -notmatch '^(\\\\[^\\]+\\[^\\]+)') {
        $result.Error = "Invalid UNC path: $SharePath"
        return $result
    }
    $shareRoot = $matches[1]
    $result.ShareRoot = $shareRoot

    # Quick check: already accessible?
    if (Test-Path $shareRoot -ErrorAction SilentlyContinue) {
        Write-SessionLog -Message "Share $shareRoot is already accessible (no auth needed)" -Category "NetworkShare"
        $result.Success = $true
        $script:ConnectedSharePath = $shareRoot
        return $result
    }

    # Disconnect any stale session to this share
    $existingSession = net use | Select-String -Pattern "^OK\s+$([regex]::Escape($shareRoot))"
    if ($existingSession) {
        Write-SessionLog -Message "Disconnecting existing session to $shareRoot" -Category "NetworkShare"
        net use $shareRoot /delete /yes 2>&1 | Out-Null
    }

    # Credential cascade
    $credToUse = $null
    $isRetry = $false

    if ($Credential) {
        $credToUse = $Credential
    }
    elseif ($script:NetworkShareCredential) {
        $credToUse = $script:NetworkShareCredential
        $isRetry = $true  # Mark as retry in case it fails
        Write-SessionLog -Message "Using cached network share credentials for $shareRoot" -Category "NetworkShare"
    }
    else {
        # Prompt for new credentials
        $credToUse = Get-Credential -Message "Enter credentials to access $shareRoot"
        if (-not $credToUse) {
            $result.Error = "Authentication cancelled by user"
            return $result
        }
    }

    # Extract username and password
    $username = $credToUse.UserName
    $password = $credToUse.GetNetworkCredential().Password

    # Auto-prepend domain if username lacks \ or @
    if ($username -notmatch '\\|@') {
        $username = "RUSH\$username"
        Write-SessionLog -Message "Prepending default domain: $username" -Category "NetworkShare"
    }

    # Attempt connection
    try {
        Write-SessionLog -Message "Connecting to $shareRoot as $username..." -Category "NetworkShare"
        $output = net use $shareRoot /user:$username $password 2>&1
        $password = $null  # Clear immediately

        if ($LASTEXITCODE -eq 0) {
            Write-SessionLog -Message "Successfully connected to $shareRoot" -Category "NetworkShare"
            $result.Success = $true
            $script:ConnectedSharePath = $shareRoot
            $script:NetworkShareCredential = $credToUse
            return $result
        }
        else {
            $result.Error = "net use failed: $($output -join ' ')"
        }
    }
    catch {
        $password = $null  # Clear on error too
        $result.Error = "Connection failed: $($_.Exception.Message)"
    }

    # If we used cached creds and they failed, clear cache and retry once with fresh prompt
    if ($isRetry -and -not $result.Success) {
        Write-SessionLog -Message "Cached credentials failed, clearing cache and re-prompting" -Category "NetworkShare" -Level "Warning"
        $script:NetworkShareCredential = $null

        $newCred = Get-Credential -Message "Previous credentials failed. Enter credentials to access $shareRoot"
        if ($newCred) {
            return Connect-NetworkShare -SharePath $SharePath -Credential $newCred
        }
        else {
            $result.Error = "Authentication cancelled after failed retry"
        }
    }

    if (-not $result.Success) {
        Write-SessionLog -Message "Failed to connect to $shareRoot : $($result.Error)" -Category "NetworkShare" -Level "Error"
    }

    return $result
}

function Disconnect-NetworkShare {
    <#
    .SYNOPSIS
        Disconnects the active network share session.
    #>
    if ($script:ConnectedSharePath) {
        Write-SessionLog -Message "Disconnecting from $script:ConnectedSharePath" -Category "NetworkShare"
        net use $script:ConnectedSharePath /delete /yes 2>&1 | Out-Null
        $script:ConnectedSharePath = $null
    }
}

function Clear-CachedCredentials {
    # Clear in-memory credential
    $script:CachedCredential = $null
    $script:CredentialPINHash = $null
    $script:PINLastVerified = $null
    $script:PINFailCount = 0

    # Clear network share credentials and disconnect
    $script:NetworkShareCredential = $null
    Disconnect-NetworkShare

    # Delete encrypted files from disk
    Remove-EncryptedCredential

    Write-SessionLog -Message "Cached credentials cleared from memory and disk" -Category "Credentials"

    [System.Windows.Forms.MessageBox]::Show(
        "Cached credentials have been cleared from memory and disk.",
        "Credentials Cleared",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

function Set-ManualCredentials {
    <#
    .SYNOPSIS
        Manually set or update admin credentials without running an elevated operation.
    .DESCRIPTION
        Prompts for username, password, and PIN, then saves encrypted credentials.
    #>

    # Check if credentials already exist - require PIN to replace them
    $existingCred = Load-EncryptedCredential
    if ($existingCred) {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Credentials already exist. Do you want to replace them with new credentials?`n`nYou will need to enter your current PIN first.",
            "Replace Credentials",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }

        # Verify current PIN before allowing replacement
        $pin = Show-PINEntryDialog -Title "Enter current PIN to update credentials"
        if (-not $pin) { return }

        $enteredHash = Get-PINHash -PIN $pin
        if ($enteredHash -ne $existingCred.PINHash) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Incorrect PIN. Credentials not updated.",
                "Wrong PIN",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }
    }

    # Prompt for new credentials
    try {
        $cred = Get-Credential -Message "Enter administrator credentials to save"
        if (-not $cred) { return }

        # Auto-prepend default domain if username doesn't include domain
        $username = $cred.UserName
        if ($username -notmatch '\\' -and $username -notmatch '@') {
            $defaultDomain = if ($script:Settings.global.defaultDomain) { $script:Settings.global.defaultDomain } else { "" }
            if ($defaultDomain) {
                $newUsername = "$defaultDomain\$username"
                $cred = New-Object System.Management.Automation.PSCredential($newUsername, $cred.Password)
            }
        }

        # Prompt for new PIN
        $newPin = Show-PINEntryDialog -IsNewPIN $true
        if (-not $newPin) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Credentials not saved - PIN is required.",
                "Cancelled",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        # Encrypt and save
        $encrypted = Protect-Credential -Credential $cred -PIN $newPin
        if ($encrypted) {
            $pinHash = Get-PINHash -PIN $newPin
            if (Save-EncryptedCredential -EncryptedData $encrypted -PINHash $pinHash) {
                $script:CachedCredential = $cred
                $script:CredentialPINHash = $pinHash
                $script:PINLastVerified = Get-Date
                $script:PINFailCount = 0

                Write-SessionLog -Message "Credentials manually updated for: $($cred.UserName)" -Category "Credentials"

                [void][System.Windows.Forms.MessageBox]::Show(
                    "Credentials saved and encrypted with your PIN.`n`nUsername: $($cred.UserName)",
                    "Credentials Saved",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                Update-CredentialStatusIndicator
            }
            else {
                [void][System.Windows.Forms.MessageBox]::Show(
                    "Failed to save credentials to disk.",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        }
        else {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Failed to encrypt credentials.",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }
    catch {
        # User cancelled credential dialog
    }
}
#endregion

#region Module Loading
function Get-Modules {
    <#
    .SYNOPSIS
        Discovers modules in the Modules folder.
    .OUTPUTS
        Array of module file paths, sorted by name.
    #>
    if (-not (Test-Path $script:ModulesPath)) {
        New-Item -Path $script:ModulesPath -ItemType Directory -Force | Out-Null
        return @()
    }

    return Get-ChildItem -Path $script:ModulesPath -Filter "*.ps1" | Sort-Object Name
}

function Load-Module {
    <#
    .SYNOPSIS
        Loads a single module and creates its tab.
    .PARAMETER ModuleFile
        FileInfo object for the module script.
    .PARAMETER TabControl
        The TabControl to add the module's tab to.
    #>
    param(
        [System.IO.FileInfo]$ModuleFile,
        [System.Windows.Forms.TabControl]$TabControl
    )

    try {
        # SECURITY: Verify module is whitelisted and hash matches
        $securityCheck = Test-ModuleAllowed -ModulePath $ModuleFile.FullName

        if (-not $securityCheck.Allowed) {
            $message = "Security: Blocked loading '$($ModuleFile.Name)'`n`nReason: $($securityCheck.Reason)`n`nIf this is a legitimate module, run Update-SecurityManifests to register it."

            if ($script:SecurityMode -eq "Enforced") {
                Show-SecurityWarning -Title "Module Blocked" -Message $message -Critical
                Write-Warning "SECURITY: Module '$($ModuleFile.Name)' blocked - $($securityCheck.Reason)"
                return $false
            }
            elseif ($script:SecurityMode -eq "Warn") {
                Show-SecurityWarning -Title "Security Warning" -Message "WARNING: $message`n`nLoading anyway (Warn mode)."
                Write-Warning "SECURITY WARNING: Module '$($ModuleFile.Name)' - $($securityCheck.Reason)"
            }
        }

        # Clear module variables
        $script:ModuleName = $null
        $script:ModuleDescription = $null

        # Dot-source the module (this sets $ModuleName, $ModuleDescription, and defines Initialize-Module)
        . $ModuleFile.FullName

        # Validate module has required components
        if (-not $script:ModuleName) {
            throw "Module does not define `$ModuleName"
        }

        # Create tab page
        $tab = New-Object System.Windows.Forms.TabPage
        $tab.Text = $script:ModuleName
        if ($script:ModuleDescription) {
            $tab.ToolTipText = $script:ModuleDescription
        }
        $tab.Padding = New-Object System.Windows.Forms.Padding(10)

        # Call module's initialization function
        if (Get-Command -Name "Initialize-Module" -ErrorAction SilentlyContinue) {
            Initialize-Module -tab $tab
        }
        else {
            throw "Module does not define Initialize-Module function"
        }

        # Add tab to control
        $TabControl.TabPages.Add($tab)

        Write-SessionLog "Loaded module: $($script:ModuleName)"
        return $true
    }
    catch {
        Write-SessionLog "Failed to load module: $($ModuleFile.Name) - $_"
        Write-Warning "Failed to load module '$($ModuleFile.Name)': $_"
        return $false
    }
}
#endregion

#region Auto-Update Functions
function Invoke-CheckForUpdates {
    <#
    .SYNOPSIS
        Entry point for update check. Queries GitHub and shows update dialog if newer version available.
    #>
    Write-SessionLog "Check for updates initiated by user" -Category "Update"

    # Show checking dialog
    $checkingForm = Show-ProgressDialog -StatusText "Checking for updates..."

    try {
        $release = Get-LatestGitHubRelease

        if ($checkingForm) {
            $checkingForm.Close()
            $checkingForm.Dispose()
        }

        if (-not $release) {
            [System.Windows.Forms.MessageBox]::Show(
                "Cannot reach GitHub. Please check your internet connection.",
                "Update Check Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        Write-SessionLog "GitHub API response: latest version is $($release.tag_name)" -Category "Update"

        $isNewer = Test-NewVersionAvailable -Current $script:AppVersion -GitHub $release.tag_name
        if (-not $isNewer) {
            [System.Windows.Forms.MessageBox]::Show(
                "You're running the latest version (v$($script:AppVersion))",
                "No Updates Available",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        Write-SessionLog "Update available: v$($script:AppVersion) → $($release.tag_name)" -Category "Update"

        # Show update dialog with release notes
        Show-UpdateDialog -Release $release
    }
    catch {
        if ($checkingForm) {
            $checkingForm.Close()
            $checkingForm.Dispose()
        }
        Write-SessionLog "Update check error: $_" -Category "Update"
        [System.Windows.Forms.MessageBox]::Show(
            "Error checking for updates: $_",
            "Update Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Get-LatestGitHubRelease {
    <#
    .SYNOPSIS
        Queries GitHub API for latest release information.
    .OUTPUTS
        Hashtable with release metadata, or $null if request fails.
    #>
    $apiUrl = "https://api.github.com/repos/SecPrime8/RushResolve/releases/latest"

    try {
        # GitHub API requires User-Agent header
        $headers = @{
            'User-Agent' = 'RushResolve-Updater'
        }

        $response = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers -UseBasicParsing -TimeoutSec 10

        # Extract ZIP asset (first asset assumed to be the release ZIP)
        $zipAsset = $response.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1

        if (-not $zipAsset) {
            Write-SessionLog "No ZIP asset found in release" -Category "Update"
            return $null
        }

        return @{
            tag_name = $response.tag_name
            name = $response.name
            body = $response.body
            download_url = $zipAsset.browser_download_url
            size = $zipAsset.size
            created_at = $response.created_at
        }
    }
    catch {
        Write-SessionLog "GitHub API error: $_" -Category "Update"
        return $null
    }
}

function Test-NewVersionAvailable {
    <#
    .SYNOPSIS
        Compares current version with GitHub version.
    .PARAMETER Current
        Current version string (e.g., "2.3").
    .PARAMETER GitHub
        GitHub release tag (e.g., "v2.4.0").
    .OUTPUTS
        $true if GitHub version is newer, $false otherwise.
    #>
    param(
        [string]$Current,
        [string]$GitHub
    )

    try {
        # Normalize versions: "2.3" → "2.3.0", "v2.4.0" → "2.4.0"
        $currentVer = [version]($Current + ".0")
        $githubVer = [version]($GitHub -replace "^v", "")

        return $githubVer -gt $currentVer
    }
    catch {
        Write-SessionLog "Version comparison error: $_" -Category "Update"
        return $false
    }
}

function Download-UpdatePackage {
    <#
    .SYNOPSIS
        Downloads update ZIP from GitHub to temp folder.
    .PARAMETER Url
        Direct download URL from GitHub release.
    .OUTPUTS
        Full path to downloaded ZIP, or $null if download fails.
    #>
    param([string]$Url)

    try {
        # SECURITY: Validate HTTPS enforcement (prevent MITM attacks)
        if (-not $Url.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-SessionLog "SECURITY: Download URL does not use HTTPS: $Url" -Category "Update"
            return $null
        }

        # Create temp folder
        $tempPath = Join-Path $env:TEMP "RushResolveUpdate_$(Get-Date -Format 'yyyyMMddHHmmss')"
        New-Item -Path $tempPath -ItemType Directory -Force | Out-Null

        $zipPath = Join-Path $tempPath "update.zip"

        Write-SessionLog "Download started from: $Url" -Category "Update"

        # Download with progress (simple synchronous download for now)
        Invoke-WebRequest -Uri $Url -OutFile $zipPath -UseBasicParsing

        $fileSize = (Get-Item $zipPath).Length
        Write-SessionLog "Download completed: $([math]::Round($fileSize / 1MB, 2)) MB" -Category "Update"

        return $zipPath
    }
    catch {
        Write-SessionLog "Download failed: $_" -Category "Update"
        return $null
    }
}

function Verify-UpdatePackage {
    <#
    .SYNOPSIS
        Verifies SHA256 hash of downloaded ZIP against expected value.
    .PARAMETER ZipPath
        Path to downloaded ZIP file.
    .PARAMETER ExpectedHash
        Expected SHA256 hash in hexadecimal format (from GitHub).
    .OUTPUTS
        $true if hash matches, $false otherwise.
    #>
    param(
        [string]$ZipPath,
        [string]$ExpectedHash
    )

    try {
        $actualHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash

        if ($actualHash -ne $ExpectedHash) {
            Write-SessionLog "Hash mismatch: Expected $ExpectedHash, got $actualHash" -Category "Update"
            return $false
        }

        Write-SessionLog "Hash verification: PASSED" -Category "Update"
        return $true
    }
    catch {
        Write-SessionLog "Hash verification error: $_" -Category "Update"
        return $false
    }
}

function Backup-CurrentVersion {
    <#
    .SYNOPSIS
        Creates backup ZIP of current version before updating.
    .OUTPUTS
        Full path to backup ZIP, or $null if backup fails.
    #>
    try {
        $backupDir = Join-Path $script:AppPath "Safety\Backups"
        if (-not (Test-Path $backupDir)) {
            New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-ddTHHmmssZ"
        $backupName = "RushResolveApp_v$($script:AppVersion)_backup_$timestamp.zip"
        $backupPath = Join-Path $backupDir $backupName

        # Get files to backup (exclude Config, Logs, Safety)
        $itemsToBackup = @()

        # Main script
        if (Test-Path (Join-Path $script:AppPath "RushResolve.ps1")) {
            $itemsToBackup += Join-Path $script:AppPath "RushResolve.ps1"
        }

        # Folders to backup
        $foldersToBackup = @("Modules", "Lib", "Security")
        foreach ($folder in $foldersToBackup) {
            $folderPath = Join-Path $script:AppPath $folder
            if (Test-Path $folderPath) {
                $itemsToBackup += $folderPath
            }
        }

        if ($itemsToBackup.Count -eq 0) {
            Write-SessionLog "No files to backup" -Category "Update"
            return $null
        }

        # Create backup ZIP
        Compress-Archive -Path $itemsToBackup -DestinationPath $backupPath -Force

        Write-SessionLog "Backup created: $backupName ($([math]::Round((Get-Item $backupPath).Length / 1MB, 2)) MB)" -Category "Update"

        # Cleanup: Keep only last 3 backups
        Get-ChildItem $backupDir -Filter "RushResolveApp_*.zip" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 3 |
            ForEach-Object {
                Write-SessionLog "Removing old backup: $($_.Name)" -Category "Update"
                Remove-Item $_.FullName -Force
            }

        return $backupPath
    }
    catch {
        Write-SessionLog "Backup failed: $_" -Category "Update"
        return $null
    }
}

function Install-Update {
    <#
    .SYNOPSIS
        Extracts update ZIP and replaces current files (preserves user settings).
    .PARAMETER ZipPath
        Path to verified update ZIP.
    .OUTPUTS
        $true if installation succeeds, $false otherwise.
    #>
    param([string]$ZipPath)

    try {
        # 1. Preserve user settings
        $settingsBackup = Join-Path $env:TEMP "settings_backup_$(Get-Date -Format 'HHmmss').json"
        if (Test-Path $script:SettingsFile) {
            Copy-Item $script:SettingsFile $settingsBackup -Force
            Write-SessionLog "User settings backed up" -Category "Update"
        }

        # 2. Extract to temp folder first (verify before replacing live files)
        $tempExtract = Join-Path $env:TEMP "RushResolveExtract_$(Get-Date -Format 'HHmmss')"
        Expand-Archive -Path $ZipPath -DestinationPath $tempExtract -Force

        Write-SessionLog "Update extracted to temp folder" -Category "Update"

        # 3. Verify integrity of extracted files
        if (-not (Test-UpdateIntegrity -ExtractPath $tempExtract)) {
            Write-SessionLog "Integrity check failed, aborting install" -Category "Update"
            return $false
        }

        # 4. Copy extracted files to live location
        # Identify the root folder in the ZIP (might be "RushResolveApp" or similar)
        $extractedItems = Get-ChildItem $tempExtract
        $sourceRoot = $tempExtract

        # If ZIP contains a single folder, use that as source
        if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer) {
            $sourceRoot = $extractedItems[0].FullName
        }

        # Copy files (will overwrite existing)
        Copy-Item "$sourceRoot\*" -Destination $script:AppPath -Recurse -Force

        Write-SessionLog "Files copied to application directory" -Category "Update"

        # 5. Restore user settings
        if (Test-Path $settingsBackup) {
            Copy-Item $settingsBackup $script:SettingsFile -Force
            Write-SessionLog "User settings restored" -Category "Update"
        }

        # 6. Regenerate security manifests
        Update-SecurityManifests
        Write-SessionLog "Security manifests regenerated" -Category "Update"

        # 7. Cleanup temp files
        if (Test-Path $tempExtract) {
            Remove-Item $tempExtract -Recurse -Force
        }
        if (Test-Path $settingsBackup) {
            Remove-Item $settingsBackup -Force
        }

        Write-SessionLog "Update installed successfully" -Category "Update"
        return $true
    }
    catch {
        Write-SessionLog "Installation failed: $_" -Category "Update"
        return $false
    }
}

function Test-UpdateIntegrity {
    <#
    .SYNOPSIS
        Verifies integrity of extracted update files before installation.
    .PARAMETER ExtractPath
        Path to extracted update folder.
    .OUTPUTS
        $true if integrity checks pass, $false otherwise.
    #>
    param([string]$ExtractPath)

    try {
        # Handle case where ZIP contains a root folder
        $extractedItems = Get-ChildItem $ExtractPath
        $checkRoot = $ExtractPath

        if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer) {
            $checkRoot = $extractedItems[0].FullName
        }

        # Check 1: Main script exists
        $mainScript = Join-Path $checkRoot "RushResolve.ps1"
        if (-not (Test-Path $mainScript)) {
            Write-SessionLog "Integrity check failed: Main script missing" -Category "Update"
            return $false
        }

        # Check 2: Modules folder exists with at least 8 modules
        $modulesPath = Join-Path $checkRoot "Modules"
        if (-not (Test-Path $modulesPath)) {
            Write-SessionLog "Integrity check failed: Modules folder missing" -Category "Update"
            return $false
        }

        $moduleFiles = Get-ChildItem $modulesPath -Filter "*.ps1"
        if ($moduleFiles.Count -lt 8) {
            Write-SessionLog "Integrity check failed: Expected 8+ modules, found $($moduleFiles.Count)" -Category "Update"
            return $false
        }

        # Check 3: Syntax check on main script
        try {
            $testScript = Get-Content $mainScript -Raw
            $scriptBlock = [scriptblock]::Create($testScript)
            Write-SessionLog "Syntax check: PASSED" -Category "Update"
        }
        catch {
            Write-SessionLog "Syntax check failed: $_" -Category "Update"
            return $false
        }

        return $true
    }
    catch {
        Write-SessionLog "Integrity check error: $_" -Category "Update"
        return $false
    }
}

function Restore-PreviousVersion {
    <#
    .SYNOPSIS
        Rolls back to previous version from backup ZIP.
    .PARAMETER BackupPath
        Path to backup ZIP file.
    #>
    param([string]$BackupPath)

    try {
        Write-SessionLog "Rollback initiated from: $BackupPath" -Category "Update"

        # Extract backup over current installation
        $tempRestore = Join-Path $env:TEMP "RushResolveRestore_$(Get-Date -Format 'HHmmss')"
        Expand-Archive -Path $BackupPath -DestinationPath $tempRestore -Force

        # Copy restored files back
        Copy-Item "$tempRestore\*" -Destination $script:AppPath -Recurse -Force

        # Regenerate manifests
        Update-SecurityManifests

        # Cleanup
        if (Test-Path $tempRestore) {
            Remove-Item $tempRestore -Recurse -Force
        }

        Write-SessionLog "Rollback complete" -Category "Update"

        [System.Windows.Forms.MessageBox]::Show(
            "Update failed and was rolled back to previous version.",
            "Update Rollback",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }
    catch {
        Write-SessionLog "Rollback failed: $_" -Category "Update"
        [System.Windows.Forms.MessageBox]::Show(
            "CRITICAL: Update and rollback both failed. Please reinstall manually.`n`nError: $_",
            "Critical Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Show-UpdateDialog {
    <#
    .SYNOPSIS
        Displays update available dialog with release notes.
    .PARAMETER Release
        Hashtable with release information from GitHub API.
    #>
    param($Release)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Update Available"
    $dialog.Size = New-Object System.Drawing.Size(520, 450)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    # Version info label
    $versionLabel = New-Object System.Windows.Forms.Label
    $versionLabel.Text = "Current Version: v$($script:AppVersion)`nLatest Version: $($Release.tag_name)"
    $versionLabel.Location = New-Object System.Drawing.Point(20, 20)
    $versionLabel.Size = New-Object System.Drawing.Size(460, 40)
    $versionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $dialog.Controls.Add($versionLabel)

    # Release notes label
    $notesLabel = New-Object System.Windows.Forms.Label
    $notesLabel.Text = "Release Notes:"
    $notesLabel.Location = New-Object System.Drawing.Point(20, 70)
    $notesLabel.AutoSize = $true
    $notesLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dialog.Controls.Add($notesLabel)

    # Release notes textbox
    $notesBox = New-Object System.Windows.Forms.TextBox
    $notesBox.Multiline = $true
    $notesBox.ScrollBars = "Vertical"
    $notesBox.Text = $Release.body
    $notesBox.Location = New-Object System.Drawing.Point(20, 95)
    $notesBox.Size = New-Object System.Drawing.Size(460, 260)
    $notesBox.ReadOnly = $true
    $notesBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $dialog.Controls.Add($notesBox)

    # Update Now button
    $updateBtn = New-Object System.Windows.Forms.Button
    $updateBtn.Text = "Update Now"
    $updateBtn.Location = New-Object System.Drawing.Point(250, 370)
    $updateBtn.Size = New-Object System.Drawing.Size(110, 30)
    $updateBtn.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $dialog.Controls.Add($updateBtn)

    # Later button
    $laterBtn = New-Object System.Windows.Forms.Button
    $laterBtn.Text = "Later"
    $laterBtn.Location = New-Object System.Drawing.Point(370, 370)
    $laterBtn.Size = New-Object System.Drawing.Size(110, 30)
    $laterBtn.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })
    $dialog.Controls.Add($laterBtn)

    $result = $dialog.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        Start-UpdateProcess -Release $Release
    }

    $dialog.Dispose()
}

function Start-UpdateProcess {
    <#
    .SYNOPSIS
        Orchestrates the full update process: download, verify, backup, install, restart.
    .PARAMETER Release
        Hashtable with release information.
    #>
    param($Release)

    $progressForm = $null

    try {
        # Step 1: Download
        $progressForm = Show-ProgressDialog -StatusText "Downloading update..."

        $zipPath = Download-UpdatePackage -Url $Release.download_url

        if (-not $zipPath -or -not (Test-Path $zipPath)) {
            if ($progressForm) { $progressForm.Close(); $progressForm.Dispose() }
            [System.Windows.Forms.MessageBox]::Show(
                "Download failed. Please check your internet connection and try again.",
                "Download Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            return
        }

        # Step 2: Verify hash (SECURITY: Critical integrity check)
        $expectedHash = $null
        if ($Release.body) {
            # Parse SHA256 from release notes (format: "SHA256: <hash>" or "Hash: <hash>")
            if ($Release.body -match '(?i)SHA256[:\s]+([A-F0-9]{64})') {
                $expectedHash = $matches[1]
            }
            elseif ($Release.body -match '(?i)Hash[:\s]+([A-F0-9]{64})') {
                $expectedHash = $matches[1]
            }
        }

        if ($expectedHash) {
            Write-SessionLog "Hash verification enabled: $expectedHash" -Category "Update"
            $hashValid = Verify-UpdatePackage -ZipPath $zipPath -ExpectedHash $expectedHash

            if (-not $hashValid) {
                if ($progressForm) { $progressForm.Close(); $progressForm.Dispose() }
                Write-SessionLog "SECURITY: Hash verification FAILED - aborting update" -Category "Update"
                [System.Windows.Forms.MessageBox]::Show(
                    "Download verification failed (hash mismatch).`n`nThis could indicate a corrupted or tampered update package.`n`nUpdate cancelled for security.",
                    "Security Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
                return
            }
        }
        else {
            Write-SessionLog "WARNING: No hash provided in release notes - proceeding without verification" -Category "Update"
        }

        # Step 3: Backup
        if ($progressForm) { $progressForm.Close(); $progressForm.Dispose() }
        $progressForm = Show-ProgressDialog -StatusText "Creating backup..."

        $backupPath = Backup-CurrentVersion

        if (-not $backupPath) {
            if ($progressForm) { $progressForm.Close(); $progressForm.Dispose() }
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to create backup. Update cancelled for safety.",
                "Backup Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            return
        }

        # Step 4: Install
        if ($progressForm) { $progressForm.Close(); $progressForm.Dispose() }
        $progressForm = Show-ProgressDialog -StatusText "Installing update..."

        $installSuccess = Install-Update -ZipPath $zipPath

        if ($progressForm) { $progressForm.Close(); $progressForm.Dispose() }

        if (-not $installSuccess) {
            # Rollback
            Restore-PreviousVersion -BackupPath $backupPath
            return
        }

        # Step 5: Success - Restart
        Write-SessionLog "Application restarting with new version ($($Release.tag_name))" -Category "Update"

        $restartDialog = [System.Windows.Forms.MessageBox]::Show(
            "Update installed successfully!`n`nThe application will now restart to apply changes.",
            "Update Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        # Restart application (SECURITY: Array-based args prevent command injection)
        $scriptPath = Join-Path $script:AppPath "RushResolve.ps1"
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-ExecutionPolicy", "Bypass", "-File", $scriptPath)

        # Close current instance
        $script:MainForm.Close()
    }
    catch {
        if ($progressForm) { $progressForm.Close(); $progressForm.Dispose() }
        Write-SessionLog "Update process error: $_" -Category "Update"
        [System.Windows.Forms.MessageBox]::Show(
            "Update failed: $_",
            "Update Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Show-ProgressDialog {
    <#
    .SYNOPSIS
        Creates a non-blocking progress dialog with marquee animation.
    .PARAMETER StatusText
        Status message to display.
    .OUTPUTS
        Form object (caller must close/dispose when done).
    #>
    param([string]$StatusText)

    $progressForm = New-Object System.Windows.Forms.Form
    $progressForm.Text = "Updating..."
    $progressForm.Size = New-Object System.Drawing.Size(400, 150)
    $progressForm.StartPosition = "CenterScreen"
    $progressForm.FormBorderStyle = "FixedDialog"
    $progressForm.ControlBox = $false
    $progressForm.MaximizeBox = $false
    $progressForm.MinimizeBox = $false

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = $StatusText
    $statusLabel.Location = New-Object System.Drawing.Point(20, 20)
    $statusLabel.Size = New-Object System.Drawing.Size(340, 30)
    $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $progressForm.Controls.Add($statusLabel)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(20, 60)
    $progressBar.Size = New-Object System.Drawing.Size(340, 30)
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.MarqueeAnimationSpeed = 30
    $progressForm.Controls.Add($progressBar)

    $progressForm.Show()
    $progressForm.Refresh()
    [System.Windows.Forms.Application]::DoEvents()

    return $progressForm
}
#endregion

#region UI Helper Functions
function New-OutputTextBox {
    <#
    .SYNOPSIS
        Creates a standard output textbox for module logging.
    .OUTPUTS
        TextBox control configured for log output.
    #>
    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $textBox.ReadOnly = $true
    $textBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $textBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $textBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $textBox.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $textBox.Height = 150
    return $textBox
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped message to a TextBox.
    .PARAMETER TextBox
        The TextBox to write to.
    .PARAMETER Message
        The message to write.
    #>
    param(
        [System.Windows.Forms.TextBox]$TextBox,
        [string]$Message
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    $TextBox.AppendText("[$timestamp] $Message`r`n")
    $TextBox.ScrollToCaret()
}

function New-Button {
    <#
    .SYNOPSIS
        Creates a standard button with consistent styling.
    #>
    param(
        [string]$Text,
        [int]$Width = 120,
        [int]$Height = 30,
        [switch]$RequiresElevation
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = if ($RequiresElevation) { "$Text" } else { $Text }
    $button.Width = $Width
    $button.Height = $Height
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    if ($RequiresElevation) {
        $button.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 180, 100)
    }

    return $button
}

#region Status Bar Helper Functions
function Start-AppActivity {
    <#
    .SYNOPSIS
        Shows pulsing activity indicator for operations with unknown duration.
    .PARAMETER Message
        Status message to display.
    #>
    param([string]$Message)
    $script:statusLabel.Text = $Message
    $script:statusLabel.ForeColor = [System.Drawing.Color]::Black
    $script:activityBar.Visible = $true
    $script:progressBar.Visible = $false
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-AppProgress {
    <#
    .SYNOPSIS
        Shows progress bar for operations with known number of steps.
    .PARAMETER Value
        Current step number.
    .PARAMETER Maximum
        Total number of steps.
    .PARAMETER Message
        Optional status message to display.
    #>
    param(
        [int]$Value,
        [int]$Maximum = 100,
        [string]$Message = ""
    )
    if ($Message) { $script:statusLabel.Text = $Message }
    $script:statusLabel.ForeColor = [System.Drawing.Color]::Black
    $script:activityBar.Visible = $false
    $script:progressBar.Maximum = $Maximum
    $script:progressBar.Value = $Value
    $script:progressBar.Visible = $true
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-AppError {
    <#
    .SYNOPSIS
        Shows error message in status bar (red text).
    .PARAMETER Message
        Error message to display.
    #>
    param([string]$Message)
    $script:statusLabel.Text = $Message
    $script:statusLabel.ForeColor = [System.Drawing.Color]::Red
    $script:activityBar.Visible = $false
    $script:progressBar.Visible = $false
    [System.Windows.Forms.Application]::DoEvents()
}

function Clear-AppStatus {
    <#
    .SYNOPSIS
        Clears status bar - hides indicators and clears message.
    #>
    $script:statusLabel.Text = ""
    $script:statusLabel.ForeColor = [System.Drawing.Color]::Black
    $script:activityBar.Visible = $false
    $script:progressBar.Visible = $false
    [System.Windows.Forms.Application]::DoEvents()
}
#endregion

#region Settings Dialog
function Show-SettingsDialog {
    <#
    .SYNOPSIS
        Shows settings dialog for configuring default paths.
    #>
    $settingsForm = New-Object System.Windows.Forms.Form
    $settingsForm.Text = "Settings"
    $settingsForm.Size = New-Object System.Drawing.Size(500, 510)
    $settingsForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $settingsForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $settingsForm.MaximizeBox = $false
    $settingsForm.MinimizeBox = $false

    $yPos = 15

    # Software Installer Section
    $swLabel = New-Object System.Windows.Forms.Label
    $swLabel.Text = "Software Installer"
    $swLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $swLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $swLabel.AutoSize = $true
    $settingsForm.Controls.Add($swLabel)
    $yPos += 25

    # Network Path
    $netPathLabel = New-Object System.Windows.Forms.Label
    $netPathLabel.Text = "Default Network Path:"
    $netPathLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $netPathLabel.AutoSize = $true
    $settingsForm.Controls.Add($netPathLabel)
    $yPos += 22

    $netPathTextBox = New-Object System.Windows.Forms.TextBox
    $netPathTextBox.Location = New-Object System.Drawing.Point(15, $yPos)
    $netPathTextBox.Width = 380
    $netPathTextBox.Text = Get-ModuleSetting -ModuleName "SoftwareInstaller" -Key "networkPath" -Default ""
    $settingsForm.Controls.Add($netPathTextBox)

    $netBrowseBtn = New-Object System.Windows.Forms.Button
    $netBrowseBtn.Text = "..."
    $netBrowseBtn.Location = New-Object System.Drawing.Point(400, ($yPos - 2))
    $netBrowseBtn.Width = 40
    $netBrowseBtn.Height = 25
    $netBrowseBtn.Add_Click({
        $folder = New-Object System.Windows.Forms.FolderBrowserDialog
        $folder.Description = "Select network installer directory"
        if ($folder.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $netPathTextBox.Text = $folder.SelectedPath
        }
    })
    $settingsForm.Controls.Add($netBrowseBtn)
    $yPos += 35

    # Local Path
    $localPathLabel = New-Object System.Windows.Forms.Label
    $localPathLabel.Text = "Default Local/USB Path:"
    $localPathLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $localPathLabel.AutoSize = $true
    $settingsForm.Controls.Add($localPathLabel)
    $yPos += 22

    $localPathTextBox = New-Object System.Windows.Forms.TextBox
    $localPathTextBox.Location = New-Object System.Drawing.Point(15, $yPos)
    $localPathTextBox.Width = 380
    $localPathTextBox.Text = Get-ModuleSetting -ModuleName "SoftwareInstaller" -Key "localPath" -Default ""
    $settingsForm.Controls.Add($localPathTextBox)

    $localBrowseBtn = New-Object System.Windows.Forms.Button
    $localBrowseBtn.Text = "..."
    $localBrowseBtn.Location = New-Object System.Drawing.Point(400, ($yPos - 2))
    $localBrowseBtn.Width = 40
    $localBrowseBtn.Height = 25
    $localBrowseBtn.Add_Click({
        $folder = New-Object System.Windows.Forms.FolderBrowserDialog
        $folder.Description = "Select local installer directory"
        if ($folder.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $localPathTextBox.Text = $folder.SelectedPath
        }
    })
    $settingsForm.Controls.Add($localBrowseBtn)
    $yPos += 40

    # Printer Management Section
    $printerLabel = New-Object System.Windows.Forms.Label
    $printerLabel.Text = "Printer Management"
    $printerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $printerLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $printerLabel.AutoSize = $true
    $settingsForm.Controls.Add($printerLabel)
    $yPos += 25

    # Print Server
    $serverLabel = New-Object System.Windows.Forms.Label
    $serverLabel.Text = "Default Print Server:"
    $serverLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $serverLabel.AutoSize = $true
    $settingsForm.Controls.Add($serverLabel)
    $yPos += 22

    $serverTextBox = New-Object System.Windows.Forms.TextBox
    $serverTextBox.Location = New-Object System.Drawing.Point(15, $yPos)
    $serverTextBox.Width = 380
    $serverTextBox.Text = Get-ModuleSetting -ModuleName "PrinterManagement" -Key "defaultServer" -Default "\\RUDWV-PS401"
    $settingsForm.Controls.Add($serverTextBox)
    $yPos += 40

    # Credentials Section
    $credLabel = New-Object System.Windows.Forms.Label
    $credLabel.Text = "Credentials"
    $credLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $credLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $credLabel.AutoSize = $true
    $settingsForm.Controls.Add($credLabel)
    $yPos += 25

    # Default Domain
    $domainLabel = New-Object System.Windows.Forms.Label
    $domainLabel.Text = "Default Domain (auto-prepended if not specified):"
    $domainLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $domainLabel.AutoSize = $true
    $settingsForm.Controls.Add($domainLabel)
    $yPos += 22

    $domainTextBox = New-Object System.Windows.Forms.TextBox
    $domainTextBox.Location = New-Object System.Drawing.Point(15, $yPos)
    $domainTextBox.Width = 200
    $defaultDomain = if ($script:Settings.global.defaultDomain) { $script:Settings.global.defaultDomain } else { "RUSH" }
    $domainTextBox.Text = $defaultDomain
    $settingsForm.Controls.Add($domainTextBox)
    $yPos += 40

    # General Section
    $generalLabel = New-Object System.Windows.Forms.Label
    $generalLabel.Text = "General"
    $generalLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $generalLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $generalLabel.AutoSize = $true
    $settingsForm.Controls.Add($generalLabel)
    $yPos += 25

    # Default Tab
    $tabLabel = New-Object System.Windows.Forms.Label
    $tabLabel.Text = "Default Tab on Startup:"
    $tabLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $tabLabel.AutoSize = $true
    $settingsForm.Controls.Add($tabLabel)
    $yPos += 22

    $tabCombo = New-Object System.Windows.Forms.ComboBox
    $tabCombo.Location = New-Object System.Drawing.Point(15, $yPos)
    $tabCombo.Width = 200
    $tabCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $tabCombo.Items.AddRange(@("System Info", "Software", "Printers"))
    $currentTab = if ($script:Settings.global.lastTab) { $script:Settings.global.lastTab } else { "System Info" }
    $tabCombo.SelectedItem = $currentTab
    if ($tabCombo.SelectedIndex -lt 0) { $tabCombo.SelectedIndex = 0 }
    $settingsForm.Controls.Add($tabCombo)
    $yPos += 40

    # Buttons
    $saveBtn = New-Object System.Windows.Forms.Button
    $saveBtn.Text = "Save"
    $saveBtn.Location = New-Object System.Drawing.Point(290, $yPos)
    $saveBtn.Width = 80
    $saveBtn.Height = 30
    $saveBtn.Add_Click({
        Set-ModuleSetting -ModuleName "SoftwareInstaller" -Key "networkPath" -Value $netPathTextBox.Text.Trim()
        Set-ModuleSetting -ModuleName "SoftwareInstaller" -Key "localPath" -Value $localPathTextBox.Text.Trim()
        Set-ModuleSetting -ModuleName "PrinterManagement" -Key "defaultServer" -Value $serverTextBox.Text.Trim()
        # Save global settings
        $script:Settings.global.defaultDomain = $domainTextBox.Text.Trim()
        $script:Settings.global.lastTab = $tabCombo.SelectedItem.ToString()
        Save-Settings
        [System.Windows.Forms.MessageBox]::Show(
            "Settings saved. Changes will apply when modules are refreshed or restarted.",
            "Settings Saved",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        $settingsForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $settingsForm.Close()
    })
    $settingsForm.Controls.Add($saveBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(380, $yPos)
    $cancelBtn.Width = 80
    $cancelBtn.Height = 30
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $settingsForm.Controls.Add($cancelBtn)

    $settingsForm.AcceptButton = $saveBtn
    $settingsForm.CancelButton = $cancelBtn

    $settingsForm.ShowDialog() | Out-Null
    $settingsForm.Dispose()
}
#endregion

#endregion

#region Main Window
function Show-MainWindow {
    # Show splash screen immediately
    Show-SplashScreen
    Update-SplashStatus "Initializing..."

    # Initialize session logging
    Initialize-SessionLog

    Update-SplashStatus "Verifying integrity..."

    # SECURITY: Check if manifests exist, offer to create on first run
    $manifestsExist = (Test-Path $script:ModuleManifestFile) -and (Test-Path $script:IntegrityManifestFile)

    if (-not $manifestsExist) {
        Update-SplashStatus "First run detected - initializing security..."

        # First run - offer to generate manifests
        $msg = "Security manifests not found (first run).`n`nGenerate security manifests now?`n`nThis will register all current modules as trusted.`nOnly do this if you trust the current module files."
        $result = [System.Windows.Forms.MessageBox]::Show($msg, "Initialize Security", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)

        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Update-SecurityManifests
            [System.Windows.Forms.MessageBox]::Show(
                "Security manifests created.`n`nThe application will now run in protected mode.",
                "Security Initialized",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
        else {
            # User declined - run in warn mode for this session
            $script:SecurityMode = "Warn"
            $warnMsg = "Running in WARN mode for this session.`n`nModules will load but may not be verified.`nUse Tools -> Security Options -> Update Security Manifests to enable full protection."
            [System.Windows.Forms.MessageBox]::Show($warnMsg, "Security Warning", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    }

    # SECURITY: Run integrity check before loading anything
    $integrityResult = Test-ApplicationIntegrity

    if (-not $integrityResult.Passed) {
        Close-SplashScreen

        $failureMsg = "SECURITY ALERT`n`nApplication integrity check failed:`n`n"
        $failureMsg += ($integrityResult.Failures -join "`n")
        $failureMsg += "`n`nThe application will not start to protect your system.`n`n"
        $failureMsg += "If you made legitimate changes, use:`n"
        $failureMsg += "Tools → Security Options → Update Security Manifests"

        [void][System.Windows.Forms.MessageBox]::Show(
            $failureMsg,
            "Security - Integrity Check Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return
    }

    if ($integrityResult.Warnings.Count -gt 0) {
        # Show warnings but continue
        $warningMsg = "Security Warnings:`n`n" + ($integrityResult.Warnings -join "`n")
        Show-SecurityWarning -Title "Security Warnings" -Message $warningMsg
    }

    Update-SplashStatus "Loading settings..."

    # Load settings first
    Load-Settings
    Update-SplashStatus "Building interface..."

    # Create main form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($script:AppName) v$($script:AppVersion)"
    $form.Size = New-Object System.Drawing.Size(
        $script:Settings.global.windowWidth,
        $script:Settings.global.windowHeight
    )
    $form.MinimumSize = New-Object System.Drawing.Size(900, 700)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Icon = [System.Drawing.SystemIcons]::Application

    # Menu strip
    $menuStrip = New-Object System.Windows.Forms.MenuStrip

    # Tools menu
    $toolsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $toolsMenu.Text = "&Tools"

    # Credential Options submenu
    $credentialMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $credentialMenu.Text = "Credential Options"

    # Cache credentials checkbox
    $cacheMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $cacheMenuItem.Text = "Enable Credential Caching (PIN Protected)"
    $cacheMenuItem.CheckOnClick = $true
    $cacheMenuItem.Checked = $script:CacheCredentials
    $cacheMenuItem.Add_Click({
        $script:CacheCredentials = $cacheMenuItem.Checked
        $script:Settings.global.cacheCredentials = $script:CacheCredentials
        Save-Settings
        if (-not $script:CacheCredentials) {
            Clear-CachedCredentials
        }
    })
    $credentialMenu.DropDownItems.Add($cacheMenuItem) | Out-Null

    # Set/Update Credentials
    $setCredMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $setCredMenuItem.Text = "Set/Update Credentials..."
    $setCredMenuItem.Add_Click({ Set-ManualCredentials })
    $credentialMenu.DropDownItems.Add($setCredMenuItem) | Out-Null

    # Lock Now (force PIN re-entry)
    $lockMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $lockMenuItem.Text = "Lock Now (Require PIN)"
    $lockMenuItem.Add_Click({ Lock-CachedCredentials })
    $credentialMenu.DropDownItems.Add($lockMenuItem) | Out-Null

    # Copy Password to Clipboard
    $copyPwdMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $copyPwdMenuItem.Text = "Copy Password to Clipboard"
    $copyPwdMenuItem.Add_Click({ Copy-PasswordToClipboard })
    $credentialMenu.DropDownItems.Add($copyPwdMenuItem) | Out-Null

    # QR Code Authenticator (displays QR with username + TAB + password)
    $qrMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $qrMenuItem.Text = "QR Code Authenticator"
    $qrMenuItem.Add_Click({ Show-QRCodeAuthenticator })
    $credentialMenu.DropDownItems.Add($qrMenuItem) | Out-Null

    # Separator
    $credentialMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Clear cached credentials
    $clearCredMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $clearCredMenuItem.Text = "Clear Cached Credentials"
    $clearCredMenuItem.Add_Click({ Clear-CachedCredentials })
    $credentialMenu.DropDownItems.Add($clearCredMenuItem) | Out-Null

    $toolsMenu.DropDownItems.Add($credentialMenu) | Out-Null

    # Security Options submenu
    $securityMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $securityMenu.Text = "Security Options"

    # Security Mode options
    $secModeEnforced = New-Object System.Windows.Forms.ToolStripMenuItem
    $secModeEnforced.Text = "Enforced (Block unauthorized)"
    $secModeEnforced.Checked = ($script:SecurityMode -eq "Enforced")
    $secModeEnforced.Add_Click({
        $script:SecurityMode = "Enforced"
        $secModeEnforced.Checked = $true
        $secModeWarn.Checked = $false
        $secModeDisabled.Checked = $false
        [System.Windows.Forms.MessageBox]::Show(
            "Security mode set to ENFORCED.`n`nUnauthorized modules will be blocked.",
            "Security Mode",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $securityMenu.DropDownItems.Add($secModeEnforced) | Out-Null

    $secModeWarn = New-Object System.Windows.Forms.ToolStripMenuItem
    $secModeWarn.Text = "Warn (Allow with warning)"
    $secModeWarn.Checked = ($script:SecurityMode -eq "Warn")
    $secModeWarn.Add_Click({
        $script:SecurityMode = "Warn"
        $secModeEnforced.Checked = $false
        $secModeWarn.Checked = $true
        $secModeDisabled.Checked = $false
        [System.Windows.Forms.MessageBox]::Show(
            "Security mode set to WARN.`n`nUnauthorized modules will show warnings but still load.",
            "Security Mode",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    })
    $securityMenu.DropDownItems.Add($secModeWarn) | Out-Null

    $secModeDisabled = New-Object System.Windows.Forms.ToolStripMenuItem
    $secModeDisabled.Text = "Disabled (No checks)"
    $secModeDisabled.Checked = ($script:SecurityMode -eq "Disabled")
    $secModeDisabled.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "WARNING: Disabling security checks allows any module to be loaded.`n`nThis should only be used for development.`n`nDisable security?",
            "Confirm Disable Security",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:SecurityMode = "Disabled"
            $secModeEnforced.Checked = $false
            $secModeWarn.Checked = $false
            $secModeDisabled.Checked = $true
        }
    })
    $securityMenu.DropDownItems.Add($secModeDisabled) | Out-Null

    $securityMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Update manifests
    $updateManifestItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $updateManifestItem.Text = "Update Security Manifests"
    $updateManifestItem.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This will update the security manifests with current file hashes.`n`nOnly do this after making legitimate changes to modules.`n`nUpdate manifests?",
            "Update Security Manifests",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $result = Update-SecurityManifests
            [System.Windows.Forms.MessageBox]::Show(
                "Security manifests updated.`n`nModules registered: $($result.ModulesRegistered)`nManifest location: $($result.ManifestPath)",
                "Manifests Updated",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
    })
    $securityMenu.DropDownItems.Add($updateManifestItem) | Out-Null

    $toolsMenu.DropDownItems.Add($securityMenu) | Out-Null

    # Settings
    $settingsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $settingsMenuItem.Text = "Settings..."
    $settingsMenuItem.Add_Click({ Show-SettingsDialog })
    $toolsMenu.DropDownItems.Add($settingsMenuItem) | Out-Null

    # Separator
    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Refresh modules
    $refreshMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $refreshMenuItem.Text = "Refresh Modules"
    $refreshMenuItem.Add_Click({
        [System.Windows.Forms.MessageBox]::Show(
            "Please restart the application to reload modules.",
            "Refresh Modules",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $toolsMenu.DropDownItems.Add($refreshMenuItem) | Out-Null

    $menuStrip.Items.Add($toolsMenu) | Out-Null

    # Help menu
    $helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $helpMenu.Text = "&Help"

    # Check for Updates
    $checkUpdateMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $checkUpdateMenuItem.Text = "Check for Updates..."
    $checkUpdateMenuItem.Add_Click({ Invoke-CheckForUpdates })
    $helpMenu.DropDownItems.Add($checkUpdateMenuItem) | Out-Null

    $helpMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $viewLogsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $viewLogsMenuItem.Text = "View Session Logs"
    $viewLogsMenuItem.Add_Click({ Open-SessionLogsFolder })
    $helpMenu.DropDownItems.Add($viewLogsMenuItem) | Out-Null

    $helpMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $aboutMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $aboutMenuItem.Text = "About"
    $aboutMenuItem.Add_Click({
        [System.Windows.Forms.MessageBox]::Show(
            "$($script:AppName) v$($script:AppVersion)`n`nPortable IT Technician Toolkit`nRush University Medical Center`n`nRunning as: $env:USERDOMAIN\$env:USERNAME",
            "About",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $helpMenu.DropDownItems.Add($aboutMenuItem) | Out-Null

    $menuStrip.Items.Add($helpMenu) | Out-Null

    $form.MainMenuStrip = $menuStrip
    $form.Controls.Add($menuStrip)

    # Tab control
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $tabControl.ShowToolTips = $true
    $tabControl.ItemSize = New-Object System.Drawing.Size(130, 30)
    $tabControl.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed

    # Status strip (bottom bar)
    $statusStrip = New-Object System.Windows.Forms.StatusStrip

    # Activity indicator (pulsing/marquee for indeterminate progress)
    $script:activityBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $script:activityBar.Width = 80
    $script:activityBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $script:activityBar.MarqueeAnimationSpeed = 30
    $script:activityBar.Visible = $false
    $statusStrip.Items.Add($script:activityBar) | Out-Null

    # Status message label
    $script:statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:statusLabel.Text = ""
    $script:statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusStrip.Items.Add($script:statusLabel) | Out-Null

    # Progress bar (for determinate progress like "2 of 5")
    $script:progressBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $script:progressBar.Width = 120
    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $script:progressBar.Visible = $false
    $statusStrip.Items.Add($script:progressBar) | Out-Null

    # Separator before user info
    $separator = New-Object System.Windows.Forms.ToolStripStatusLabel
    $separator.Spring = $true
    $statusStrip.Items.Add($separator) | Out-Null

    # Credential status indicator
    $script:credStatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:credStatusLabel.Text = "No Creds"
    $script:credStatusLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:credStatusLabel.ToolTipText = "No credentials cached"
    $script:credStatusLabel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 10, 0)
    $statusStrip.Items.Add($script:credStatusLabel) | Out-Null

    $userLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $userLabel.Text = "Running as: $env:USERDOMAIN\$env:USERNAME"
    $userLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $statusStrip.Items.Add($userLabel) | Out-Null

    $versionLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $versionLabel.Text = "v$($script:AppVersion)"
    $versionLabel.ForeColor = [System.Drawing.Color]::Gray
    $statusStrip.Items.Add($versionLabel) | Out-Null

    # Panel to hold tab control (between menu and status bar)
    $mainPanel = New-Object System.Windows.Forms.Panel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.Padding = New-Object System.Windows.Forms.Padding(10, 35, 10, 5)
    $mainPanel.Controls.Add($tabControl)

    # Add controls in correct order (top to bottom)
    $form.Controls.Add($mainPanel)
    $form.Controls.Add($statusStrip)

    # Update credential status indicator on startup
    Update-CredentialStatusIndicator

    # Load modules
    Update-SplashStatus "Loading modules..."
    $modules = Get-Modules
    $loadedCount = 0
    $moduleIndex = 0
    $totalModules = $modules.Count

    foreach ($module in $modules) {
        $moduleIndex++
        Update-SplashStatus "Loading module $moduleIndex of $totalModules`: $($module.BaseName)..."
        if (Load-Module -ModuleFile $module -TabControl $tabControl) {
            $loadedCount++
        }
    }

    # If no modules loaded, show a welcome tab
    if ($loadedCount -eq 0) {
        $welcomeTab = New-Object System.Windows.Forms.TabPage
        $welcomeTab.Text = "Welcome"
        $welcomeTab.Padding = New-Object System.Windows.Forms.Padding(20)

        $welcomeLabel = New-Object System.Windows.Forms.Label
        $welcomeLabel.Text = @"
Welcome to $($script:AppName)!

No modules were found in the Modules folder.

To add functionality:
1. Create a .ps1 file in the Modules folder
2. Define `$ModuleName and `$ModuleDescription variables
3. Define an Initialize-Module function
4. Restart this application

Example module structure:
`$ModuleName = "My Module"
`$ModuleDescription = "Does something useful"

function Initialize-Module {
    param([System.Windows.Forms.TabPage]`$tab)
    # Add your UI controls here
}
"@
        $welcomeLabel.AutoSize = $true
        $welcomeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11)
        $welcomeLabel.Location = New-Object System.Drawing.Point(20, 20)
        $welcomeTab.Controls.Add($welcomeLabel)

        $tabControl.TabPages.Add($welcomeTab)
    }

    # Save window size on close
    $form.Add_FormClosing({
        $script:Settings.global.windowWidth = $form.Width
        $script:Settings.global.windowHeight = $form.Height
        if ($tabControl.SelectedTab) {
            $script:Settings.global.lastTab = $tabControl.SelectedTab.Text
        }
        Disconnect-NetworkShare
        Save-Settings
        Close-SessionLog
    })

    # Always start on System Info (field techs move between machines constantly)
    $systemInfoFound = $false
    foreach ($tab in $tabControl.TabPages) {
        if ($tab.Text -eq "System Info") {
            $tabControl.SelectedTab = $tab
            $systemInfoFound = $true
            break
        }
    }
    # Fallback: first tab (System Info sorts first due to 01_ prefix)
    if (-not $systemInfoFound -and $tabControl.TabPages.Count -gt 0) {
        $tabControl.SelectedIndex = 0
    }

    # Close splash and show main form
    Update-SplashStatus "Ready!"
    Close-SplashScreen
    [void]$form.ShowDialog()
}
#endregion

#region Main Entry Point
# Run the application
Show-MainWindow
#endregion
