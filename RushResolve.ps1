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

# Inline QR Code Generator - generates QR codes locally without external dependencies
$qrCodeSource = @"
using System;
using System.Drawing;
using System.Text;
using System.Collections.Generic;

public class SimpleQRGenerator {
    // QR Code Version 3 (29x29 modules) - supports up to 77 alphanumeric chars
    private const int SIZE = 29;
    private const int VERSION = 3;
    private bool[,] modules;
    private bool[,] isFunction;

    public static Bitmap Generate(string text, int scale = 8) {
        var qr = new SimpleQRGenerator();
        return qr.CreateQR(text, scale);
    }

    private Bitmap CreateQR(string text, int scale) {
        modules = new bool[SIZE, SIZE];
        isFunction = new bool[SIZE, SIZE];

        // Add function patterns
        AddFinderPattern(0, 0);
        AddFinderPattern(SIZE - 7, 0);
        AddFinderPattern(0, SIZE - 7);
        AddAlignmentPattern(22, 22);
        AddTimingPatterns();
        AddFormatInfo();
        AddVersionInfo();

        // Encode data
        byte[] data = EncodeData(text);
        PlaceData(data);
        ApplyMask();

        // Render to bitmap
        int imgSize = SIZE * scale + scale * 2;
        Bitmap bmp = new Bitmap(imgSize, imgSize);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.Clear(Color.White);
            for (int y = 0; y < SIZE; y++) {
                for (int x = 0; x < SIZE; x++) {
                    if (modules[y, x]) {
                        g.FillRectangle(Brushes.Black,
                            (x + 1) * scale, (y + 1) * scale, scale, scale);
                    }
                }
            }
        }
        return bmp;
    }

    private void AddFinderPattern(int row, int col) {
        for (int r = -1; r <= 7; r++) {
            for (int c = -1; c <= 7; c++) {
                int rr = row + r, cc = col + c;
                if (rr < 0 || rr >= SIZE || cc < 0 || cc >= SIZE) continue;
                bool black = (r >= 0 && r <= 6 && (c == 0 || c == 6)) ||
                            (c >= 0 && c <= 6 && (r == 0 || r == 6)) ||
                            (r >= 2 && r <= 4 && c >= 2 && c <= 4);
                modules[rr, cc] = black;
                isFunction[rr, cc] = true;
            }
        }
    }

    private void AddAlignmentPattern(int row, int col) {
        for (int r = -2; r <= 2; r++) {
            for (int c = -2; c <= 2; c++) {
                int rr = row + r, cc = col + c;
                bool black = Math.Max(Math.Abs(r), Math.Abs(c)) != 1;
                modules[rr, cc] = black;
                isFunction[rr, cc] = true;
            }
        }
    }

    private void AddTimingPatterns() {
        for (int i = 8; i < SIZE - 8; i++) {
            bool black = i % 2 == 0;
            modules[6, i] = black;
            modules[i, 6] = black;
            isFunction[6, i] = true;
            isFunction[i, 6] = true;
        }
    }

    private void AddFormatInfo() {
        int format = 0x5412; // Mask 0, EC level L
        for (int i = 0; i <= 5; i++) { modules[8, i] = ((format >> i) & 1) == 1; isFunction[8, i] = true; }
        modules[8, 7] = ((format >> 6) & 1) == 1; isFunction[8, 7] = true;
        modules[8, 8] = ((format >> 7) & 1) == 1; isFunction[8, 8] = true;
        modules[7, 8] = ((format >> 8) & 1) == 1; isFunction[7, 8] = true;
        for (int i = 9; i < 15; i++) { modules[14 - i, 8] = ((format >> i) & 1) == 1; isFunction[14 - i, 8] = true; }
        for (int i = 0; i < 8; i++) { modules[SIZE - 1 - i, 8] = ((format >> i) & 1) == 1; isFunction[SIZE - 1 - i, 8] = true; }
        modules[SIZE - 8, 8] = true; isFunction[SIZE - 8, 8] = true;
        for (int i = 8; i < 15; i++) { modules[8, SIZE - 15 + i] = ((format >> i) & 1) == 1; isFunction[8, SIZE - 15 + i] = true; }
    }

    private void AddVersionInfo() { } // Not needed for version 3

    private byte[] EncodeData(string text) {
        List<bool> bits = new List<bool>();
        // Mode indicator: Byte mode (0100)
        bits.Add(false); bits.Add(true); bits.Add(false); bits.Add(false);
        // Character count (8 bits for version 1-9 byte mode)
        byte[] textBytes = Encoding.UTF8.GetBytes(text);
        for (int i = 7; i >= 0; i--) bits.Add(((textBytes.Length >> i) & 1) == 1);
        // Data
        foreach (byte b in textBytes)
            for (int i = 7; i >= 0; i--) bits.Add(((b >> i) & 1) == 1);
        // Terminator
        for (int i = 0; i < 4 && bits.Count < 440; i++) bits.Add(false);
        // Pad to byte boundary
        while (bits.Count % 8 != 0) bits.Add(false);
        // Pad codewords
        byte[] pads = { 0xEC, 0x11 };
        int padIdx = 0;
        while (bits.Count < 440) {
            for (int i = 7; i >= 0; i--) bits.Add(((pads[padIdx] >> i) & 1) == 1);
            padIdx = (padIdx + 1) % 2;
        }
        // Convert to bytes and add error correction
        byte[] data = new byte[55];
        for (int i = 0; i < 55; i++) {
            for (int j = 0; j < 8; j++)
                if (bits[i * 8 + j]) data[i] |= (byte)(1 << (7 - j));
        }
        byte[] ec = CalculateEC(data);
        byte[] result = new byte[70];
        Array.Copy(data, result, 55);
        Array.Copy(ec, 0, result, 55, 15);
        return result;
    }

    private byte[] CalculateEC(byte[] data) {
        // Simplified Reed-Solomon for version 3-L (15 EC codewords)
        int[] gen = { 8, 183, 61, 91, 202, 37, 51, 58, 58, 237, 140, 124, 5, 99, 105 };
        byte[] ec = new byte[15];
        byte[] work = new byte[70];
        Array.Copy(data, work, 55);
        for (int i = 0; i < 55; i++) {
            byte coef = work[i];
            if (coef != 0) {
                int logCoef = GFLog[coef];
                for (int j = 0; j < 15; j++)
                    work[i + j + 1] = (byte)(work[i + j + 1] ^ GFExp[(logCoef + gen[j]) % 255]);
            }
        }
        Array.Copy(work, 55, ec, 0, 15);
        return ec;
    }

    private static int[] GFExp = new int[512];
    private static int[] GFLog = new int[256];
    static SimpleQRGenerator() {
        int x = 1;
        for (int i = 0; i < 255; i++) {
            GFExp[i] = x; GFLog[x] = i;
            x <<= 1;
            if (x >= 256) x ^= 0x11D;
        }
        for (int i = 255; i < 512; i++) GFExp[i] = GFExp[i - 255];
    }

    private void PlaceData(byte[] data) {
        int bitIdx = 0;
        for (int right = SIZE - 1; right >= 1; right -= 2) {
            if (right == 6) right = 5;
            for (int vert = 0; vert < SIZE; vert++) {
                for (int j = 0; j < 2; j++) {
                    int x = right - j;
                    bool upward = ((right + 1) / 2) % 2 == 0;
                    int y = upward ? SIZE - 1 - vert : vert;
                    if (!isFunction[y, x] && bitIdx < data.Length * 8) {
                        modules[y, x] = ((data[bitIdx / 8] >> (7 - bitIdx % 8)) & 1) == 1;
                        bitIdx++;
                    }
                }
            }
        }
    }

    private void ApplyMask() {
        // Mask pattern 0: (row + column) mod 2 == 0
        for (int y = 0; y < SIZE; y++)
            for (int x = 0; x < SIZE; x++)
                if (!isFunction[y, x] && (y + x) % 2 == 0)
                    modules[y, x] = !modules[y, x];
    }
}
"@

