<#
.SYNOPSIS
    Software Installer Module for Rush Resolve
.DESCRIPTION
    Install specialty applications from network share or local/USB directory.
    Supports optional install.json config files for silent install parameters.
#>

$script:ModuleName = "Software Installer"
$script:ModuleDescription = "Install applications from network share or check for updates"

#region HP Detection & HPIA Script Blocks

$script:IsHPMachine = $null
$script:HPIAPath = $null

$script:DetectHP = {
    if ($null -eq $script:IsHPMachine) {
        try {
            $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -Property Manufacturer -ErrorAction Stop).Manufacturer
            $script:IsHPMachine = ($manufacturer -match "HP|Hewlett")
        }
        catch {
            $script:IsHPMachine = $false
        }
    }
    return $script:IsHPMachine
}

$script:GetHPIAPath = {
    if ($null -eq $script:HPIAPath) {
        $repoHPIADir = Join-Path (Split-Path $PSScriptRoot -Parent) "Tools\HPIA"
        $repoHPIA = Join-Path $repoHPIADir "HPImageAssistant.exe"

        $possiblePaths = @(
            $repoHPIA,
            "${env:ProgramFiles(x86)}\HP\HPIA\HPImageAssistant.exe",
            "${env:ProgramFiles}\HP\HPIA\HPImageAssistant.exe",
            "C:\HPIA\HPImageAssistant.exe"
        )
        foreach ($path in $possiblePaths) {
            if (Test-Path $path) {
                $script:HPIAPath = $path
                break
            }
        }

        # If not found, check if the installer exe (hp-hpia-*.exe) is in the Tools\HPIA folder and extract it
        if ($null -eq $script:HPIAPath -and (Test-Path $repoHPIADir)) {
            $installer = Get-ChildItem -Path $repoHPIADir -Filter "hp-hpia-*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($installer) {
                Write-Host "Found HPIA installer: $($installer.Name). Extracting..."
                $extractDir = Join-Path $repoHPIADir "extracted"
                try {
                    Start-Process -FilePath $installer.FullName -ArgumentList "/s /e /f `"$extractDir`"" -Wait -NoNewWindow
                    $extracted = Get-ChildItem -Path $extractDir -Filter "HPImageAssistant.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($extracted) {
                        Get-ChildItem -Path $extracted.DirectoryName -ErrorAction SilentlyContinue | Copy-Item -Destination $repoHPIADir -Recurse -Force
                        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
                        if (Test-Path $repoHPIA) {
                            $script:HPIAPath = $repoHPIA
                            Write-Host "HPIA extracted successfully to: $repoHPIADir"
                        }
                    }
                } catch {
                    Write-Warning "Failed to extract HPIA installer: $_"
                }
            }
        }
    }
    return $script:HPIAPath
}

$script:RunHPIAAnalysis = {
    param([scriptblock]$Log)

    $findings = @()

    if (-not (& $script:DetectHP)) {
        if ($Log) { & $Log "Not an HP machine - skipping HPIA" }
        return $findings
    }

    $hpiaPath = & $script:GetHPIAPath
    if (-not $hpiaPath) {
        if ($Log) { & $Log "HPIA not found. Place hp-hpia-*.exe in Tools\HPIA or install HPIA." }
        return $findings
    }

    if ($Log) { & $Log "Running HP Image Assistant analysis..." }

    $reportPath = "$env:TEMP\HPIA_Report"
    if (Test-Path $reportPath) { Remove-Item $reportPath -Recurse -Force }
    New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

    try {
        $hpiaArgs = "/Operation:Analyze /Action:List /Category:Drivers /Silent /ReportFolder:`"$reportPath`""
        if ($Log) { & $Log "  Command: HPImageAssistant.exe $hpiaArgs" }

        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $hpiaPath
        $pinfo.Arguments = $hpiaArgs
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $pinfo
        $proc.Start() | Out-Null
        $proc.WaitForExit(120000)

        $jsonReport = Get-ChildItem $reportPath -Filter "*.json" -Recurse | Select-Object -First 1

        if ($jsonReport) {
            $report = Get-Content $jsonReport.FullName -Raw | ConvertFrom-Json

            $outdated = @()
            if ($report.HPIA.Recommendations) {
                foreach ($rec in $report.HPIA.Recommendations) {
                    if ($rec.RecommendationValue -eq "Install") {
                        $outdated += $rec
                    }
                }
            }

            foreach ($driver in $outdated) {
                $priority = if ($driver.CvaPackageInformation.Priority) { $driver.CvaPackageInformation.Priority } else { "Recommended" }
                $severity = switch ($priority) {
                    "Critical" { "Critical" }
                    "Recommended" { "Warning" }
                    default { "Info" }
                }
                $softpaqId = if ($driver.Id) { $driver.Id } else { "N/A" }
                $version = if ($driver.Version) { $driver.Version } else { "N/A" }

                $findings += @{
                    Name     = $driver.Name
                    Priority = $priority
                    Severity = $severity
                    SoftPaq  = $softpaqId
                    Version  = $version
                }
                if ($Log) { & $Log "  [$priority] $($driver.Name) - $softpaqId" }
            }

            if ($outdated.Count -eq 0) {
                if ($Log) { & $Log "  All HP drivers are up to date." }
            } else {
                $critCount = @($outdated | Where-Object { $_.CvaPackageInformation.Priority -eq "Critical" }).Count
                $recCount = @($outdated | Where-Object { $_.CvaPackageInformation.Priority -eq "Recommended" }).Count
                $routineCount = $outdated.Count - $critCount - $recCount
                if ($Log) { & $Log "  Summary: $critCount critical, $recCount recommended, $routineCount routine" }
            }
        }
        else {
            if ($Log) { & $Log "  No HPIA report generated" }
        }
    }
    catch {
        if ($Log) { & $Log "  HPIA analysis failed: $($_.Exception.Message)" }
    }
    finally {
        if (Test-Path $reportPath) { Remove-Item $reportPath -Recurse -Force -ErrorAction SilentlyContinue }
    }

    return $findings
}

$script:RunHPIAUpdate = {
    param(
        [scriptblock]$Log,
        [PSCredential]$Credential,
        [ValidateSet("All", "Critical", "Recommended")]
        [string]$Selection = "All"
    )

    if (-not (& $script:DetectHP)) {
        [System.Windows.Forms.MessageBox]::Show("This is not an HP machine.", "Not HP", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $hpiaPath = & $script:GetHPIAPath
    if (-not $hpiaPath) {
        [System.Windows.Forms.MessageBox]::Show("HP Image Assistant is not installed.`n`nDownload from:`nhttps://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html", "HPIA Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $selectionDesc = switch ($Selection) {
        "Critical" { "CRITICAL drivers only" }
        "Recommended" { "CRITICAL and RECOMMENDED drivers" }
        default { "ALL available drivers" }
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This will download and install $selectionDesc.`n`nThe system may require a reboot after updates.`n`nContinue?",
        "Install HP Driver Updates",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    if ($Log) { & $Log "Starting HP driver update (Selection: $Selection)..." }

    $reportPath = "$env:TEMP\HPIA_Update"
    if (Test-Path $reportPath) { Remove-Item $reportPath -Recurse -Force }
    New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

    try {
        $selectionArg = if ($Selection -eq "Recommended") { "Critical,Recommended" } else { $Selection }
        $hpiaArgs = "/Operation:Analyze /Action:Install /Category:Drivers /Selection:$selectionArg /Silent /ReportFolder:`"$reportPath`""

        if ($Log) { & $Log "  Running HPIA with /Action:Install..." }

        if ($Credential) {
            $result = Invoke-Elevated -ScriptBlock {
                param($path, $arguments)
                $pinfo = New-Object System.Diagnostics.ProcessStartInfo
                $pinfo.FileName = $path
                $pinfo.Arguments = $arguments
                $pinfo.UseShellExecute = $false
                $pinfo.CreateNoWindow = $true

                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $pinfo
                $proc.Start() | Out-Null
                $proc.WaitForExit(600000)
                return $proc.ExitCode
            } -ArgumentList $hpiaPath, $hpiaArgs -Credential $Credential -OperationName "install HP drivers"

            if ($result.Success) {
                if ($Log) { & $Log "  HPIA update completed" }
                [System.Windows.Forms.MessageBox]::Show("HP driver updates completed.`n`nA reboot may be required.", "Update Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
            else {
                if ($Log) { & $Log "  HPIA update failed: $($result.Error)" }
                [System.Windows.Forms.MessageBox]::Show("HP driver update failed.`n`n$($result.Error)", "Update Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            }
        }
        else {
            Start-Process -FilePath $hpiaPath -ArgumentList $hpiaArgs -Wait -NoNewWindow
            if ($Log) { & $Log "  HPIA update completed (non-elevated)" }
        }
    }
    catch {
        if ($Log) { & $Log "  HPIA update error: $($_.Exception.Message)" }
        [System.Windows.Forms.MessageBox]::Show("Error running HPIA: $($_.Exception.Message)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        if (Test-Path $reportPath) { Remove-Item $reportPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

#endregion

#region Script Blocks (defined first to avoid scope issues)

# Helper: Process a single folder for installer
$script:ProcessFolder = {
    param([System.IO.DirectoryInfo]$Folder)

    $configPath = Join-Path $Folder.FullName "install.json"
    $hasConfig = Test-Path $configPath

    if ($hasConfig) {
        # Load config file
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json

            # Find the installer file
            $installerFile = $null
            if ($config.installer) {
                $installerFile = Join-Path $Folder.FullName $config.installer
            } else {
                # Auto-detect installer
                $found = Get-ChildItem -Path $Folder.FullName -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.msi', '.exe' } |
                    Select-Object -First 1
                if ($found) { $installerFile = $found.FullName }
            }

            if ($installerFile -and (Test-Path $installerFile)) {
                $ext = [System.IO.Path]::GetExtension($installerFile)
                $isMsi = ($ext -eq '.msi')

                # Build values with proper conditionals
                $appName = if ($config.name) { $config.name } else { $Folder.Name }
                $appVersion = if ($config.version) { $config.version } else { "" }
                $appDesc = if ($config.description) { $config.description } else { "" }
                $defaultSilent = if ($isMsi) { "/qn /norestart" } else { "/S" }
                $defaultInteractive = if ($isMsi) { "/qb" } else { "" }
                $silentArgs = if ($config.silentArgs) { $config.silentArgs } else { $defaultSilent }
                $interactiveArgs = if ($config.interactiveArgs) { $config.interactiveArgs } else { $defaultInteractive }
                $requiresElev = if ($null -ne $config.requiresElevation) { $config.requiresElevation } else { $true }

                return @{
                    Name = $appName
                    Version = $appVersion
                    Description = $appDesc
                    InstallerPath = $installerFile
                    InstallerType = $ext
                    SilentArgs = $silentArgs
                    InteractiveArgs = $interactiveArgs
                    RequiresElevation = $requiresElev
                    HasConfig = $true
                    FolderPath = $Folder.FullName
                }
            }
        }
        catch {
            # Config parse failed, skip this folder
        }
    }
    else {
        # No config, look for installer file
        $installer = Get-ChildItem -Path $Folder.FullName -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.msi', '.exe' } |
            Select-Object -First 1

        if ($installer) {
            $isMsi = ($installer.Extension -eq '.msi')
            $silentArgs = if ($isMsi) { "/qn /norestart" } else { "/S" }
            $interactiveArgs = if ($isMsi) { "/qb" } else { "" }

            return @{
                Name = $Folder.Name
                Version = ""
                Description = ""
                InstallerPath = $installer.FullName
                InstallerType = $installer.Extension
                SilentArgs = $silentArgs
                InteractiveArgs = $interactiveArgs
                RequiresElevation = $true
                HasConfig = $false
                FolderPath = $Folder.FullName
            }
        }
    }

    return $null
}

# Scan directory for installable applications (recursive, up to 5 levels deep)
$script:ScanForApps = {
    param(
        [string]$Path,
        [System.Windows.Forms.TextBox]$LogBox = $null
    )

    $apps = @()

    # Helper to log messages
    $logMsg = {
        param([string]$Msg)
        if ($LogBox) {
            $ts = Get-Date -Format "HH:mm:ss"
            $LogBox.AppendText("[$ts]   $Msg`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    if (-not (Test-Path $Path)) {
        & $logMsg "ERROR: Path does not exist or is not accessible"
        return $apps
    }

    & $logMsg "Scanning root for standalone installers..."

    # Scan root level for standalone installers
    try {
        $rootInstallers = Get-ChildItem -Path $Path -File -ErrorAction Stop |
            Where-Object { $_.Extension -in '.msi', '.exe' }
        & $logMsg "Found $($rootInstallers.Count) standalone installer(s) in root"
    }
    catch {
        & $logMsg "ERROR reading root directory: $($_.Exception.Message)"
        $rootInstallers = @()
    }

    foreach ($installer in $rootInstallers) {
        # Determine args based on installer type
        $isMsi = ($installer.Extension -eq '.msi')
        $silentArgs = if ($isMsi) { "/qn /norestart" } else { "/S" }
        $interactiveArgs = if ($isMsi) { "/qb" } else { "" }

        $apps += @{
            Name = $installer.BaseName
            Version = ""
            Description = "(standalone installer)"
            InstallerPath = $installer.FullName
            InstallerType = $installer.Extension
            SilentArgs = $silentArgs
            InteractiveArgs = $interactiveArgs
            RequiresElevation = $true
            HasConfig = $false
            FolderPath = $null
        }
    }

    # Scan subfolders recursively (up to 3 levels deep for performance)
    # Note: Reduced from 5 to 3 levels to prevent UI freezing on large network shares
    & $logMsg "Scanning subfolders (recursive, up to 3 levels)..."
    & $logMsg "Please wait - enumerating directories..."
    try {
        # Use Get-ChildItem with -Recurse and -Depth for deep scanning
        $allFolders = Get-ChildItem -Path $Path -Directory -Recurse -Depth 3 -ErrorAction Stop
        & $logMsg "Found $($allFolders.Count) total subfolder(s) - now checking for installers..."
    }
    catch {
        & $logMsg "ERROR reading subdirectories: $($_.Exception.Message)"
        $allFolders = @()
    }

    # Process each folder for installers
    $foldersProcessed = 0
    $totalFolders = $allFolders.Count
    foreach ($folder in $allFolders) {
        $foldersProcessed++

        # Show progress every 25 folders OR for first 5 OR last few
        $showProgress = ($foldersProcessed -le 5) -or
                       ($foldersProcessed % 25 -eq 0) -or
                       ($foldersProcessed -ge ($totalFolders - 5))

        if ($showProgress) {
            $percentComplete = [Math]::Round(($foldersProcessed / $totalFolders) * 100, 0)
            & $logMsg "  Progress: $percentComplete% ($foldersProcessed / $totalFolders folders checked)"
        }

        $result = & $script:ProcessFolder -Folder $folder
        if ($result) {
            # Calculate relative path from root for better naming
            $relativePath = $folder.FullName.Replace($Path, "").TrimStart('\', '/')
            $pathParts = $relativePath -split '[\\/]' | Where-Object { $_ }

            # Use relative path for name (e.g., "Parent / Child / App")
            if ($pathParts.Count -gt 1) {
                $result.Name = ($pathParts -join " / ")
            }

            & $logMsg "    -> Found installer: $($result.Name)"
            $apps += $result
        }
    }

    & $logMsg "Scan complete. Total apps found: $($apps.Count)"
    return $apps
}

# Install an application
$script:InstallApp = {
    param(
        [hashtable]$App,
        [bool]$Silent,
        [System.Windows.Forms.TextBox]$LogBox
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Installing $($App.Name)...`r`n")
    $LogBox.ScrollToCaret()

    $localInstallerPath = $null
    $tempCopied = $false

    try {
        $installerPath = $App.InstallerPath

        # Check if path is on a network drive (mapped drive letter or UNC path)
        # Elevated sessions with alternate credentials don't have access to:
        # - UNC paths (\\server\share)
        # - Mapped drives (K:\ etc) - these are per-user session
        $needsCopy = $false
        if ($installerPath -like "\\*") {
            # UNC path - always needs copy
            $needsCopy = $true
        }
        elseif ($installerPath -match "^[A-Za-z]:") {
            # Drive letter - check if it's a network/mapped drive
            $driveLetter = $installerPath.Substring(0, 2)
            $logicalDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$driveLetter'" -ErrorAction SilentlyContinue
            if ($logicalDisk -and $logicalDisk.DriveType -eq 4) {
                # DriveType 4 = Network Drive
                $needsCopy = $true
            }
        }

        if ($needsCopy) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $LogBox.AppendText("[$timestamp] Source: $installerPath`r`n")
            $LogBox.AppendText("[$timestamp] Copying from network to local temp...`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()

            $tempDir = "C:\Temp\RushResolve_Install"
            $LogBox.AppendText("[$timestamp] Temp dir: $tempDir`r`n")
            [System.Windows.Forms.Application]::DoEvents()

            # Ensure C:\Temp exists first
            if (-not (Test-Path "C:\Temp")) {
                $LogBox.AppendText("[$timestamp] Creating C:\Temp...`r`n")
                New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
            }

            if (-not (Test-Path $tempDir)) {
                $LogBox.AppendText("[$timestamp] Creating $tempDir...`r`n")
                New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
            }

            # Verify folder exists
            if (Test-Path $tempDir) {
                $LogBox.AppendText("[$timestamp] Temp directory ready: $tempDir`r`n")
            }
            else {
                $LogBox.AppendText("[$timestamp] ERROR: Failed to create temp directory!`r`n")
                $LogBox.ScrollToCaret()
                return
            }

            $fileName = Split-Path $installerPath -Leaf
            $localInstallerPath = Join-Path $tempDir $fileName
            $LogBox.AppendText("[$timestamp] Destination: $localInstallerPath`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()

            # Get file size for progress reporting
            try {
                $sourceFile = Get-Item $installerPath -ErrorAction Stop
                $fileSizeMB = [math]::Round($sourceFile.Length / 1MB, 1)
                $LogBox.AppendText("[$timestamp] File size: $fileSizeMB MB`r`n")
            }
            catch {
                $LogBox.AppendText("[$timestamp] ERROR: Cannot access source file: $_`r`n")
                $LogBox.ScrollToCaret()
                return
            }
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()

            # Copy with progress using streams
            $sourceStream = $null
            $destStream = $null
            $copySuccess = $false
            try {
                $LogBox.AppendText("[$timestamp] Opening source stream...`r`n")
                [System.Windows.Forms.Application]::DoEvents()
                $sourceStream = [System.IO.File]::OpenRead($installerPath)

                $LogBox.AppendText("[$timestamp] Creating destination file...`r`n")
                [System.Windows.Forms.Application]::DoEvents()
                $destStream = [System.IO.File]::Create($localInstallerPath)

                $buffer = New-Object byte[] (1MB)
                $totalRead = 0
                $lastPercent = -1

                Start-AppActivity "Copying $fileName..."
                Set-AppProgress -Value 0 -Maximum 100

                # Add initial progress line that we'll update in place
                $LogBox.AppendText("[$timestamp] Copying: 0 / $fileSizeMB MB (0%)")
                $progressLineStart = $LogBox.Text.LastIndexOf("[$timestamp] Copying:")

                while (($bytesRead = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $destStream.Write($buffer, 0, $bytesRead)
                    $totalRead += $bytesRead
                    $percent = [math]::Floor(($totalRead / $sourceFile.Length) * 100)

                    if ($percent -ne $lastPercent) {
                        Set-AppProgress -Value $percent -Maximum 100
                        $copiedMB = [math]::Round($totalRead / 1MB, 1)

                        # Update the progress line in place
                        $newProgressText = "[$timestamp] Copying: $copiedMB / $fileSizeMB MB ($percent%)"
                        $LogBox.Select($progressLineStart, $LogBox.Text.Length - $progressLineStart)
                        $LogBox.SelectedText = $newProgressText
                        $LogBox.SelectionStart = $LogBox.Text.Length
                        $LogBox.ScrollToCaret()
                        [System.Windows.Forms.Application]::DoEvents()
                        $lastPercent = $percent
                    }
                }
                $copySuccess = $true
                $LogBox.AppendText("`r`n[$timestamp] Copy complete.`r`n")
                Clear-AppStatus
            }
            catch {
                $LogBox.AppendText("[$timestamp] ERROR during copy: $_`r`n")
                Clear-AppStatus
            }
            finally {
                if ($sourceStream) { $sourceStream.Close(); $sourceStream.Dispose() }
                if ($destStream) { $destStream.Close(); $destStream.Dispose() }
            }

            # Verify copy succeeded
            if (-not $copySuccess) {
                $LogBox.AppendText("[$timestamp] FAILED: Copy did not complete`r`n")
                $LogBox.ScrollToCaret()
                return
            }

            if (-not (Test-Path $localInstallerPath)) {
                $LogBox.AppendText("[$timestamp] FAILED: Copied file not found at $localInstallerPath`r`n")
                $LogBox.ScrollToCaret()
                return
            }

            $copiedFile = Get-Item $localInstallerPath
            $LogBox.AppendText("[$timestamp] Verified: Local file exists ($([math]::Round($copiedFile.Length / 1MB, 1)) MB)`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()

            $installerPath = $localInstallerPath
            $tempCopied = $true
        }

        $installArgs = if ($Silent) { $App.SilentArgs } else { $App.InteractiveArgs }
        $hideWindow = $Silent

        if ($App.InstallerType -eq '.msi') {
            # MSI installer - use msiexec
            $result = Start-ElevatedProcess -FilePath "msiexec.exe" `
                -ArgumentList "/i `"$installerPath`" $installArgs" `
                -Wait -Hidden:$hideWindow `
                -OperationName "install $($App.Name)"
        }
        else {
            # EXE installer - run directly
            $result = Start-ElevatedProcess -FilePath $installerPath `
                -ArgumentList $installArgs `
                -Wait -Hidden:$hideWindow `
                -OperationName "install $($App.Name)"
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        if ($result.Success) {
            $LogBox.AppendText("[$timestamp] SUCCESS: $($App.Name) installed (exit code: $($result.ExitCode))`r`n")
        }
        else {
            $LogBox.AppendText("[$timestamp] FAILED: $($App.Name) - $($result.Error)`r`n")
        }
    }
    catch {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $LogBox.AppendText("[$timestamp] ERROR: $($App.Name) - $_`r`n")
    }
    finally {
        # Clean up temp file if we copied it
        if ($tempCopied -and $localInstallerPath -and (Test-Path $localInstallerPath)) {
            try {
                Remove-Item -Path $localInstallerPath -Force -ErrorAction SilentlyContinue
            }
            catch { }
        }
    }

    $LogBox.ScrollToCaret()
}

# ==============================================================================
# WINGET FUNCTIONALITY DISABLED FOR STABLE BRANCH
# ==============================================================================
# WinGet (Windows Package Manager) is blocked in hospital environments.
# This functionality is preserved in comments for reference and is available
# in the development branch for environments that support WinGet.
#
# To re-enable in dev branch:
#  1. Uncomment the two script blocks below (ScanForUpdates and UpdateApp)
#  2. Uncomment the UI label at line ~1286
#  3. Uncomment the function calls at lines ~1378, ~1442, ~1479
# ==============================================================================

<#
# Scan for available updates using WinGet
$script:ScanForUpdates = {
    param(
        [System.Windows.Forms.TextBox]$LogBox = $null
    )

    $updates = @()

    $logMsg = {
        param([string]$Msg)
        if ($LogBox) {
            $ts = Get-Date -Format "HH:mm:ss"
            $LogBox.AppendText("[$ts]   $Msg`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    # Check if WinGet is available
    $wingetFound = $false
    $script:wingetPath = $null

    # Try Get-Command first (checks PATH)
    try {
        $script:wingetPath = (Get-Command winget -ErrorAction Stop).Source
        & $logMsg "Found WinGet at: $($script:wingetPath)"
        $wingetFound = $true
    }
    catch {
        # Try known location (WindowsApps folder)
        $knownPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
        if (Test-Path $knownPath) {
            $script:wingetPath = $knownPath
            & $logMsg "Found WinGet at: $($script:wingetPath)"
            $wingetFound = $true
        }
        else {
            & $logMsg "WinGet not found. Attempting to install from USB..."
        }
    }

    if (-not $wingetFound) {

        # Try to install from Tools/WinGet folder
        $installerPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Tools\WinGet\Install-WinGet.ps1"

        if (Test-Path $installerPath) {
            try {
                & $logMsg "Running WinGet installer..."
                $installOutput = & powershell -ExecutionPolicy Bypass -File $installerPath 2>&1

                # Log installer output
                foreach ($line in $installOutput) {
                    & $logMsg "  $line"
                }

                # Check if WinGet now available
                try {
                    $null = Get-Command winget -ErrorAction Stop
                    & $logMsg "WinGet installed successfully!"
                    $wingetFound = $true
                }
                catch {
                    & $logMsg "ERROR: WinGet installation completed but command not found."
                    & $logMsg "You may need to restart PowerShell. Close and reopen RushResolve."
                }
            }
            catch {
                & $logMsg "ERROR: WinGet installation failed: $($_.Exception.Message)"
            }
        }
        else {
            & $logMsg "ERROR: WinGet installer not found at Tools\WinGet\"
            & $logMsg "See Tools\WinGet\README.md for setup instructions."
        }
    }

    if (-not $wingetFound) {
        & $logMsg ""
        & $logMsg "Cannot scan for updates without WinGet."
        return $updates
    }

    & $logMsg "Scanning for available updates..."
    & $logMsg "This may take 30-60 seconds..."

    try {
        # Run winget upgrade and parse output
        $output = & $script:wingetPath upgrade --include-unknown 2>&1 | Out-String

        # Parse the table output
        $lines = $output -split "`n"
        $inTable = $false
        $headerProcessed = $false

        foreach ($line in $lines) {
            # Detect start of results table
            if ($line -match "^Name\s+Id\s+Version\s+Available") {
                $inTable = $true
                $headerProcessed = $true
                continue
            }

            # Detect separator line (dashes)
            if ($inTable -and $line -match "^-+") {
                continue
            }

            # Detect end of table
            if ($inTable -and ($line.Trim() -eq "" -or $line -match "^\d+ upgrades available")) {
                break
            }

            # Parse data rows
            if ($inTable -and $headerProcessed -and $line.Trim() -ne "") {
                # WinGet output format: Name  Id  Version  Available  Source
                # Use regex to extract fields (handles spaces in names)
                if ($line -match "^(.+?)\s{2,}([\w\.\-]+)\s+(\S+)\s+(\S+)\s*(\S*)") {
                    $name = $matches[1].Trim()
                    $id = $matches[2].Trim()
                    $currentVersion = $matches[3].Trim()
                    $availableVersion = $matches[4].Trim()
                    $source = if ($matches[5]) { $matches[5].Trim() } else { "winget" }

                    # Skip if versions are the same or unknown
                    if ($currentVersion -ne $availableVersion -and $currentVersion -ne "Unknown") {
                        $updates += @{
                            Name = $name
                            Id = $id
                            CurrentVersion = $currentVersion
                            AvailableVersion = $availableVersion
                            Source = $source
                        }
                    }
                }
            }
        }

        & $logMsg "Found $($updates.Count) application(s) with available updates"
    }
    catch {
        & $logMsg "ERROR scanning for updates: $_"
    }

    return $updates
}

# Update selected applications using WinGet
$script:UpdateApp = {
    param(
        [hashtable]$App,
        [System.Windows.Forms.TextBox]$LogBox
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Updating $($App.Name) ($($App.CurrentVersion) → $($App.AvailableVersion))...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # Run winget upgrade for this specific app
        $LogBox.AppendText("[$timestamp] Running: winget upgrade --id $($App.Id) --silent --accept-source-agreements --accept-package-agreements`r`n")
        $LogBox.ScrollToCaret()

        $result = & $script:wingetPath upgrade --id $App.Id --silent --accept-source-agreements --accept-package-agreements 2>&1

        $timestamp = Get-Date -Format "HH:mm:ss"

        # Check if successful (WinGet returns 0 on success)
        if ($LASTEXITCODE -eq 0) {
            $LogBox.AppendText("[$timestamp] SUCCESS: $($App.Name) updated to $($App.AvailableVersion)`r`n")
        }
        else {
            $LogBox.AppendText("[$timestamp] WARNING: Update completed with exit code $LASTEXITCODE`r`n")
            # Show relevant output lines
            $outputLines = $result | Select-Object -Last 5
            foreach ($line in $outputLines) {
                $LogBox.AppendText("    $line`r`n")
            }
        }
    }
    catch {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $LogBox.AppendText("[$timestamp] ERROR: $($App.Name) - $_`r`n")
    }

    $LogBox.AppendText("`r`n")
    $LogBox.ScrollToCaret()
}
#>

# WinGet functions above are commented out for stable branch
# Use manual installer scanning (folder browse) instead

# Query All Available GPO Software Packages from Active Directory
$script:QueryGPOSoftware = {
    param(
        [System.Windows.Forms.TextBox]$LogBox = $null,
        [System.Management.Automation.PSCredential]$Credential = $null
    )

    $packages = @()

    $logMsg = {
        param([string]$Msg)
        if ($LogBox) {
            $ts = Get-Date -Format "HH:mm:ss"
            $LogBox.AppendText("[$ts]   $Msg`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    & $logMsg "Querying Active Directory for all available GPO software packages..."
    if ($Credential) {
        & $logMsg "Using provided credentials: $($Credential.UserName)"
    }

    try {
        # Check if ActiveDirectory module is available
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            & $logMsg "ERROR: ActiveDirectory PowerShell module not installed"
            & $logMsg "This feature requires the Active Directory module."
            & $logMsg "Install with: Add-WindowsFeature RSAT-AD-PowerShell"
            return $packages
        }

        # Import AD module
        Import-Module ActiveDirectory -ErrorAction Stop

        # Get domain info
        & $logMsg "Connecting to Active Directory domain..."

        # Build AD cmdlet parameters with credentials if provided
        $adParams = @{}
        if ($Credential) {
            $adParams['Credential'] = $Credential
        }

        # Get all GPOs in the domain
        & $logMsg "Retrieving all Group Policy Objects..."
        $allGPOs = Get-GPO -All @adParams -ErrorAction Stop
        & $logMsg "Found $($allGPOs.Count) GPO(s) in domain"

        # Parse each GPO for software installation policies
        foreach ($gpo in $allGPOs) {
            try {
                & $logMsg "Scanning GPO: $($gpo.DisplayName)"

                # Get GPO report in XML format
                $gpoReport = Get-GPOReport -Guid $gpo.Id -ReportType Xml @adParams -ErrorAction Stop
                [xml]$xml = $gpoReport

                # Define namespace for GPO XML
                $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                $ns.AddNamespace("gpo", "http://www.microsoft.com/GroupPolicy/Settings")
                $ns.AddNamespace("q1", "http://www.microsoft.com/GroupPolicy/Settings/SoftwareInstallation")

                # Find software installation extensions
                $softwareNodes = $xml.SelectNodes("//q1:MsiApplication", $ns)

                if ($softwareNodes -and $softwareNodes.Count -gt 0) {
                    & $logMsg "  Found $($softwareNodes.Count) package(s) in this GPO"

                    foreach ($msi in $softwareNodes) {
                        $name = $msi.Name
                        $packagePath = $msi.Path
                        $deploymentType = $msi.DeploymentType  # "Assigned" or "Published"

                        if ($name -and $packagePath) {
                            # Check if we already have this package (avoid duplicates)
                            $exists = $packages | Where-Object { $_.Path -eq $packagePath }
                            if (-not $exists) {
                                $packages += @{
                                    Name = $name
                                    Path = $packagePath
                                    DeploymentType = $deploymentType
                                    GPOName = $gpo.DisplayName
                                    Source = "AD-GPO"
                                }
                                & $logMsg "    -> $name ($deploymentType)"
                            }
                        }
                    }
                }
            }
            catch {
                # Skip GPOs that fail to parse
                & $logMsg "  Warning: Could not parse GPO '$($gpo.DisplayName)': $($_.Exception.Message)"
            }
        }

        if ($packages.Count -eq 0) {
            & $logMsg ""
            & $logMsg "No software packages found in any GPO."
            & $logMsg "Possible reasons:"
            & $logMsg "  - No software deployment policies configured in domain GPOs"
            & $logMsg "  - Insufficient permissions to read GPO settings"
            & $logMsg "  - Software packages stored in different location"
        }
        else {
            & $logMsg ""
            & $logMsg "Total unique packages found: $($packages.Count)"
        }
    }
    catch {
        & $logMsg "ERROR querying Active Directory: $($_.Exception.Message)"
        & $logMsg "Make sure you have:"
        & $logMsg "  - Active Directory PowerShell module installed"
        & $logMsg "  - Network connectivity to domain controller"
        & $logMsg "  - Sufficient AD permissions (enterprise admin credentials)"
    }

    return $packages
}

# Install package from GPO network share
$script:InstallGPOPackage = {
    param(
        [hashtable]$Package,
        [System.Windows.Forms.TextBox]$LogBox
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Installing $($Package.Name) from GPO share...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $msiPath = $Package.Path

        # Verify network path accessible
        if (-not (Test-Path $msiPath)) {
            $LogBox.AppendText("[$timestamp] ERROR: Cannot access $msiPath`r`n")
            $LogBox.AppendText("[$timestamp] Check network connectivity and share permissions.`r`n")
            $LogBox.ScrollToCaret()
            return
        }

        $LogBox.AppendText("[$timestamp] Source: $msiPath`r`n")
        $LogBox.ScrollToCaret()

        # Create log path
        $logPath = "$env:TEMP\RushResolve_GPO_Install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

        # Build msiexec arguments
        $arguments = @(
            "/i"
            "`"$msiPath`""
            "/quiet"
            "/norestart"
            "/l*v"
            "`"$logPath`""
        )

        $LogBox.AppendText("[$timestamp] Running msiexec (silent install)...`r`n")
        $LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()

        # Run elevated install
        $result = Start-ElevatedProcess -FilePath "msiexec.exe" `
            -ArgumentList ($arguments -join " ") `
            -Wait -Hidden:$true `
            -OperationName "install $($Package.Name)"

        $timestamp = Get-Date -Format "HH:mm:ss"

        if ($result.Success) {
            if ($result.ExitCode -eq 0) {
                $LogBox.AppendText("[$timestamp] SUCCESS: $($Package.Name) installed`r`n")
                $LogBox.AppendText("[$timestamp] Log: $logPath`r`n")
            }
            elseif ($result.ExitCode -eq 3010) {
                $LogBox.AppendText("[$timestamp] SUCCESS: $($Package.Name) installed (reboot required)`r`n")
                $LogBox.AppendText("[$timestamp] Log: $logPath`r`n")
            }
            elseif ($result.ExitCode -eq 1641) {
                $LogBox.AppendText("[$timestamp] SUCCESS: $($Package.Name) installed (restart initiated)`r`n")
                $LogBox.AppendText("[$timestamp] Log: $logPath`r`n")
            }
            else {
                $LogBox.AppendText("[$timestamp] WARNING: Install completed with exit code $($result.ExitCode)`r`n")
                $LogBox.AppendText("[$timestamp] Log: $logPath`r`n")
            }
        }
        else {
            $LogBox.AppendText("[$timestamp] FAILED: $($Package.Name) - $($result.Error)`r`n")
            $LogBox.AppendText("[$timestamp] Log: $logPath`r`n")
        }
    }
    catch {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $LogBox.AppendText("[$timestamp] ERROR: $($Package.Name) - $_`r`n")
    }

    $LogBox.AppendText("`r`n")
    $LogBox.ScrollToCaret()
}

#endregion

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Store apps list at script level
    $script:AppsList = @()
    $script:UpdatesList = @()

    # Create TabControl to house Install and Updates tabs
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill

    # Tab 1: Install Software
    $installTab = New-Object System.Windows.Forms.TabPage
    $installTab.Text = "Install Software"
    $installTab.UseVisualStyleBackColor = $true
    $tabControl.TabPages.Add($installTab)

    # Tab 2: GPO Software Packages
    $gpoTab = New-Object System.Windows.Forms.TabPage
    $gpoTab.Text = "GPO Software Packages"
    $gpoTab.UseVisualStyleBackColor = $true
    $tabControl.TabPages.Add($gpoTab)

    # Tab 3: Check for Updates
    $updatesTab = New-Object System.Windows.Forms.TabPage
    $updatesTab.Text = "Check for Updates"
    $updatesTab.UseVisualStyleBackColor = $true
    $tabControl.TabPages.Add($updatesTab)

    #region Install Software Tab (existing functionality)

    # Main layout - TableLayoutPanel for structured layout
    $mainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.RowCount = 4
    $mainPanel.ColumnCount = 1
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 70))) | Out-Null
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null

    #region Row 0: Source Selection Bar
    $sourcePanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $sourcePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $sourcePanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $sourceLabel = New-Object System.Windows.Forms.Label
    $sourceLabel.Text = "Source:"
    $sourceLabel.AutoSize = $true
    $sourceLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $sourcePanel.Controls.Add($sourceLabel)

    $script:sourceCombo = New-Object System.Windows.Forms.ComboBox
    $script:sourceCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:sourceCombo.Width = 400
    $script:sourceCombo.Items.Add("Network Share (configure path)") | Out-Null
    $script:sourceCombo.Items.Add("Local/USB Directory") | Out-Null
    $script:sourceCombo.SelectedIndex = 1

    $sourcePanel.Controls.Add($script:sourceCombo)

    # Second row spacer (forces new line in FlowLayoutPanel)
    $pathRowSpacer = New-Object System.Windows.Forms.Label
    $pathRowSpacer.Text = ""
    $pathRowSpacer.Width = 2000
    $pathRowSpacer.Height = 1
    $sourcePanel.Controls.Add($pathRowSpacer)

    # Path input row
    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Text = "Path:"
    $pathLabel.AutoSize = $true
    $pathLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $sourcePanel.Controls.Add($pathLabel)

    $script:pathTextBox = New-Object System.Windows.Forms.TextBox
    $script:pathTextBox.Width = 500
    $script:pathTextBox.Height = 25
    $sourcePanel.Controls.Add($script:pathTextBox)

    $browseBtn = New-Object System.Windows.Forms.Button
    $browseBtn.Text = "Browse..."
    $browseBtn.Width = 75
    $browseBtn.Height = 30
    $sourcePanel.Controls.Add($browseBtn)

    $refreshBtn = New-Object System.Windows.Forms.Button
    $refreshBtn.Text = "Refresh"
    $refreshBtn.Width = 70
    $refreshBtn.Height = 30
    $sourcePanel.Controls.Add($refreshBtn)

    $mainPanel.Controls.Add($sourcePanel, 0, 0)
    #endregion

    #region Row 1: Application ListView
    $listGroup = New-Object System.Windows.Forms.GroupBox
    $listGroup.Text = "Available Applications"
    $listGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $listGroup.Padding = New-Object System.Windows.Forms.Padding(5)
    $listGroup.MinimumSize = New-Object System.Drawing.Size(400, 150)

    # Container for filter bar + listview (TableLayoutPanel for explicit sizing)
    $listContainer = New-Object System.Windows.Forms.TableLayoutPanel
    $listContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $listContainer.RowCount = 2
    $listContainer.ColumnCount = 1
    $listContainer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
    $listContainer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $listContainer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $listContainer.MinimumSize = New-Object System.Drawing.Size(380, 100)

    # Filter bar
    $filterPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $filterPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $filterPanel.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)

    $filterLabel = New-Object System.Windows.Forms.Label
    $filterLabel.Text = "Filter:"
    $filterLabel.AutoSize = $true
    $filterLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $filterPanel.Controls.Add($filterLabel)

    $script:installerFilterBox = New-Object System.Windows.Forms.TextBox
    $script:installerFilterBox.Width = 200
    $script:installerFilterBox.Height = 23
    $filterPanel.Controls.Add($script:installerFilterBox)

    $clearFilterBtn = New-Object System.Windows.Forms.Button
    $clearFilterBtn.Text = "X"
    $clearFilterBtn.Width = 25
    $clearFilterBtn.Height = 23
    $clearFilterBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $filterPanel.Controls.Add($clearFilterBtn)

    $script:filterCountLabel = New-Object System.Windows.Forms.Label
    $script:filterCountLabel.Text = ""
    $script:filterCountLabel.AutoSize = $true
    $script:filterCountLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:filterCountLabel.Padding = New-Object System.Windows.Forms.Padding(10, 5, 0, 0)
    $filterPanel.Controls.Add($script:filterCountLabel)

    $script:appListView = New-Object System.Windows.Forms.ListView
    $script:appListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:appListView.View = [System.Windows.Forms.View]::Details
    $script:appListView.CheckBoxes = $true
    $script:appListView.FullRowSelect = $true
    $script:appListView.GridLines = $true
    $script:appListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:appListView.MinimumSize = New-Object System.Drawing.Size(300, 150)

    $script:appListView.Columns.Add("Name", 200) | Out-Null
    $script:appListView.Columns.Add("Version", 80) | Out-Null
    $script:appListView.Columns.Add("Description", 250) | Out-Null
    $script:appListView.Columns.Add("Type", 60) | Out-Null
    $script:appListView.Columns.Add("Config", 50) | Out-Null

    # Track sort state
    $script:sortColumn = 0
    $script:sortAscending = $true

    # Column click sorting
    $script:appListView.Add_ColumnClick({
        param($sender, $e)
        $col = $e.Column

        # Toggle sort direction if same column
        if ($col -eq $script:sortColumn) {
            $script:sortAscending = -not $script:sortAscending
        } else {
            $script:sortColumn = $col
            $script:sortAscending = $true
        }

        # Sort items
        $items = @($script:appListView.Items | ForEach-Object { $_ })
        $sorted = $items | Sort-Object { $_.SubItems[$col].Text } -Descending:(-not $script:sortAscending)

        $script:appListView.BeginUpdate()
        $script:appListView.Items.Clear()
        foreach ($item in $sorted) {
            $script:appListView.Items.Add($item) | Out-Null
        }
        $script:appListView.EndUpdate()
    })

    # Filter textbox - filter as user types (inlined to avoid scriptblock issues)
    $script:installerFilterBox.Add_TextChanged({
        $filterText = $script:installerFilterBox.Text.Trim().ToLower()
        $script:appListView.BeginUpdate()
        $script:appListView.Items.Clear()

        $matchCount = 0
        foreach ($app in $script:AppsList) {
            $match = $true
            if ($filterText) {
                $match = ($app.Name -and $app.Name.ToLower().Contains($filterText)) -or
                         ($app.Version -and $app.Version.ToLower().Contains($filterText)) -or
                         ($app.Description -and $app.Description.ToLower().Contains($filterText))
            }
            if ($match) {
                $item = New-Object System.Windows.Forms.ListViewItem($app.Name)
                $item.SubItems.Add($app.Version) | Out-Null
                $item.SubItems.Add($app.Description) | Out-Null
                $typeText = if ($app.InstallerType) { $app.InstallerType.TrimStart('.').ToUpper() } else { "?" }
                $item.SubItems.Add($typeText) | Out-Null
                $configText = if ($app.HasConfig) { "Yes" } else { "No" }
                $item.SubItems.Add($configText) | Out-Null
                $item.Tag = $app
                $script:appListView.Items.Add($item) | Out-Null
                $matchCount++
            }
        }
        $script:appListView.EndUpdate()
        $script:appListView.Refresh()

        # Update count label
        $totalCount = $script:AppsList.Count
        if ($filterText) {
            $script:filterCountLabel.Text = "Showing $matchCount of $totalCount"
        } else {
            $script:filterCountLabel.Text = ""
        }
    })

    # Clear filter button
    $clearFilterBtn.Add_Click({
        $script:installerFilterBox.Text = ""
    })

    # Add controls to TableLayoutPanel (row 0 = filter, row 1 = listview)
    $listContainer.Controls.Add($filterPanel, 0, 0)
    $listContainer.Controls.Add($script:appListView, 0, 1)

    $listGroup.Controls.Add($listContainer)
    $mainPanel.Controls.Add($listGroup, 0, 1)
    #endregion

    #region Row 2: Action Buttons
    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $modeLabel = New-Object System.Windows.Forms.Label
    $modeLabel.Text = "Install Mode:"
    $modeLabel.AutoSize = $true
    $modeLabel.Padding = New-Object System.Windows.Forms.Padding(0, 8, 10, 0)
    $buttonPanel.Controls.Add($modeLabel)

    $script:silentRadio = New-Object System.Windows.Forms.RadioButton
    $script:silentRadio.Text = "Silent"
    $script:silentRadio.AutoSize = $true
    $script:silentRadio.Checked = $true
    $script:silentRadio.Padding = New-Object System.Windows.Forms.Padding(0, 5, 10, 0)
    $buttonPanel.Controls.Add($script:silentRadio)

    $script:interactiveRadio = New-Object System.Windows.Forms.RadioButton
    $script:interactiveRadio.Text = "Interactive"
    $script:interactiveRadio.AutoSize = $true
    $script:interactiveRadio.Padding = New-Object System.Windows.Forms.Padding(0, 5, 20, 0)
    $buttonPanel.Controls.Add($script:interactiveRadio)

    $sep = New-Object System.Windows.Forms.Label
    $sep.Text = "|"
    $sep.AutoSize = $true
    $sep.Padding = New-Object System.Windows.Forms.Padding(0, 8, 10, 0)
    $buttonPanel.Controls.Add($sep)

    $installBtn = New-Object System.Windows.Forms.Button
    $installBtn.Text = "Install Selected"
    $installBtn.Width = 135
    $installBtn.Height = 30
    $installBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 255, 230)
    $buttonPanel.Controls.Add($installBtn)

    $selectAllBtn = New-Object System.Windows.Forms.Button
    $selectAllBtn.Text = "Select All"
    $selectAllBtn.Width = 80
    $selectAllBtn.Height = 30
    $buttonPanel.Controls.Add($selectAllBtn)

    $clearSelBtn = New-Object System.Windows.Forms.Button
    $clearSelBtn.Text = "Clear"
    $clearSelBtn.Width = 60
    $clearSelBtn.Height = 30
    $buttonPanel.Controls.Add($clearSelBtn)

    $detailsBtn = New-Object System.Windows.Forms.Button
    $detailsBtn.Text = "View Details"
    $detailsBtn.Width = 90
    $detailsBtn.Height = 30
    $buttonPanel.Controls.Add($detailsBtn)

    # Installed Apps - opens ListView with all installed applications
    $installedAppsBtn = New-Object System.Windows.Forms.Button
    $installedAppsBtn.Text = "Installed Apps"
    $installedAppsBtn.Width = 95
    $installedAppsBtn.Height = 30
    $installedAppsBtn.Add_Click({
        # Create form
        $appForm = New-Object System.Windows.Forms.Form
        $appForm.Text = "Installed Applications"
        $appForm.Size = New-Object System.Drawing.Size(900, 600)
        $appForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $appForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

        # Top panel for filter
        $filterPanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $filterPanel.Dock = [System.Windows.Forms.DockStyle]::Top
        $filterPanel.Height = 35
        $filterPanel.Padding = New-Object System.Windows.Forms.Padding(5)

        $filterLabel = New-Object System.Windows.Forms.Label
        $filterLabel.Text = "Filter:"
        $filterLabel.AutoSize = $true
        $filterLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
        $filterPanel.Controls.Add($filterLabel)

        $filterBox = New-Object System.Windows.Forms.TextBox
        $filterBox.Width = 250
        $filterPanel.Controls.Add($filterBox)

        $clearBtn = New-Object System.Windows.Forms.Button
        $clearBtn.Text = "X"
        $clearBtn.Width = 25
        $clearBtn.Height = 23
        $clearBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $filterPanel.Controls.Add($clearBtn)

        $countLabel = New-Object System.Windows.Forms.Label
        $countLabel.Text = "Loading..."
        $countLabel.AutoSize = $true
        $countLabel.ForeColor = [System.Drawing.Color]::Gray
        $countLabel.Padding = New-Object System.Windows.Forms.Padding(15, 5, 0, 0)
        $filterPanel.Controls.Add($countLabel)

        # ListView
        $appListView = New-Object System.Windows.Forms.ListView
        $appListView.Dock = [System.Windows.Forms.DockStyle]::Fill
        $appListView.View = [System.Windows.Forms.View]::Details
        $appListView.FullRowSelect = $true
        $appListView.GridLines = $true
        $appListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

        $appListView.Columns.Add("Name", 300) | Out-Null
        $appListView.Columns.Add("Version", 120) | Out-Null
        $appListView.Columns.Add("Publisher", 200) | Out-Null
        $appListView.Columns.Add("Install Date", 100) | Out-Null

        # Store full app list
        $script:allApps = @()
        $sortCol = 0
        $sortAsc = $true

        # Column click sorting
        $appListView.Add_ColumnClick({
            param($s, $e)
            $col = $e.Column
            if ($col -eq $sortCol) { $sortAsc = -not $sortAsc } else { $sortCol = $col; $sortAsc = $true }
            $items = @($appListView.Items | ForEach-Object { $_ })
            $sorted = $items | Sort-Object { $_.SubItems[$col].Text } -Descending:(-not $sortAsc)
            $appListView.BeginUpdate()
            $appListView.Items.Clear()
            foreach ($item in $sorted) { $appListView.Items.Add($item) | Out-Null }
            $appListView.EndUpdate()
        })

        # Apply filter function
        $applyFilter = {
            param($apps, $filterText)
            $appListView.BeginUpdate()
            $appListView.Items.Clear()
            $matchCount = 0
            foreach ($app in $apps) {
                $match = $true
                if ($filterText) {
                    $match = $app.Name.ToLower().Contains($filterText.ToLower()) -or
                             ($app.Publisher -and $app.Publisher.ToLower().Contains($filterText.ToLower()))
                }
                if ($match) {
                    $item = New-Object System.Windows.Forms.ListViewItem($app.Name)
                    $item.SubItems.Add($app.Version) | Out-Null
                    $item.SubItems.Add($app.Publisher) | Out-Null
                    $item.SubItems.Add($app.InstallDate) | Out-Null
                    $appListView.Items.Add($item) | Out-Null
                    $matchCount++
                }
            }
            $appListView.EndUpdate()
            if ($filterText) { $countLabel.Text = "Showing $matchCount of $($apps.Count)" }
            else { $countLabel.Text = "$($apps.Count) applications" }
        }

        $filterBox.Add_TextChanged({
            & $applyFilter $script:allApps $filterBox.Text
        }.GetNewClosure())

        $clearBtn.Add_Click({
            $filterBox.Text = ""
        })

        $appForm.Controls.Add($appListView)
        $appForm.Controls.Add($filterPanel)

        # Load apps on form shown
        $appForm.Add_Shown({
            [System.Windows.Forms.Application]::DoEvents()
            $countLabel.Text = "Loading..."
            [System.Windows.Forms.Application]::DoEvents()

            # Get installed apps from registry (both 32 and 64 bit)
            $apps = @()
            $regPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
            )
            foreach ($path in $regPaths) {
                $items = Get-ItemProperty $path -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -and $_.DisplayName.Trim() }
                foreach ($item in $items) {
                    $installDate = ""
                    if ($item.InstallDate) {
                        try {
                            $d = [datetime]::ParseExact($item.InstallDate, "yyyyMMdd", $null)
                            $installDate = $d.ToString("yyyy-MM-dd")
                        } catch { $installDate = $item.InstallDate }
                    }
                    $apps += [PSCustomObject]@{
                        Name = $item.DisplayName.Trim()
                        Version = if ($item.DisplayVersion) { $item.DisplayVersion } else { "" }
                        Publisher = if ($item.Publisher) { $item.Publisher } else { "" }
                        InstallDate = $installDate
                    }
                }
            }
            # Remove duplicates by Name+Version
            $script:allApps = $apps | Sort-Object Name, Version -Unique
            & $applyFilter $script:allApps ""
        }.GetNewClosure())

        $appForm.ShowDialog() | Out-Null
    })
    $buttonPanel.Controls.Add($installedAppsBtn)

    $mainPanel.Controls.Add($buttonPanel, 0, 2)
    #endregion

    #region Row 3: Log Output
    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = "Installation Log"
    $logGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:installerLogBox = New-Object System.Windows.Forms.TextBox
    $script:installerLogBox.Multiline = $true
    $script:installerLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:installerLogBox.ReadOnly = $true
    $script:installerLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:installerLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:installerLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:installerLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $logGroup.Controls.Add($script:installerLogBox)
    $mainPanel.Controls.Add($logGroup, 0, 3)
    #endregion

    #region Event Handlers

    # Current path tracker
    $script:currentPath = ""
    $script:networkPath = Get-ModuleSetting -ModuleName "SoftwareInstaller" -Key "networkPath" -Default ""
    $script:localPath = Get-ModuleSetting -ModuleName "SoftwareInstaller" -Key "localPath" -Default ""

    # Function to refresh app list (uses $script: scoped variables)
    $script:RefreshAppList = {
        $script:appListView.Items.Clear()
        $script:AppsList = @()

        # Read path from textbox
        $path = $script:pathTextBox.Text.Trim()
        $script:currentPath = $path

        if (-not $path -or -not (Test-Path $path)) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:installerLogBox.AppendText("[$timestamp] Invalid path: $path`r`n")
            $script:installerLogBox.AppendText("[$timestamp] Enter a valid local or network path (e.g., C:\Installers or \\server\share)`r`n")
            Set-AppError "Invalid path: $path"
            return
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:installerLogBox.AppendText("[$timestamp] Scanning: $path`r`n")
        Start-AppActivity "Scanning for installers..."

        $apps = & $script:ScanForApps -Path $path -LogBox $script:installerLogBox
        $script:AppsList = $apps
        Clear-AppStatus

        # Populate ListView directly (inlined to avoid scriptblock issues)
        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:installerLogBox.AppendText("[$timestamp] Populating ListView...`r`n")

        $filterText = $script:installerFilterBox.Text.Trim().ToLower()
        $script:appListView.BeginUpdate()
        $script:appListView.Items.Clear()

        $matchCount = 0
        foreach ($app in $script:AppsList) {
            $match = $true
            if ($filterText) {
                $match = ($app.Name -and $app.Name.ToLower().Contains($filterText)) -or
                         ($app.Version -and $app.Version.ToLower().Contains($filterText)) -or
                         ($app.Description -and $app.Description.ToLower().Contains($filterText))
            }
            if ($match) {
                $item = New-Object System.Windows.Forms.ListViewItem($app.Name)
                $item.SubItems.Add($app.Version) | Out-Null
                $item.SubItems.Add($app.Description) | Out-Null
                $typeText = if ($app.InstallerType) { $app.InstallerType.TrimStart('.').ToUpper() } else { "?" }
                $item.SubItems.Add($typeText) | Out-Null
                $configText = if ($app.HasConfig) { "Yes" } else { "No" }
                $item.SubItems.Add($configText) | Out-Null
                $item.Tag = $app
                $script:appListView.Items.Add($item) | Out-Null
                $matchCount++
            }
        }
        $script:appListView.EndUpdate()
        $script:appListView.Refresh()

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:installerLogBox.AppendText("[$timestamp] Found $($apps.Count) application(s)`r`n")
        $script:installerLogBox.ScrollToCaret()
    }

    # Browse button - no closure, use $script: vars directly
    $browseBtn.Add_Click({
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select installer directory"
        $folderBrowser.ShowNewFolderButton = $false

        if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:pathTextBox.Text = $folderBrowser.SelectedPath
            $script:currentPath = $folderBrowser.SelectedPath

            # Save to settings based on current source type
            if ($script:sourceCombo.SelectedIndex -eq 0) {
                $script:networkPath = $script:currentPath
                Set-ModuleSetting -ModuleName "SoftwareInstaller" -Key "networkPath" -Value $script:currentPath
            }
            else {
                $script:localPath = $script:currentPath
                Set-ModuleSetting -ModuleName "SoftwareInstaller" -Key "localPath" -Value $script:currentPath
            }

            & $script:RefreshAppList
        }
    })

    # Refresh button
    $refreshBtn.Add_Click({
        & $script:RefreshAppList
    })

    # Source combo change - update textbox with saved path
    $script:sourceCombo.Add_SelectedIndexChanged({
        if ($script:sourceCombo.SelectedIndex -eq 0) {
            $script:pathTextBox.Text = $script:networkPath
            $script:currentPath = $script:networkPath
        }
        else {
            $script:pathTextBox.Text = $script:localPath
            $script:currentPath = $script:localPath
        }
        & $script:RefreshAppList
    })

    # Enter key in path textbox triggers refresh
    $script:pathTextBox.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            & $script:RefreshAppList
        }
    })

    # Install button
    $installBtn.Add_Click({
        $selectedItems = @()
        foreach ($item in $script:appListView.CheckedItems) {
            $selectedItems += $item.Tag
        }

        if ($selectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please select at least one application to install.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $silent = $script:silentRadio.Checked
        $modeText = if ($silent) { "silent" } else { "interactive" }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Install $($selectedItems.Count) application(s) in $modeText mode?",
            "Confirm Installation",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $total = $selectedItems.Count
            $current = 0

            foreach ($app in $selectedItems) {
                $current++
                Set-AppProgress -Value $current -Maximum $total -Message "Installing $current of $total`: $($app.Name)"
                & $script:InstallApp -App $app -Silent $silent -LogBox $script:installerLogBox
            }

            Clear-AppStatus
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:installerLogBox.AppendText("[$timestamp] --- Installation batch complete ---`r`n")
            $script:installerLogBox.ScrollToCaret()
        }
    })

    # Select All button
    $selectAllBtn.Add_Click({
        foreach ($item in $script:appListView.Items) {
            $item.Checked = $true
        }
    })

    # Clear Selection button
    $clearSelBtn.Add_Click({
        foreach ($item in $script:appListView.Items) {
            $item.Checked = $false
        }
    })

    # View Details button
    $detailsBtn.Add_Click({
        if ($script:appListView.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please select an application to view details.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        $app = $script:appListView.SelectedItems[0].Tag

        $versionText = if ($app.Version) { $app.Version } else { "(not specified)" }
        $descText = if ($app.Description) { $app.Description } else { "(none)" }
        $interactiveText = if ($app.InteractiveArgs) { $app.InteractiveArgs } else { "(none)" }
        $hasConfigText = if ($app.HasConfig) { "Yes" } else { "No" }
        $elevText = if ($app.RequiresElevation) { "Yes" } else { "No" }
        $typeText = $app.InstallerType.TrimStart('.').ToUpper()

        $details = @"
Application Details
====================

Name:           $($app.Name)
Version:        $versionText
Description:    $descText

Installer:      $($app.InstallerPath)
Type:           $typeText
Has Config:     $hasConfigText

Silent Args:    $($app.SilentArgs)
Interactive:    $interactiveText

Requires Elevation: $elevText
"@

        [System.Windows.Forms.MessageBox]::Show(
            $details,
            "Application Details - $($app.Name)",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })

    #endregion

    $installTab.Controls.Add($mainPanel)

    # Initialize textbox with saved path (Local/USB is default, index 1)
    $script:pathTextBox.Text = $script:localPath
    $script:currentPath = $script:localPath

    # Initial log message
    $timestamp = Get-Date -Format "HH:mm:ss"
    $script:installerLogBox.AppendText("[$timestamp] Software Installer ready.`r`n")

    # Auto-load if path exists
    if ($script:currentPath -and (Test-Path $script:currentPath -ErrorAction SilentlyContinue)) {
        & $script:RefreshAppList
    }
    else {
        $script:installerLogBox.AppendText("[$timestamp] Enter a path or Browse, then click Refresh.`r`n")
    }

    #endregion Install Software Tab

    #region GPO Software Packages Tab

    $script:GPOPackagesList = @()

    # GPO panel layout
    $gpoPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $gpoPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $gpoPanel.RowCount = 4
    $gpoPanel.ColumnCount = 1
    $gpoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 80))) | Out-Null
    $gpoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null
    $gpoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
    $gpoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null

    # Row 0: Info and Query button
    $gpoHeaderPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $gpoHeaderPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $gpoHeaderPanel.Padding = New-Object System.Windows.Forms.Padding(5)
    $gpoHeaderPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown

    $gpoInfoLabel = New-Object System.Windows.Forms.Label
    $gpoInfoLabel.Text = "Query all software packages available in Active Directory Group Policies"
    $gpoInfoLabel.AutoSize = $true
    $gpoInfoLabel.ForeColor = [System.Drawing.Color]::Gray
    $gpoHeaderPanel.Controls.Add($gpoInfoLabel)

    $gpoButtonRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $gpoButtonRow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $gpoButtonRow.AutoSize = $true

    $queryGPOBtn = New-Object System.Windows.Forms.Button
    $queryGPOBtn.Text = "Query GPO Packages"
    $queryGPOBtn.Width = 150
    $queryGPOBtn.Height = 35
    $queryGPOBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 240, 255)
    $gpoButtonRow.Controls.Add($queryGPOBtn)

    $credentialBtn = New-Object System.Windows.Forms.Button
    $credentialBtn.Text = "Set Credentials..."
    $credentialBtn.Width = 120
    $credentialBtn.Height = 35
    $gpoButtonRow.Controls.Add($credentialBtn)

    $forceGPOBtn = New-Object System.Windows.Forms.Button
    $forceGPOBtn.Text = "Force GPO Update"
    $forceGPOBtn.Width = 140
    $forceGPOBtn.Height = 35
    $forceGPOBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    $gpoButtonRow.Controls.Add($forceGPOBtn)

    # Store credentials at script level
    $script:GPOCredential = $null
    $script:credentialLabel = New-Object System.Windows.Forms.Label
    $script:credentialLabel.Text = "Using current user credentials"
    $script:credentialLabel.AutoSize = $true
    $script:credentialLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:credentialLabel.Padding = New-Object System.Windows.Forms.Padding(5, 8, 0, 0)
    $gpoButtonRow.Controls.Add($script:credentialLabel)

    $gpoHeaderPanel.Controls.Add($gpoButtonRow)
    $gpoPanel.Controls.Add($gpoHeaderPanel, 0, 0)

    # Row 1: GPO Packages ListView
    $gpoListGroup = New-Object System.Windows.Forms.GroupBox
    $gpoListGroup.Text = "GPO Software Packages"
    $gpoListGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $gpoListGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:gpoListView = New-Object System.Windows.Forms.ListView
    $script:gpoListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:gpoListView.View = [System.Windows.Forms.View]::Details
    $script:gpoListView.CheckBoxes = $true
    $script:gpoListView.FullRowSelect = $true
    $script:gpoListView.GridLines = $true
    $script:gpoListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:gpoListView.Columns.Add("Package Name", 250) | Out-Null
    $script:gpoListView.Columns.Add("Deployment", 100) | Out-Null
    $script:gpoListView.Columns.Add("GPO Name", 200) | Out-Null
    $script:gpoListView.Columns.Add("Network Path", 300) | Out-Null

    $gpoListGroup.Controls.Add($script:gpoListView)
    $gpoPanel.Controls.Add($gpoListGroup, 0, 1)

    # Row 2: Action buttons
    $gpoActionPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $gpoActionPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $gpoActionPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $installGPOBtn = New-Object System.Windows.Forms.Button
    $installGPOBtn.Text = "Install Selected"
    $installGPOBtn.Width = 135
    $installGPOBtn.Height = 30
    $installGPOBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 255, 230)
    $gpoActionPanel.Controls.Add($installGPOBtn)

    $selectAllGPOBtn = New-Object System.Windows.Forms.Button
    $selectAllGPOBtn.Text = "Select All"
    $selectAllGPOBtn.Width = 80
    $selectAllGPOBtn.Height = 30
    $gpoActionPanel.Controls.Add($selectAllGPOBtn)

    $clearGPOBtn = New-Object System.Windows.Forms.Button
    $clearGPOBtn.Text = "Clear"
    $clearGPOBtn.Width = 60
    $clearGPOBtn.Height = 30
    $gpoActionPanel.Controls.Add($clearGPOBtn)

    $gpoPanel.Controls.Add($gpoActionPanel, 0, 2)

    # Row 3: GPO log
    $gpoLogGroup = New-Object System.Windows.Forms.GroupBox
    $gpoLogGroup.Text = "GPO Log"
    $gpoLogGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $gpoLogGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:gpoLogBox = New-Object System.Windows.Forms.TextBox
    $script:gpoLogBox.Multiline = $true
    $script:gpoLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:gpoLogBox.ReadOnly = $true
    $script:gpoLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:gpoLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:gpoLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:gpoLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $gpoLogGroup.Controls.Add($script:gpoLogBox)
    $gpoPanel.Controls.Add($gpoLogGroup, 0, 3)

    # Event handlers for GPO tab

    # Credential button
    $credentialBtn.Add_Click({
        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:gpoLogBox.AppendText("[$timestamp] Prompting for enterprise admin credentials...`r`n")

        # Use the credential wrapper from main script
        $cred = Get-ElevatedCredential -Message "Enter enterprise admin credentials for GPO query"

        if ($cred) {
            $script:GPOCredential = $cred
            $script:credentialLabel.Text = "Using: $($cred.UserName)"
            $script:credentialLabel.ForeColor = [System.Drawing.Color]::Green
            $script:gpoLogBox.AppendText("[$timestamp] Credentials set: $($cred.UserName)`r`n")
        }
        else {
            $script:gpoLogBox.AppendText("[$timestamp] Credential prompt cancelled`r`n")
        }
        $script:gpoLogBox.ScrollToCaret()
    })

    # Query GPO button
    $queryGPOBtn.Add_Click({
        $script:gpoListView.Items.Clear()
        $script:GPOPackagesList = @()

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:gpoLogBox.AppendText("[$timestamp] Querying Group Policy software assignments...`r`n")
        Start-AppActivity "Querying GPO..."

        $packages = & $script:QueryGPOSoftware -LogBox $script:gpoLogBox -Credential $script:GPOCredential
        $script:GPOPackagesList = $packages
        Clear-AppStatus

        # Populate ListView
        foreach ($pkg in $packages) {
            $item = New-Object System.Windows.Forms.ListViewItem($pkg.Name)
            $item.SubItems.Add($pkg.DeploymentType) | Out-Null
            $item.SubItems.Add($pkg.GPOName) | Out-Null
            $item.SubItems.Add($pkg.Path) | Out-Null
            $item.Tag = $pkg
            $script:gpoListView.Items.Add($item) | Out-Null
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:gpoLogBox.AppendText("[$timestamp] Query complete. Found $($packages.Count) package(s).`r`n")
        $script:gpoLogBox.ScrollToCaret()
    })

    # Force GPO Update button
    $forceGPOBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Force Group Policy update?`n`nThis will apply all GPO settings immediately, including software installations assigned via GPO.`n`nThis may take several minutes.",
            "Force GPO Update",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:gpoLogBox.AppendText("[$timestamp] Running gpupdate /force...`r`n")
            $script:gpoLogBox.ScrollToCaret()
            Start-AppActivity "Running GPO update..."

            try {
                # Run gpupdate with timeout
                $result = Start-Process -FilePath "gpupdate.exe" -ArgumentList "/force", "/target:computer", "/wait:0" -Wait -PassThru -NoNewWindow

                $timestamp = Get-Date -Format "HH:mm:ss"

                if ($result.ExitCode -eq 0) {
                    $script:gpoLogBox.AppendText("[$timestamp] SUCCESS: Group Policy updated`r`n")
                    $script:gpoLogBox.AppendText("[$timestamp] Software installations should apply shortly.`r`n")
                }
                else {
                    $script:gpoLogBox.AppendText("[$timestamp] WARNING: gpupdate completed with exit code $($result.ExitCode)`r`n")
                }
            }
            catch {
                $timestamp = Get-Date -Format "HH:mm:ss"
                $script:gpoLogBox.AppendText("[$timestamp] ERROR: $_`r`n")
            }

            Clear-AppStatus
            $script:gpoLogBox.ScrollToCaret()
        }
    })

    # Install Selected button
    $installGPOBtn.Add_Click({
        $selectedItems = @()
        foreach ($item in $script:gpoListView.CheckedItems) {
            $selectedItems += $item.Tag
        }

        if ($selectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please select at least one package to install.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Install $($selectedItems.Count) package(s) directly from GPO network share?`n`nThis bypasses GPO deployment but uses the same approved packages.",
            "Confirm GPO Install",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $total = $selectedItems.Count
            $current = 0

            foreach ($pkg in $selectedItems) {
                $current++
                Set-AppProgress -Value $current -Maximum $total -Message "Installing $current of $total`: $($pkg.Name)"
                & $script:InstallGPOPackage -Package $pkg -LogBox $script:gpoLogBox
            }

            Clear-AppStatus
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:gpoLogBox.AppendText("[$timestamp] --- Installation batch complete ---`r`n")
            $script:gpoLogBox.AppendText("[$timestamp] Click 'Query GPO Packages' to refresh status.`r`n")
            $script:gpoLogBox.ScrollToCaret()
        }
    })

    # Select All button
    $selectAllGPOBtn.Add_Click({
        foreach ($item in $script:gpoListView.Items) {
            $item.Checked = $true
        }
    })

    # Clear button
    $clearGPOBtn.Add_Click({
        foreach ($item in $script:gpoListView.Items) {
            $item.Checked = $false
        }
    })

    $gpoTab.Controls.Add($gpoPanel)

    # Initial log
    $timestamp = Get-Date -Format "HH:mm:ss"
    $script:gpoLogBox.AppendText("[$timestamp] GPO Software Packages ready.`r`n")
    $script:gpoLogBox.AppendText("[$timestamp] Click 'Set Credentials...' to provide enterprise admin credentials.`r`n")
    $script:gpoLogBox.AppendText("[$timestamp] Click 'Query GPO Packages' to scan all software in Active Directory GPOs.`r`n")
    $script:gpoLogBox.AppendText("[$timestamp]`r`n")
    $script:gpoLogBox.AppendText("[$timestamp] NOTE: This feature queries ALL software packages in AD GPOs.`r`n")
    $script:gpoLogBox.AppendText("[$timestamp] You can install any RUSH-approved package from the catalog.`r`n")

    #endregion GPO Software Packages Tab

    #region Check for Updates Tab

    # Updates panel layout
    $updatesPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $updatesPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $updatesPanel.RowCount = 4
    $updatesPanel.ColumnCount = 1
    $updatesPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
    $updatesPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null
    $updatesPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
    $updatesPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null

    # Row 0: Scan button
    $scanPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $scanPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $scanPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $scanBtn = New-Object System.Windows.Forms.Button
    $scanBtn.Text = "Check for Updates"
    $scanBtn.Width = 150
    $scanBtn.Height = 35
    $scanBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 240, 255)
    $scanPanel.Controls.Add($scanBtn)

    $scanInfoLabel = New-Object System.Windows.Forms.Label
    # WinGet disabled for stable branch - hospital environment blocks it
    # $scanInfoLabel.Text = "Scan for application updates using Windows Package Manager (WinGet)"
    $scanInfoLabel.Text = "Note: Automatic updates disabled. Use manual installer scanning (Browse Folder tab)"
    $scanInfoLabel.AutoSize = $true
    $scanInfoLabel.Padding = New-Object System.Windows.Forms.Padding(10, 10, 0, 0)
    $scanInfoLabel.ForeColor = [System.Drawing.Color]::Gray
    $scanPanel.Controls.Add($scanInfoLabel)

    $updatesPanel.Controls.Add($scanPanel, 0, 0)

    # Row 1: Updates ListView
    $updatesListGroup = New-Object System.Windows.Forms.GroupBox
    $updatesListGroup.Text = "Available Updates"
    $updatesListGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $updatesListGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:updatesListView = New-Object System.Windows.Forms.ListView
    $script:updatesListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:updatesListView.View = [System.Windows.Forms.View]::Details
    $script:updatesListView.CheckBoxes = $true
    $script:updatesListView.FullRowSelect = $true
    $script:updatesListView.GridLines = $true
    $script:updatesListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:updatesListView.Columns.Add("Application", 250) | Out-Null
    $script:updatesListView.Columns.Add("Current Version", 120) | Out-Null
    $script:updatesListView.Columns.Add("Available Version", 120) | Out-Null
    $script:updatesListView.Columns.Add("Source", 80) | Out-Null

    $updatesListGroup.Controls.Add($script:updatesListView)
    $updatesPanel.Controls.Add($updatesListGroup, 0, 1)

    # Row 2: Action buttons
    $updateButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $updateButtonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $updateButtonPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $updateSelectedBtn = New-Object System.Windows.Forms.Button
    $updateSelectedBtn.Text = "Update Selected"
    $updateSelectedBtn.Width = 135
    $updateSelectedBtn.Height = 30
    $updateSelectedBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 255, 230)
    $updateButtonPanel.Controls.Add($updateSelectedBtn)

    $updateAllBtn = New-Object System.Windows.Forms.Button
    $updateAllBtn.Text = "Update All"
    $updateAllBtn.Width = 100
    $updateAllBtn.Height = 30
    $updateAllBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    $updateButtonPanel.Controls.Add($updateAllBtn)

    $selectAllUpdatesBtn = New-Object System.Windows.Forms.Button
    $selectAllUpdatesBtn.Text = "Select All"
    $selectAllUpdatesBtn.Width = 80
    $selectAllUpdatesBtn.Height = 30
    $updateButtonPanel.Controls.Add($selectAllUpdatesBtn)

    $clearUpdatesBtn = New-Object System.Windows.Forms.Button
    $clearUpdatesBtn.Text = "Clear"
    $clearUpdatesBtn.Width = 60
    $clearUpdatesBtn.Height = 30
    $updateButtonPanel.Controls.Add($clearUpdatesBtn)

    $updatesPanel.Controls.Add($updateButtonPanel, 0, 2)

    # Row 3: Update log
    $updateLogGroup = New-Object System.Windows.Forms.GroupBox
    $updateLogGroup.Text = "Update Log"
    $updateLogGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $updateLogGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:updateLogBox = New-Object System.Windows.Forms.TextBox
    $script:updateLogBox.Multiline = $true
    $script:updateLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:updateLogBox.ReadOnly = $true
    $script:updateLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:updateLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:updateLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:updateLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $updateLogGroup.Controls.Add($script:updateLogBox)
    $updatesPanel.Controls.Add($updateLogGroup, 0, 3)

    # Event handlers for Updates tab

    # Scan button
    $scanBtn.Add_Click({
        $script:updatesListView.Items.Clear()
        $script:UpdatesList = @()

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:updateLogBox.AppendText("[$timestamp] Checking for updates...`r`n")
        Start-AppActivity "Scanning for updates..."

        # WinGet disabled for stable branch
        # $updates = & $script:ScanForUpdates -LogBox $script:updateLogBox
        $updates = @()
        $script:updateLogBox.AppendText("[$timestamp] WinGet updates disabled for stable branch`r`n")
        $script:updateLogBox.AppendText("[$timestamp] Use 'Browse Folder' tab to install software manually`r`n")
        $script:UpdatesList = $updates
        Clear-AppStatus

        # Populate ListView
        foreach ($update in $updates) {
            $item = New-Object System.Windows.Forms.ListViewItem($update.Name)
            $item.SubItems.Add($update.CurrentVersion) | Out-Null
            $item.SubItems.Add($update.AvailableVersion) | Out-Null
            $item.SubItems.Add($update.Source) | Out-Null
            $item.Tag = $update
            $script:updatesListView.Items.Add($item) | Out-Null
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:updateLogBox.AppendText("[$timestamp] Scan complete. Found $($updates.Count) update(s).`r`n")
        $script:updateLogBox.ScrollToCaret()
    })

    # Select All button
    $selectAllUpdatesBtn.Add_Click({
        foreach ($item in $script:updatesListView.Items) {
            $item.Checked = $true
        }
    })

    # Clear button
    $clearUpdatesBtn.Add_Click({
        foreach ($item in $script:updatesListView.Items) {
            $item.Checked = $false
        }
    })

    # Update Selected button
    $updateSelectedBtn.Add_Click({
        $selectedItems = @()
        foreach ($item in $script:updatesListView.CheckedItems) {
            $selectedItems += $item.Tag
        }

        if ($selectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please select at least one application to update.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Update $($selectedItems.Count) application(s)?`n`nThis will download and install updates in the background.",
            "Confirm Updates",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $total = $selectedItems.Count
            $current = 0

            foreach ($app in $selectedItems) {
                $current++
                Set-AppProgress -Value $current -Maximum $total -Message "Updating $current of $total`: $($app.Name)"
                # WinGet disabled for stable branch
                # & $script:UpdateApp -App $app -LogBox $script:updateLogBox
                $timestamp = Get-Date -Format "HH:mm:ss"
                $script:updateLogBox.AppendText("[$timestamp] WinGet updates disabled - cannot update $($app.Name)`r`n")
            }

            Clear-AppStatus
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:updateLogBox.AppendText("[$timestamp] --- Update batch complete ---`r`n")
            $script:updateLogBox.AppendText("[$timestamp] Click 'Check for Updates' to refresh the list.`r`n")
            $script:updateLogBox.ScrollToCaret()
        }
    })

    # Update All button
    $updateAllBtn.Add_Click({
        if ($script:UpdatesList.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "No updates available. Click 'Check for Updates' first.",
                "No Updates",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Update all $($script:UpdatesList.Count) application(s)?`n`nThis will download and install all available updates.",
            "Confirm Update All",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $total = $script:UpdatesList.Count
            $current = 0

            foreach ($app in $script:UpdatesList) {
                $current++
                Set-AppProgress -Value $current -Maximum $total -Message "Updating $current of $total`: $($app.Name)"
                # WinGet disabled for stable branch
                # & $script:UpdateApp -App $app -LogBox $script:updateLogBox
                $timestamp = Get-Date -Format "HH:mm:ss"
                $script:updateLogBox.AppendText("[$timestamp] WinGet updates disabled - cannot update $($app.Name)`r`n")
            }

            Clear-AppStatus
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:updateLogBox.AppendText("[$timestamp] --- Update all complete ---`r`n")
            $script:updateLogBox.AppendText("[$timestamp] Click 'Check for Updates' to refresh the list.`r`n")
            $script:updateLogBox.ScrollToCaret()
        }
    })

    $updatesTab.Controls.Add($updatesPanel)

    # Initial log
    $timestamp = Get-Date -Format "HH:mm:ss"
    $script:updateLogBox.AppendText("[$timestamp] Software Updates ready.`r`n")
    $script:updateLogBox.AppendText("[$timestamp] Click 'Check for Updates' to scan for available updates.`r`n")
    #>
    #endregion Check for Updates Tab

    #region HP Drivers (HPIA) Tab

    $hpiaTab = New-Object System.Windows.Forms.TabPage
    $hpiaTab.Text = "HP Drivers (HPIA)"
    $hpiaTab.UseVisualStyleBackColor = $true
    $tabControl.TabPages.Add($hpiaTab)

    $hpiaPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $hpiaPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hpiaPanel.RowCount = 4
    $hpiaPanel.ColumnCount = 1
    $hpiaPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 80))) | Out-Null
    $hpiaPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 55))) | Out-Null
    $hpiaPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
    $hpiaPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 45))) | Out-Null

    # Row 0: Status + Scan button
    $hpiaScanPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $hpiaScanPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hpiaScanPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:hpiaStatusLabel = New-Object System.Windows.Forms.Label
    $script:hpiaStatusLabel.AutoSize = $true
    $script:hpiaStatusLabel.Padding = New-Object System.Windows.Forms.Padding(0, 8, 15, 0)
    $script:hpiaStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

    # Detect status on load
    $isHP = & $script:DetectHP
    $hpiaPath = & $script:GetHPIAPath
    if (-not $isHP) {
        $script:hpiaStatusLabel.Text = "Status: Not an HP machine"
        $script:hpiaStatusLabel.ForeColor = [System.Drawing.Color]::Gray
    } elseif (-not $hpiaPath) {
        $script:hpiaStatusLabel.Text = "Status: HPIA not found - place hp-hpia-*.exe in Tools\HPIA"
        $script:hpiaStatusLabel.ForeColor = [System.Drawing.Color]::OrangeRed
    } else {
        $script:hpiaStatusLabel.Text = "Status: HPIA ready ($hpiaPath)"
        $script:hpiaStatusLabel.ForeColor = [System.Drawing.Color]::Green
    }
    $hpiaScanPanel.Controls.Add($script:hpiaStatusLabel)

    # Force new row in FlowLayoutPanel
    $hpiaSpacer = New-Object System.Windows.Forms.Label
    $hpiaSpacer.Text = ""
    $hpiaSpacer.Width = 2000
    $hpiaSpacer.Height = 1
    $hpiaScanPanel.Controls.Add($hpiaSpacer)

    $hpiaScanBtn = New-Object System.Windows.Forms.Button
    $hpiaScanBtn.Text = "Scan Drivers"
    $hpiaScanBtn.Width = 120
    $hpiaScanBtn.Height = 30
    $hpiaScanBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 240, 255)
    $hpiaScanPanel.Controls.Add($hpiaScanBtn)

    $hpiaDownloadLink = New-Object System.Windows.Forms.LinkLabel
    $hpiaDownloadLink.Text = "Download HPIA"
    $hpiaDownloadLink.AutoSize = $true
    $hpiaDownloadLink.Padding = New-Object System.Windows.Forms.Padding(15, 8, 0, 0)
    $hpiaDownloadLink.Add_LinkClicked({
        Start-Process "https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html"
    })
    $hpiaScanPanel.Controls.Add($hpiaDownloadLink)

    $hpiaPanel.Controls.Add($hpiaScanPanel, 0, 0)

    # Row 1: Driver ListView
    $hpiaListGroup = New-Object System.Windows.Forms.GroupBox
    $hpiaListGroup.Text = "HP Driver Status"
    $hpiaListGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hpiaListGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:hpiaListView = New-Object System.Windows.Forms.ListView
    $script:hpiaListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:hpiaListView.View = [System.Windows.Forms.View]::Details
    $script:hpiaListView.FullRowSelect = $true
    $script:hpiaListView.GridLines = $true
    $script:hpiaListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:hpiaListView.Columns.Add("Driver", 300) | Out-Null
    $script:hpiaListView.Columns.Add("Priority", 100) | Out-Null
    $script:hpiaListView.Columns.Add("SoftPaq", 100) | Out-Null
    $script:hpiaListView.Columns.Add("Version", 120) | Out-Null

    $hpiaListGroup.Controls.Add($script:hpiaListView)
    $hpiaPanel.Controls.Add($hpiaListGroup, 0, 1)

    # Row 2: Install buttons
    $hpiaButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $hpiaButtonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hpiaButtonPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $hpiaInstallAllBtn = New-Object System.Windows.Forms.Button
    $hpiaInstallAllBtn.Text = "Install All"
    $hpiaInstallAllBtn.Width = 100
    $hpiaInstallAllBtn.Height = 30
    $hpiaInstallAllBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    $hpiaButtonPanel.Controls.Add($hpiaInstallAllBtn)

    $hpiaInstallCritBtn = New-Object System.Windows.Forms.Button
    $hpiaInstallCritBtn.Text = "Install Critical"
    $hpiaInstallCritBtn.Width = 120
    $hpiaInstallCritBtn.Height = 30
    $hpiaInstallCritBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 230)
    $hpiaButtonPanel.Controls.Add($hpiaInstallCritBtn)

    $hpiaInstallRecBtn = New-Object System.Windows.Forms.Button
    $hpiaInstallRecBtn.Text = "Install Critical + Recommended"
    $hpiaInstallRecBtn.Width = 210
    $hpiaInstallRecBtn.Height = 30
    $hpiaInstallRecBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 255, 230)
    $hpiaButtonPanel.Controls.Add($hpiaInstallRecBtn)

    $hpiaPanel.Controls.Add($hpiaButtonPanel, 0, 2)

    # Row 3: HPIA Log
    $hpiaLogGroup = New-Object System.Windows.Forms.GroupBox
    $hpiaLogGroup.Text = "HPIA Log"
    $hpiaLogGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hpiaLogGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:hpiaLogBox = New-Object System.Windows.Forms.TextBox
    $script:hpiaLogBox.Multiline = $true
    $script:hpiaLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:hpiaLogBox.ReadOnly = $true
    $script:hpiaLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:hpiaLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:hpiaLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:hpiaLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $hpiaLogGroup.Controls.Add($script:hpiaLogBox)
    $hpiaPanel.Controls.Add($hpiaLogGroup, 0, 3)

    # HPIA log helper
    $script:hpiaLog = {
        param([string]$Message)
        $ts = Get-Date -Format "HH:mm:ss"
        $script:hpiaLogBox.AppendText("[$ts] $Message`r`n")
        $script:hpiaLogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }

    # Event: Scan Drivers
    $hpiaScanBtn.Add_Click({
        $script:hpiaListView.Items.Clear()
        $script:hpiaLogBox.Clear()

        if (-not (& $script:DetectHP)) {
            & $script:hpiaLog "This is not an HP machine. HP driver scanning is not available."
            return
        }

        # Re-check HPIA path (in case user just dropped the installer)
        $script:HPIAPath = $null
        $hpiaPath = & $script:GetHPIAPath
        if ($hpiaPath) {
            $script:hpiaStatusLabel.Text = "Status: HPIA ready ($hpiaPath)"
            $script:hpiaStatusLabel.ForeColor = [System.Drawing.Color]::Green
        } else {
            $script:hpiaStatusLabel.Text = "Status: HPIA not found - place hp-hpia-*.exe in Tools\HPIA"
            $script:hpiaStatusLabel.ForeColor = [System.Drawing.Color]::OrangeRed
            & $script:hpiaLog "HPIA not found. Download from https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html"
            & $script:hpiaLog "Or place hp-hpia-*.exe in the Tools\HPIA folder and click Scan again."
            return
        }

        Start-AppActivity "Scanning HP drivers..."
        $findings = & $script:RunHPIAAnalysis -Log $script:hpiaLog
        $script:HPIAFindings = $findings

        foreach ($f in $findings) {
            $item = New-Object System.Windows.Forms.ListViewItem($f.Name)
            $item.SubItems.Add($f.Priority) | Out-Null
            $item.SubItems.Add($f.SoftPaq) | Out-Null
            $item.SubItems.Add($f.Version) | Out-Null

            # Color by priority
            switch ($f.Priority) {
                "Critical" { $item.BackColor = [System.Drawing.Color]::FromArgb(255, 220, 220) }
                "Recommended" { $item.BackColor = [System.Drawing.Color]::FromArgb(255, 245, 220) }
            }

            $script:hpiaListView.Items.Add($item) | Out-Null
        }

        Clear-AppStatus

        if ($findings.Count -eq 0) {
            & $script:hpiaLog "Scan complete. All HP drivers are up to date."
        } else {
            & $script:hpiaLog "Scan complete. Found $($findings.Count) driver(s) needing updates."
        }

        Write-SessionLog -Message "HPIA scan: $($findings.Count) drivers need updates" -Category "Software"
    })

    # Event: Install All
    $hpiaInstallAllBtn.Add_Click({
        $cred = Get-ElevatedCredential -Message "Enter admin credentials for HP driver updates"
        if ($cred) {
            & $script:RunHPIAUpdate -Log $script:hpiaLog -Credential $cred -Selection "All"
        }
    })

    # Event: Install Critical
    $hpiaInstallCritBtn.Add_Click({
        $cred = Get-ElevatedCredential -Message "Enter admin credentials for HP driver updates"
        if ($cred) {
            & $script:RunHPIAUpdate -Log $script:hpiaLog -Credential $cred -Selection "Critical"
        }
    })

    # Event: Install Critical + Recommended
    $hpiaInstallRecBtn.Add_Click({
        $cred = Get-ElevatedCredential -Message "Enter admin credentials for HP driver updates"
        if ($cred) {
            & $script:RunHPIAUpdate -Log $script:hpiaLog -Credential $cred -Selection "Recommended"
        }
    })

    # Initial log message
    $hpiaTimestamp = Get-Date -Format "HH:mm:ss"
    $script:hpiaLogBox.AppendText("[$hpiaTimestamp] HP Drivers (HPIA) ready.`r`n")
    if ($isHP -and $hpiaPath) {
        $script:hpiaLogBox.AppendText("[$hpiaTimestamp] Click 'Scan Drivers' to check for HP driver updates.`r`n")
    } elseif ($isHP) {
        $script:hpiaLogBox.AppendText("[$hpiaTimestamp] HPIA not found. Place hp-hpia-5.3.3.exe (or newer) in Tools\HPIA and click Scan.`r`n")
    } else {
        $script:hpiaLogBox.AppendText("[$hpiaTimestamp] Not an HP machine - HP driver features are unavailable.`r`n")
    }

    $hpiaTab.Controls.Add($hpiaPanel)

    #endregion HP Drivers (HPIA) Tab

    # Add TabControl to main tab
    $tab.Controls.Add($tabControl)
}
