#Requires -Version 5.1

<#
.SYNOPSIS
    Installs WinGet from bundled files if not already present
.DESCRIPTION
    Checks if WinGet is installed, and if not, installs it from the
    bundled .msixbundle and dependencies in this folder.
.NOTES
    No admin rights required - installs per-user
#>

param(
    [switch]$Force  # Force reinstall even if already present
)

function Test-WinGetInstalled {
    try {
        $null = Get-Command winget -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        default { "White" }
    }
    Write-Host "[$timestamp] $Message" -ForegroundColor $color
}

# Check if already installed
if ((Test-WinGetInstalled) -and -not $Force) {
    Write-Log "WinGet is already installed." -Level Success
    $version = (winget --version)
    Write-Log "Version: $version" -Level Info
    exit 0
}

Write-Log "WinGet not found. Installing from bundled files..." -Level Warning

# Get script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Check for required files
$vcLibsPath = Join-Path $scriptDir "Microsoft.VCLibs.x64.14.00.Desktop.appx"
$uiXamlPath = Join-Path $scriptDir "Microsoft.UI.Xaml.2.8.x64.appx"
$wingetPath = Join-Path $scriptDir "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"

$missingFiles = @()
if (-not (Test-Path $vcLibsPath)) { $missingFiles += "Microsoft.VCLibs.x64.14.00.Desktop.appx" }
if (-not (Test-Path $uiXamlPath)) { $missingFiles += "Microsoft.UI.Xaml.2.8.x64.appx" }
if (-not (Test-Path $wingetPath)) { $missingFiles += "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" }

if ($missingFiles.Count -gt 0) {
    Write-Log "ERROR: Missing required files:" -Level Error
    foreach ($file in $missingFiles) {
        Write-Log "  - $file" -Level Error
    }
    Write-Log "" -Level Error
    Write-Log "Please download files according to Tools\WinGet\README.md" -Level Error
    exit 1
}

# Install dependencies and WinGet
try {
    Write-Log "Installing VCLibs dependency..." -Level Info
    Add-AppxPackage -Path $vcLibsPath -ErrorAction Stop
    Write-Log "  VCLibs installed successfully" -Level Success

    Write-Log "Installing UI.Xaml dependency..." -Level Info
    Add-AppxPackage -Path $uiXamlPath -ErrorAction Stop
    Write-Log "  UI.Xaml installed successfully" -Level Success

    Write-Log "Installing WinGet..." -Level Info
    Add-AppxPackage -Path $wingetPath -ErrorAction Stop
    Write-Log "  WinGet installed successfully" -Level Success

    # Verify installation
    Start-Sleep -Seconds 2  # Give it a moment to register
    if (Test-WinGetInstalled) {
        $version = (winget --version)
        Write-Log "" -Level Success
        Write-Log "WinGet installation complete!" -Level Success
        Write-Log "Version: $version" -Level Success
        Write-Log "" -Level Success
        Write-Log "You may need to restart PowerShell for PATH changes to take effect." -Level Warning
        exit 0
    }
    else {
        Write-Log "Installation completed but WinGet command not found." -Level Warning
        Write-Log "You may need to restart PowerShell or log out/in for PATH to update." -Level Warning
        exit 0
    }
}
catch {
    Write-Log "ERROR: Installation failed" -Level Error
    Write-Log $_.Exception.Message -Level Error
    Write-Log "" -Level Error
    Write-Log "Possible causes:" -Level Error
    Write-Log "  - Group Policy blocks AppX package installation" -Level Error
    Write-Log "  - Windows version too old (need Windows 10 1809+)" -Level Error
    Write-Log "  - Files corrupted (try re-downloading)" -Level Error
    exit 1
}