try {
    Add-Type -TypeDefinition $qrCodeSource -ReferencedAssemblies System.Drawing -ErrorAction Stop
    $script:QRGeneratorAvailable = $true
}
catch {
    $script:QRGeneratorAvailable = $false
    Write-Warning "QR Code generator could not be loaded: $_"
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

    # App name
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
$script:AppVersion = "2.3"  # Session logging
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

# Session logging
$script:LogsPath = Join-Path $script:AppPath "Logs"
$script:SessionLogFile = $null
#endregion

#region Session Logging
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

        # Generate filename with timestamp
        $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
        $script:SessionLogFile = Join-Path $script:LogsPath "session_$timestamp.log"

        # Write header
        $header = @"
================================================================================
RUSH RESOLVE SESSION LOG
================================================================================
Started: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
User: $env:USERDOMAIN\$env:USERNAME
Computer: $env:COMPUTERNAME
Version: $($script:AppVersion)
================================================================================

"@
        Set-Content -Path $script:SessionLogFile -Value $header -Force
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
        The message to log.
    .PARAMETER Category
        Optional category prefix (e.g., "Credentials", "Disk Cleanup").
    #>
    param(
        [string]$Message,
        [string]$Category = ""
    )

    if (-not $script:SessionLogFile) { return }

    try {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $logEntry = if ($Category) {
            "[$timestamp] [$Category] $Message"
        } else {
            "[$timestamp] $Message"
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
        Encrypts a PSCredential using DPAPI with PIN as additional entropy.
    #>
    param(
        [PSCredential]$Credential,
        [string]$PIN
    )

    try {
        # Convert credential to storable format
        $username = $Credential.UserName
        $password = $Credential.GetNetworkCredential().Password
        $data = "$username|$password"
        $dataBytes = [System.Text.Encoding]::UTF8.GetBytes($data)

        # Use PIN as additional entropy
        $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes($PIN)

        # Encrypt with DPAPI (CurrentUser scope + entropy)
        $encryptedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $dataBytes,
            $entropyBytes,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )

        return $encryptedBytes
    }
    catch {
        Write-Warning "Failed to encrypt credential: $_"
        return $null
    }
}

function Unprotect-Credential {
    <#
    .SYNOPSIS
        Decrypts credential blob using DPAPI with PIN as entropy.
    #>
    param(
        [byte[]]$EncryptedData,
        [string]$PIN
    )

    try {
        # Use PIN as entropy
        $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes($PIN)

        # Decrypt with DPAPI
        $decryptedBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $EncryptedData,
            $entropyBytes,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )

        $data = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
        $parts = $data -split '\|', 2

        if ($parts.Count -eq 2) {
            $securePassword = ConvertTo-SecureString $parts[1] -AsPlainText -Force
            return New-Object System.Management.Automation.PSCredential($parts[0], $securePassword)
        }
        return $null
    }
    catch {
        # Decryption failed (wrong PIN or corrupted data)
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

                # Copy password to clipboard
                $password = $decrypted.GetNetworkCredential().Password
                [System.Windows.Forms.Clipboard]::SetText($password)
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

    # Generate QR code string: username + TAB + password
    $username = $credential.UserName
    $password = $credential.GetNetworkCredential().Password
    $qrString = "$username`t$password"

    Write-SessionLog -Message "QR Code Authenticator displayed" -Category "Credentials"

    # Generate QR code bitmap
    try {
        $qrBitmap = [SimpleQRGenerator]::Generate($qrString, 10)
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

    # Create popup form
    $qrForm = New-Object System.Windows.Forms.Form
    $qrForm.Text = "QR Code Authenticator"
    $qrForm.Size = New-Object System.Drawing.Size(380, 480)
    $qrForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $qrForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $qrForm.MaximizeBox = $false
    $qrForm.MinimizeBox = $false
    $qrForm.TopMost = $true
    $qrForm.BackColor = [System.Drawing.Color]::White

    # Title label
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Scan with barcode scanner"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(85, 15)
    $qrForm.Controls.Add($titleLabel)

    # QR code PictureBox
    $pictureBox = New-Object System.Windows.Forms.PictureBox
    $pictureBox.Image = $qrBitmap
    $pictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::AutoSize
    $pictureBox.Location = New-Object System.Drawing.Point(35, 50)
    $qrForm.Controls.Add($pictureBox)

    # Info label
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "Contains: Username [TAB] Password`n`nScanner will type credentials automatically."
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $infoLabel.ForeColor = [System.Drawing.Color]::DarkGray
    $infoLabel.AutoSize = $true
    $infoLabel.Location = New-Object System.Drawing.Point(60, 365)
    $qrForm.Controls.Add($infoLabel)

    # Countdown label
    $countdownLabel = New-Object System.Windows.Forms.Label
    $countdownLabel.Text = "Auto-close in 60 seconds"
    $countdownLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $countdownLabel.ForeColor = [System.Drawing.Color]::Red
    $countdownLabel.AutoSize = $true
    $countdownLabel.Location = New-Object System.Drawing.Point(115, 405)
    $qrForm.Controls.Add($countdownLabel)

    # OK button
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Width = 100
    $okButton.Height = 30
    $okButton.Location = New-Object System.Drawing.Point(140, 430)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $qrForm.Controls.Add($okButton)
    $qrForm.AcceptButton = $okButton

    # Timer for auto-close
    $secondsRemaining = 60
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000

    $timer.Add_Tick({
        $script:qrSecondsRemaining--
        $countdownLabel.Text = "Auto-close in $($script:qrSecondsRemaining) seconds"
        if ($script:qrSecondsRemaining -le 0) {
            $timer.Stop()
            $qrForm.Close()
        }
    }.GetNewClosure())

    $script:qrSecondsRemaining = 60
    $timer.Start()

    # Show form
    $qrForm.ShowDialog() | Out-Null

    # Cleanup
    $timer.Stop()
    $timer.Dispose()
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

    try {
        # Create temp folder if it doesn't exist
        $tempFolder = "C:\Temp\RushResolve_Install"
        if (-not (Test-Path $tempFolder)) {
            New-Item -Path $tempFolder -ItemType Directory -Force | Out-Null
        }
        $tempScript = Join-Path $tempFolder "RushResolve_$(Get-Random).ps1"

        # Build the script content
        $scriptContent = @"
`$ErrorActionPreference = 'Stop'
try {
    `$output = & {
        $($ScriptBlock.ToString())
    } $($ArgumentList -join ' ')
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
        # Clean up temp file
        if ($tempScript -and (Test-Path $tempScript)) {
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
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
            if ($Wait) { $startParams.Wait = $true }

            $process = Start-Process @startParams
            if ($Wait -and $process) {
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
        if ($Wait) { $startParams.Wait = $true }

        $process = Start-Process @startParams

        if ($Wait -and $process) {
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
        $jobResult = $job | Wait-Job | Receive-Job
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

function Clear-CachedCredentials {
    # Clear in-memory credential
    $script:CachedCredential = $null
    $script:CredentialPINHash = $null
    $script:PINLastVerified = $null
    $script:PINFailCount = 0

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
        Save-Settings
        Close-SessionLog
    })

    # Restore last tab
    if ($script:Settings.global.lastTab) {
        foreach ($tab in $tabControl.TabPages) {
            if ($tab.Text -eq $script:Settings.global.lastTab) {
                $tabControl.SelectedTab = $tab
                break
            }
        }
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
