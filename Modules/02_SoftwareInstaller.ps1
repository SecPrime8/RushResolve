<#
.SYNOPSIS
    Software Installer Module for Rush Resolve
.DESCRIPTION
    Install specialty applications from network share or local/USB directory.
    Supports optional install.json config files for silent install parameters.
#>

$script:ModuleName = "Software Installer"
$script:ModuleDescription = "Install applications from network share and manage favorites"
$script:FavoritesList = @()
$script:FavoritesFile = $null  # Set during init from $script:ConfigPath


# ==============================================================================
# NOTE: GPO (Group Policy Object) Deployment Not Available
# ==============================================================================
# This module does not include Group Policy-based software deployment.
# GPO deployment requires domain admin permissions and GPMC (Group Policy
# Management Console), which are typically restricted in hospital environments.
#
# For enterprise software deployment, use:
#  - Manual installation via network share (this module)
#  - SCCM/Intune (if available in your environment)
#  - Third-party deployment tools (PDQ Deploy, etc.)
# ==============================================================================

#region Script Blocks (defined first to avoid scope issues)

# Helper: Extract version from installer file
$script:GetInstallerVersion = {
    param([string]$InstallerPath)

    if (-not (Test-Path $InstallerPath)) {
        return ""
    }

    try {
        $ext = [System.IO.Path]::GetExtension($InstallerPath).ToLower()

        if ($ext -eq '.exe') {
            # Try to get file version from EXE
            $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($InstallerPath)
            if ($versionInfo.FileVersion) {
                return $versionInfo.FileVersion.Trim()
            }
            elseif ($versionInfo.ProductVersion) {
                return $versionInfo.ProductVersion.Trim()
            }
        }
        elseif ($ext -eq '.msi') {
            # Try to get version from MSI properties
            try {
                $windowsInstaller = New-Object -ComObject WindowsInstaller.Installer
                $database = $windowsInstaller.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $windowsInstaller, @($InstallerPath, 0))
                $query = "SELECT Value FROM Property WHERE Property = 'ProductVersion'"
                $view = $database.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $database, ($query))
                $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null)
                $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, $null)
                if ($record) {
                    $version = $record.GetType().InvokeMember("StringData", "GetProperty", $null, $record, 1)
                    return $version.Trim()
                }
            }
            catch {
                # MSI version extraction failed, return empty
            }
            finally {
                if ($view) { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($view) | Out-Null }
                if ($database) { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($database) | Out-Null }
                if ($windowsInstaller) { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($windowsInstaller) | Out-Null }
            }
        }
    }
    catch {
        # Version extraction failed
    }

    return ""
}

# Load favorites from JSON file
$script:LoadFavorites = {
    if (-not $script:FavoritesFile -or -not (Test-Path $script:FavoritesFile)) {
        $script:FavoritesList = @()
        return
    }

    try {
        $json = Get-Content $script:FavoritesFile -Raw | ConvertFrom-Json
        $script:FavoritesList = @()

        foreach ($fav in $json.favorites) {
            # Convert PSCustomObject to hashtable for consistency
            $favHash = @{
                Id = $fav.id
                Name = $fav.name
                Version = $fav.version
                Description = $fav.description
                InstallerPath = $fav.installerPath
                InstallerType = $fav.installerType
                SilentArgs = $fav.silentArgs
                InteractiveArgs = $fav.interactiveArgs
                RequiresElevation = $fav.requiresElevation
                HasConfig = $fav.hasConfig
                FolderPath = $fav.folderPath
                AddedDate = $fav.addedDate
                LocalCopyPath = $fav.localCopyPath
                HasLocalCopy = $false
            }

            # Validate local copy exists on disk
            if ($fav.localCopyPath -and (Test-Path $fav.localCopyPath -ErrorAction SilentlyContinue)) {
                $favHash.HasLocalCopy = $true
            } else {
                $favHash.LocalCopyPath = $null
            }

            $script:FavoritesList += $favHash
        }
    }
    catch {
        $script:FavoritesList = @()
    }
}

# Save favorites to JSON file
$script:SaveFavorites = {
    if (-not $script:FavoritesFile) { return }

    try {
        $favArray = @()
        foreach ($fav in $script:FavoritesList) {
            $favArray += @{
                id = $fav.Id
                name = $fav.Name
                version = $fav.Version
                description = $fav.Description
                installerPath = $fav.InstallerPath
                installerType = $fav.InstallerType
                silentArgs = $fav.SilentArgs
                interactiveArgs = $fav.InteractiveArgs
                requiresElevation = $fav.RequiresElevation
                hasConfig = $fav.HasConfig
                folderPath = $fav.FolderPath
                addedDate = $fav.AddedDate
                localCopyPath = $fav.LocalCopyPath
            }
        }

        $output = @{
            version = 1
            favorites = $favArray
        }

        $output | ConvertTo-Json -Depth 5 | Set-Content $script:FavoritesFile -Encoding UTF8
    }
    catch { }
}

# Add app to favorites (deduplicates by InstallerPath)
$script:AddToFavorites = {
    param([hashtable]$App)

    # Check if already exists
    $exists = $script:FavoritesList | Where-Object { $_.InstallerPath -eq $App.InstallerPath }
    if ($exists) {
        return @{ Success = $false; Reason = "Already in favorites" }
    }

    # Create new favorite entry
    $favorite = @{
        Id = [guid]::NewGuid().ToString()
        Name = $App.Name
        Version = $App.Version
        Description = $App.Description
        InstallerPath = $App.InstallerPath
        InstallerType = $App.InstallerType
        SilentArgs = $App.SilentArgs
        InteractiveArgs = $App.InteractiveArgs
        RequiresElevation = $App.RequiresElevation
        HasConfig = $App.HasConfig
        FolderPath = $App.FolderPath
        AddedDate = (Get-Date -Format "yyyy-MM-dd")
        LocalCopyPath = $null
        HasLocalCopy = $false
    }

    $script:FavoritesList += $favorite
    & $script:SaveFavorites

    return @{ Success = $true; Reason = "Added to favorites" }
}

# Download favorite from server to local storage
$script:DownloadFavorite = {
    param(
        [hashtable]$Favorite,
        [string]$DestinationRoot,
        [System.Windows.Forms.TextBox]$LogBox
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Downloading $($Favorite.Name)...`r`n")
    $LogBox.ScrollToCaret()

    try {
        # Sanitize name for directory
        $safeName = $Favorite.Name -replace '[\\/:*?"<>|]', '_'
        $appDir = Join-Path $DestinationRoot $safeName

        # Create directory if needed
        if (-not (Test-Path $appDir)) {
            New-Item -Path $appDir -ItemType Directory -Force | Out-Null
        }

        $fileName = Split-Path $Favorite.InstallerPath -Leaf
        $localPath = Join-Path $appDir $fileName

        # Get file size for progress
        $sourceFile = Get-Item $Favorite.InstallerPath -ErrorAction Stop
        $fileSizeMB = [math]::Round($sourceFile.Length / 1MB, 1)
        $LogBox.AppendText("[$timestamp] Source: $($Favorite.InstallerPath)`r`n")
        $LogBox.AppendText("[$timestamp] Destination: $localPath`r`n")
        $LogBox.AppendText("[$timestamp] Size: $fileSizeMB MB`r`n")
        $LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()

        # Streaming copy with progress (1MB buffer)
        $sourceStream = $null
        $destStream = $null
        $copySuccess = $false
        try {
            $sourceStream = [System.IO.File]::OpenRead($Favorite.InstallerPath)
            $destStream = [System.IO.File]::Create($localPath)

            $buffer = New-Object byte[] (1MB)
            $totalRead = 0
            $lastPercent = -1

            Start-AppActivity "Downloading $fileName..."
            Set-AppProgress -Value 0 -Maximum 100

            $progressLineStart = $LogBox.Text.Length
            $LogBox.AppendText("[$timestamp] Progress: 0 / $fileSizeMB MB (0%)")

            while (($bytesRead = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $destStream.Write($buffer, 0, $bytesRead)
                $totalRead += $bytesRead
                $percent = [math]::Floor(($totalRead / $sourceFile.Length) * 100)

                if ($percent -ne $lastPercent) {
                    Set-AppProgress -Value $percent -Maximum 100
                    $copiedMB = [math]::Round($totalRead / 1MB, 1)

                    # Update progress line in place
                    $newProgressText = "[$timestamp] Progress: $copiedMB / $fileSizeMB MB ($percent%)"
                    $LogBox.Select($progressLineStart, $LogBox.Text.Length - $progressLineStart)
                    $LogBox.SelectedText = $newProgressText
                    $LogBox.SelectionStart = $LogBox.Text.Length
                    $LogBox.ScrollToCaret()
                    [System.Windows.Forms.Application]::DoEvents()
                    $lastPercent = $percent
                }
            }
            $copySuccess = $true
            $LogBox.AppendText("`r`n[$timestamp] Download complete.`r`n")
            Clear-AppStatus
        }
        catch {
            $LogBox.AppendText("`r`n[$timestamp] ERROR during download: $_`r`n")
            Clear-AppStatus
            return @{ Success = $false; Error = $_.Exception.Message }
        }
        finally {
            if ($sourceStream) { $sourceStream.Close(); $sourceStream.Dispose() }
            if ($destStream) { $destStream.Close(); $destStream.Dispose() }
        }

        if (-not $copySuccess -or -not (Test-Path $localPath)) {
            return @{ Success = $false; Error = "Copy failed or file not found" }
        }

        # Update favorite metadata
        $Favorite.LocalCopyPath = $localPath
        $Favorite.HasLocalCopy = $true
        & $script:SaveFavorites

        return @{ Success = $true; LocalPath = $localPath }
    }
    catch {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
        $LogBox.ScrollToCaret()
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# Install from favorite (prefers local copy, falls back to server)
$script:InstallFromFavorite = {
    param(
        [hashtable]$Favorite,
        [bool]$Silent,
        [System.Windows.Forms.TextBox]$LogBox
    )

    # Build app hashtable for InstallApp
    $installerPath = $Favorite.InstallerPath
    $useLocal = $false

    # Prefer local copy if available and exists
    if ($Favorite.HasLocalCopy -and $Favorite.LocalCopyPath -and (Test-Path $Favorite.LocalCopyPath)) {
        $installerPath = $Favorite.LocalCopyPath
        $useLocal = $true
        $timestamp = Get-Date -Format "HH:mm:ss"
        $LogBox.AppendText("[$timestamp] Using local copy: $installerPath`r`n")
        $LogBox.ScrollToCaret()
    }

    $app = @{
        Name = $Favorite.Name
        Version = $Favorite.Version
        Description = $Favorite.Description
        InstallerPath = $installerPath
        InstallerType = $Favorite.InstallerType
        SilentArgs = $Favorite.SilentArgs
        InteractiveArgs = $Favorite.InteractiveArgs
        RequiresElevation = $Favorite.RequiresElevation
        HasConfig = $Favorite.HasConfig
        FolderPath = $Favorite.FolderPath
    }

    # Delegate to existing InstallApp
    & $script:InstallApp -App $app -Silent $Silent -LogBox $LogBox
}

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
        if ($script:scanCancelled) {
            & $logMsg "Scan cancelled by user."
            break
        }

        & $logMsg "  Found: $($installer.Name)"

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

    # Scan subfolders level-by-level (up to 2 levels deep for performance)
    # Incremental enumeration with DoEvents to keep UI responsive on network shares
    & $logMsg "Scanning subfolders (incremental, up to 2 levels)..."

    # Record scan start time for timeout check
    $scanStart = [DateTime]::Now
    $allFolders = @()

    try {
        # Level 0: immediate children
        & $logMsg "Enumerating top-level folders..."
        $level0 = @(Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue)
        $allFolders += $level0
        [System.Windows.Forms.Application]::DoEvents()

        # Check timeout
        if (([DateTime]::Now - $scanStart).TotalSeconds -gt 120) {
            & $logMsg "Scan timed out after 2 minutes. Showing partial results."
            return $apps
        }

        # Level 1: children of each L0 folder
        & $logMsg "Scanning subfolder level 1 ($($level0.Count) folders)..."
        foreach ($dir in $level0) {
            if ($script:scanCancelled) {
                & $logMsg "Scan cancelled by user."
                break
            }
            # Check timeout
            if (([DateTime]::Now - $scanStart).TotalSeconds -gt 120) {
                & $logMsg "Scan timed out after 2 minutes. Showing partial results."
                return $apps
            }
            try {
                $children = @(Get-ChildItem -Path $dir.FullName -Directory -ErrorAction SilentlyContinue)
                $allFolders += $children
            } catch {
                & $logMsg "  Skipped (access denied): $($dir.Name)"
            }
            [System.Windows.Forms.Application]::DoEvents()
        }

        if (-not $script:scanCancelled) {
            # Level 2: children of each L1 folder
            $level1 = $allFolders | Where-Object { $level0 -notcontains $_ }
            & $logMsg "Scanning subfolder level 2 ($($level1.Count) folders)..."
            foreach ($dir in $level1) {
                if ($script:scanCancelled) {
                    & $logMsg "Scan cancelled by user."
                    break
                }
                # Check timeout
                if (([DateTime]::Now - $scanStart).TotalSeconds -gt 120) {
                    & $logMsg "Scan timed out after 2 minutes. Showing partial results."
                    return $apps
                }
                try {
                    $children = @(Get-ChildItem -Path $dir.FullName -Directory -ErrorAction SilentlyContinue)
                    $allFolders += $children
                } catch {
                    & $logMsg "  Skipped (access denied): $($dir.Name)"
                }
                [System.Windows.Forms.Application]::DoEvents()
            }
        }

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
        [System.Windows.Forms.Application]::DoEvents()

        # Check cancel flag
        if ($script:scanCancelled) {
            & $logMsg "Scan cancelled by user."
            break
        }

        # Check timeout
        if (([DateTime]::Now - $scanStart).TotalSeconds -gt 120) {
            & $logMsg "Scan timed out after 2 minutes. Showing partial results."
            break
        }

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

# Ensure network share access with credential authentication
$script:EnsureShareAccess = {
    param(
        [string]$SharePath,
        [System.Windows.Forms.TextBox]$LogBox = $null
    )

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

    # Quick check: already accessible?
    if (Test-Path $SharePath -ErrorAction SilentlyContinue) {
        & $logMsg "Share path is already accessible"
        $script:ShareStatusLabel.Text = "Connected"
        $script:ShareStatusLabel.ForeColor = [System.Drawing.Color]::Green
        return $true
    }

    # If path is a drive letter (e.g., K:\), try to resolve to UNC
    $uncPath = $SharePath
    if ($SharePath -match '^[A-Z]:') {
        & $logMsg "Detected mapped drive, attempting to resolve to UNC path..."
        $resolved = Resolve-ToUNCPath -Path $SharePath

        if ($resolved) {
            $uncPath = $resolved
            & $logMsg "Resolved to UNC: $uncPath"
        }
        else {
            # Drive letter not mapped - use saved or default UNC
            $savedUNC = $script:Settings.modules.SoftwareInstaller.networkPathUNC
            $defaultUNC = $script:Settings.modules.SoftwareInstaller.networkPathUNCDefault

            if ($savedUNC) {
                $uncPath = $savedUNC
                & $logMsg "Drive not found, using saved UNC: $uncPath"
            }
            elseif ($defaultUNC) {
                $uncPath = $defaultUNC
                & $logMsg "Drive not found, using default UNC: $uncPath"
            }
            else {
                & $logMsg "ERROR: Cannot resolve drive letter and no UNC path configured"
                $script:ShareStatusLabel.Text = "Not Connected"
                $script:ShareStatusLabel.ForeColor = [System.Drawing.Color]::Red
                return $false
            }

            # Update textbox with resolved UNC path
            $script:pathTextBox.Text = $uncPath
        }
    }

    # Attempt connection
    & $logMsg "Connecting to network share..."
    $result = Connect-NetworkShare -SharePath $uncPath

    if ($result.Success) {
        & $logMsg "Successfully connected to $($result.ShareRoot)"

        # Save working UNC to settings for next time
        $script:Settings.modules.SoftwareInstaller.networkPathUNC = $uncPath
        Save-Settings

        # Update status label
        $script:ShareStatusLabel.Text = "Connected"
        $script:ShareStatusLabel.ForeColor = [System.Drawing.Color]::Green

        return $true
    }
    else {
        & $logMsg "ERROR: Failed to connect - $($result.Error)"
        $script:ShareStatusLabel.Text = "Not Connected"
        $script:ShareStatusLabel.ForeColor = [System.Drawing.Color]::Red
        return $false
    }
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
    try {
        $wingetPath = (Get-Command winget -ErrorAction Stop).Source
        & $logMsg "Found WinGet at: $wingetPath"
    }
    catch {
        & $logMsg "ERROR: WinGet not found. Install from Microsoft Store (App Installer)."
        return $updates
    }

    & $logMsg "Scanning for available updates..."
    & $logMsg "This may take 30-60 seconds..."

    try {
        # Run winget upgrade and parse output
        $output = winget upgrade --include-unknown 2>&1 | Out-String

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
    $LogBox.AppendText("[$timestamp] Updating $($App.Name) ($($App.CurrentVersion) â†’ $($App.AvailableVersion))...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # Run winget upgrade for this specific app
        $LogBox.AppendText("[$timestamp] Running: winget upgrade --id $($App.Id) --silent --accept-source-agreements --accept-package-agreements`r`n")
        $LogBox.ScrollToCaret()

        $result = winget upgrade --id $App.Id --silent --accept-source-agreements --accept-package-agreements 2>&1

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


#endregion

#region HP Detection and HPIA Integration

# HP detection
$script:IsHPMachine = $null
$script:HPIAPath = $null

$script:DetectHP = {
    if ($null -eq $script:IsHPMachine) {
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
            $script:IsHPMachine = $cs.Manufacturer -match "HP|Hewlett"
        }
        catch {
            $script:IsHPMachine = $false
        }
    }
    return $script:IsHPMachine
}

$script:GetHPIAPath = {
    if ($null -eq $script:HPIAPath) {
        # Check repo location first (Tools/HPIA/ relative to module's parent directory)
        $repoHPIA = Join-Path (Split-Path $PSScriptRoot -Parent) "Tools\HPIA\HPImageAssistant.exe"

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
    }
    return $script:HPIAPath
}

$script:RunHPIAAnalysis = {
    param([scriptblock]$Log)

    $results = @()

    # Check if HP machine
    if (-not (& $script:DetectHP)) {
        if ($Log) { & $Log "Not an HP machine - skipping HPIA" }
        return $results
    }

    $hpiaPath = & $script:GetHPIAPath
    if (-not $hpiaPath) {
        if ($Log) { & $Log "HPIA not installed. Download from: https://ftp.hp.com/pub/caps-softpaq/cmit/HPIA.html" }
        return $results
    }

    if ($Log) {
        & $Log "Running HP Image Assistant analysis..."
        & $Log "  HPIA path: $hpiaPath"
    }

    # Use a shared location so the elevated process can write and we can read
    $reportPath = "C:\Temp\RushResolve_HPIA_Report"
    if (Test-Path $reportPath) {
        Remove-Item $reportPath -Recurse -Force
        if ($Log) { & $Log "  Cleaned previous report folder" }
    }
    New-Item -ItemType Directory -Path $reportPath -Force | Out-Null
    if ($Log) { & $Log "  Report folder: $reportPath" }

    try {
        # Run HPIA in analyze-only mode
        $hpiaArgs = "/Operation:Analyze /Action:List /Category:All /Silent /ReportFolder:`"$reportPath`""

        if ($Log) {
            & $Log "  Command: `"$hpiaPath`" $hpiaArgs"
            & $Log "  Launching elevated (UAC prompt)..."
        }

        # HPIA requires true admin elevation - use Verb RunAs for UAC prompt
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $hpiaPath
        $pinfo.Arguments = $hpiaArgs
        $pinfo.UseShellExecute = $true
        $pinfo.Verb = "runas"
        $pinfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $pinfo
        [void]$proc.Start()

        if ($Log) { & $Log "  HPIA started (PID: $($proc.Id)), waiting up to 3 minutes..." }

        # Poll instead of blocking WaitForExit so the UI stays responsive
        $startTime = Get-Date
        $timeoutSec = 180  # 3 minutes
        $lastLogTime = $startTime
        while (-not $proc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 500
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            if ($elapsed -gt $timeoutSec) {
                if ($Log) { & $Log "  WARNING: HPIA analysis timed out after 3 minutes" }
                try { $proc.Kill() } catch {}
                break
            }
            if (((Get-Date) - $lastLogTime).TotalSeconds -ge 30) {
                $mins = [math]::Floor($elapsed / 60)
                $secs = [math]::Floor($elapsed % 60)
                if ($Log) { & $Log "  Still analyzing... (${mins}m ${secs}s elapsed)" }
                $lastLogTime = Get-Date
            }
        }

        $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
        if ($Log) { & $Log "  HPIA exited with code: $exitCode" }

        # Exit code 256 = no recommendations (system is up to date)
        if ($exitCode -eq 256) {
            if ($Log) { & $Log "  System is up to date - no driver/firmware updates needed" }
            return $results
        }

        # Exit code 0 = success with findings, 3010 = reboot needed (still has findings)
        if ($exitCode -ne 0 -and $exitCode -ne 3010) {
            if ($Log) { & $Log "  WARNING: Unexpected HPIA exit code $exitCode" }
        }

        # List report folder contents
        if ($Log) {
            & $Log "  Scanning report folder..."
            $allFiles = Get-ChildItem $reportPath -Recurse -ErrorAction SilentlyContinue
            if ($allFiles.Count -eq 0) {
                & $Log "  WARNING: Report folder is empty - HPIA may not have run"
            }
            else {
                foreach ($f in $allFiles) {
                    $relPath = $f.FullName.Replace($reportPath, "")
                    $sizeKB = if (-not $f.PSIsContainer) { [math]::Round($f.Length / 1KB, 1) } else { "DIR" }
                    & $Log "    $relPath ($sizeKB KB)"
                }
            }
        }

        # Find JSON report - HPIA creates <SystemID>.json in report folder
        $jsonReports = @(Get-ChildItem $reportPath -Filter "*.json" -Recurse -ErrorAction SilentlyContinue)
        if ($Log) { & $Log "  Found $($jsonReports.Count) JSON file(s)" }

        if ($jsonReports.Count -gt 0) {
            foreach ($jsonReport in $jsonReports) {
                if ($Log) { & $Log "  Reading: $($jsonReport.Name)" }

                $rawJson = Get-Content $jsonReport.FullName -Raw
                $report = $rawJson | ConvertFrom-Json

                # Find recommendations array - HPIA.Recommendations or Recommendations
                $recommendations = $null
                if ($report.HPIA -and $report.HPIA.Recommendations) {
                    $recommendations = $report.HPIA.Recommendations
                    if ($Log) { & $Log "  Found at: HPIA.Recommendations" }
                }
                elseif ($report.Recommendations) {
                    $recommendations = $report.Recommendations
                    if ($Log) { & $Log "  Found at: Recommendations" }
                }

                if ($recommendations) {
                    if ($Log) { & $Log "  Processing $($recommendations.Count) recommendation(s)..." }

                    foreach ($rec in $recommendations) {
                        # Every item in Recommendations[] IS a recommendation - no filter needed
                        # Map Severity from RELEASE_TYPE_* to friendly name
                        $priority = switch ($rec.Severity) {
                            "RELEASE_TYPE_CRITICAL"    { "Critical" }
                            "RELEASE_TYPE_RECOMMENDED" { "Recommended" }
                            "RELEASE_TYPE_ROUTINE"     { "Routine" }
                            default                    { "Recommended" }
                        }

                        $driverName = if ($rec.Name) { $rec.Name } else { "Unknown" }
                        $softpaqId = if ($rec.SoftPaqID) { $rec.SoftPaqID } else { "N/A" }
                        $version = if ($rec.RecommendationValue) { $rec.RecommendationValue } else { "N/A" }

                        $results += @{
                            Priority  = $priority
                            Name      = $driverName
                            SoftPaqId = $softpaqId
                            Version   = $version
                        }

                        if ($Log) { & $Log "  >> [$priority] $driverName - $softpaqId (v$version)" }
                    }

                    if ($recommendations.Count -gt 0) { break }
                }
                else {
                    if ($Log) {
                        $topKeys = @($report.PSObject.Properties | ForEach-Object { $_.Name })
                        & $Log "  No Recommendations found. Top-level keys: $($topKeys -join ', ')"
                    }
                }
            }

            if ($results.Count -eq 0) {
                if ($Log) { & $Log "  No updates found in report" }
            }
            else {
                $critCount = @($results | Where-Object { $_.Priority -eq "Critical" }).Count
                $recCount = @($results | Where-Object { $_.Priority -eq "Recommended" }).Count
                $routineCount = $results.Count - $critCount - $recCount
                if ($Log) { & $Log "  Summary: $critCount critical, $recCount recommended, $routineCount routine" }
            }
        }
        else {
            if ($Log) { & $Log "  No JSON report files found - HPIA may require UAC approval or failed to run" }
        }
    }
    catch {
        if ($Log) { & $Log "  HPIA analysis failed: $($_.Exception.Message)" }
    }
    finally {
        # Keep report folder for debugging if no results found
        if ($results.Count -gt 0) {
            if (Test-Path $reportPath) { Remove-Item $reportPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
        else {
            if ($Log) { & $Log "  Report folder kept for debugging: $reportPath" }
        }
    }

    return $results
}

$script:RunHPIAUpdate = {
    param(
        [scriptblock]$Log,
        [ValidateSet("All", "Critical", "Recommended")]
        [string]$Selection = "All"
    )

    if (-not (& $script:DetectHP)) {
        [System.Windows.Forms.MessageBox]::Show("This is not an HP machine.", "Not HP", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $hpiaPath = & $script:GetHPIAPath
    if (-not $hpiaPath) {
        [System.Windows.Forms.MessageBox]::Show("HP Image Assistant is not installed.`n`nDownload from:`nhttps://ftp.hp.com/pub/caps-softpaq/cmit/HPIA.html", "HPIA Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    # Build selection description for confirmation dialog
    $selectionDesc = switch ($Selection) {
        "Critical" { "CRITICAL drivers only" }
        "Recommended" { "CRITICAL and RECOMMENDED drivers" }
        default { "ALL available drivers" }
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This will download and install $selectionDesc.`n`nA UAC prompt will appear for elevation.`nThe system may require a reboot after updates.`n`nContinue?",
        "Install HP Driver Updates",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    if ($Log) { & $Log "Starting HP driver update (Selection: $Selection)..." }

    $downloadPath = "C:\Temp\RushResolve_HPIA_Downloads"
    $reportPath = "C:\Temp\RushResolve_HPIA_Update"

    # Clean previous folders
    foreach ($p in @($downloadPath, $reportPath)) {
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }

    try {
        # Build selection string - for "Recommended" we want Critical+Recommended
        $selectionArg = if ($Selection -eq "Recommended") { "Critical,Recommended" } else { $Selection }

        #region Phase 1: Download SoftPaqs
        if ($Log) { & $Log "Phase 1: Downloading SoftPaqs..." }

        $hpiaArgs = "/Operation:Analyze /Action:Download /Category:All /Selection:$selectionArg /Silent /SoftpaqDownloadFolder:`"$downloadPath`" /ReportFolder:`"$reportPath`""

        if ($Log) {
            & $Log "  Command: $hpiaArgs"
            & $Log "  Launching elevated (UAC prompt)..."
        }

        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $hpiaPath
        $pinfo.Arguments = $hpiaArgs
        $pinfo.UseShellExecute = $true
        $pinfo.Verb = "runas"
        $pinfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $pinfo
        [void]$proc.Start()

        if ($Log) { & $Log "  HPIA download started (PID: $($proc.Id))..." }

        # Poll with DoEvents so UI stays responsive
        $startTime = Get-Date
        $timeoutSec = 600  # 10 minutes for download
        $lastLogTime = $startTime
        while (-not $proc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 500
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            if ($elapsed -gt $timeoutSec) {
                if ($Log) { & $Log "  WARNING: Download timed out after 10 minutes" }
                try { $proc.Kill() } catch {}
                break
            }
            if (((Get-Date) - $lastLogTime).TotalSeconds -ge 15) {
                $mins = [math]::Floor($elapsed / 60)
                $secs = [math]::Floor($elapsed % 60)
                # Count files downloaded so far
                $dlCount = @(Get-ChildItem $downloadPath -Filter "sp*.exe" -ErrorAction SilentlyContinue).Count
                if ($Log) { & $Log "  Downloading... (${mins}m ${secs}s, $dlCount SoftPaq(s) so far)" }
                $lastLogTime = Get-Date
            }
        }

        $dlExit = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
        if ($Log) { & $Log "  Download phase finished (exit code: $dlExit)" }

        if ($dlExit -eq 256) {
            if ($Log) { & $Log "  System is up to date - nothing to download" }
            [System.Windows.Forms.MessageBox]::Show("System is already up to date.`nNo updates to install.", "Up to Date", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        #endregion

        #region Phase 2: Install from downloaded SoftPaqs
        if ($Log) { & $Log "Phase 2: Installing downloaded SoftPaqs..." }

        # Look for HPIA-generated install script
        $installScript = Get-ChildItem $downloadPath -Include "*.cmd","*.bat" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($installScript) {
            if ($Log) { & $Log "  Found install script: $($installScript.Name)" }
        }
        else {
            # No script found - build one from downloaded SoftPaq executables
            $softpaqs = @(Get-ChildItem $downloadPath -Filter "sp*.exe" -Recurse -ErrorAction SilentlyContinue)

            if ($softpaqs.Count -eq 0) {
                if ($Log) { & $Log "  No SoftPaq files found in download folder" }
                [System.Windows.Forms.MessageBox]::Show("Download completed but no SoftPaq files were found.`nCheck the log for details.", "No Files", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }

            if ($Log) { & $Log "  No install script found - creating one for $($softpaqs.Count) SoftPaq(s)" }

            $batchLines = @("@echo off")
            $i = 0
            foreach ($sp in $softpaqs) {
                $i++
                $batchLines += "echo."
                $batchLines += "echo ============================================"
                $batchLines += "echo Installing $i of $($softpaqs.Count): $($sp.Name)"
                $batchLines += "echo ============================================"
                $batchLines += "`"$($sp.FullName)`" /s /f `"$downloadPath`""
                $batchLines += "echo   Exit code: %ERRORLEVEL%"
            }
            $batchLines += "echo."
            $batchLines += "echo ============================================"
            $batchLines += "echo All $($softpaqs.Count) installation(s) complete."
            $batchLines += "echo ============================================"

            $installScriptPath = "C:\Temp\RushResolve_InstallAll.cmd"
            [System.IO.File]::WriteAllLines($installScriptPath, $batchLines)
            $installScript = Get-Item $installScriptPath
        }

        # Write wrapper and log to C:\Temp (download folder is owned by elevated HPIA)
        $installLog = "C:\Temp\RushResolve_install_output.log"
        $wrapperPath = "C:\Temp\RushResolve_wrapper.cmd"
        $wrapperLines = @(
            "@echo off"
            "cd /d `"$downloadPath`""
            "call `"$($installScript.FullName)`" > `"$installLog`" 2>&1"
            "echo __HPIA_INSTALL_DONE__ >> `"$installLog`""
        )
        [System.IO.File]::WriteAllLines($wrapperPath, $wrapperLines)

        if ($Log) { & $Log "  Launching install script elevated (UAC prompt)..." }

        # Run wrapper elevated - one UAC prompt for all installs
        $pinfo2 = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo2.FileName = "cmd.exe"
        $pinfo2.Arguments = "/c `"$wrapperPath`""
        $pinfo2.UseShellExecute = $true
        $pinfo2.Verb = "runas"
        $pinfo2.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

        $proc2 = New-Object System.Diagnostics.Process
        $proc2.StartInfo = $pinfo2
        [void]$proc2.Start()

        if ($Log) { & $Log "  Install process started (PID: $($proc2.Id))" }

        # Tail the log file to stream output into our UI log
        $reader = $null
        $startTime2 = Get-Date
        $timeoutSec2 = 900  # 15 minutes for install
        $installDone = $false

        while (-not $proc2.HasExited -or ($reader -and $reader.Peek() -ge 0)) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 300

            # Open reader once log file appears
            if (-not $reader -and (Test-Path $installLog)) {
                try {
                    $fs = [System.IO.FileStream]::new(
                        $installLog,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::ReadWrite
                    )
                    $reader = [System.IO.StreamReader]::new($fs)
                } catch {}
            }

            # Read and display new lines
            if ($reader) {
                while ($null -ne ($line = $reader.ReadLine())) {
                    if ($line -eq "__HPIA_INSTALL_DONE__") {
                        $installDone = $true
                        continue
                    }
                    $trimmed = $line.Trim()
                    if ($trimmed) {
                        if ($Log) { & $Log "  $trimmed" }
                    }
                }
            }

            # Timeout check
            $elapsed2 = ((Get-Date) - $startTime2).TotalSeconds
            if ($elapsed2 -gt $timeoutSec2) {
                if ($Log) { & $Log "  WARNING: Install timed out after 15 minutes" }
                try { $proc2.Kill() } catch {}
                break
            }
        }

        # Close the reader
        if ($reader) {
            $reader.Close()
            $reader.Dispose()
        }

        $installExit = if ($proc2.HasExited) { $proc2.ExitCode } else { -1 }
        if ($Log) { & $Log "  Install phase finished (exit code: $installExit)" }

        if ($installDone -or $installExit -eq 0) {
            if ($Log) { & $Log "  All updates installed successfully" }
            [System.Windows.Forms.MessageBox]::Show("HP driver updates completed.`n`nA reboot may be required.", "Update Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
        elseif ($installExit -eq 3010) {
            if ($Log) { & $Log "  Updates installed - reboot required" }
            [System.Windows.Forms.MessageBox]::Show("HP driver updates completed.`n`nA reboot is REQUIRED to finish installation.", "Reboot Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
        else {
            if ($Log) { & $Log "  Install finished with exit code: $installExit" }
            [System.Windows.Forms.MessageBox]::Show("HP driver update finished with exit code $installExit.`n`nCheck the log for details.", "Update Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
        #endregion
    }
    catch {
        if ($Log) { & $Log "  HPIA update error: $($_.Exception.Message)" }
        [System.Windows.Forms.MessageBox]::Show("Error running HPIA: $($_.Exception.Message)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        if (Test-Path $reportPath) { Remove-Item $reportPath -Recurse -Force -ErrorAction SilentlyContinue }
        # Keep download folder briefly for debugging, clean on next run
    }
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

    # Tab 2: Favorites
    $favoritesTab = New-Object System.Windows.Forms.TabPage
    $favoritesTab.Text = "Favorites"
    $favoritesTab.UseVisualStyleBackColor = $true
    $tabControl.TabPages.Add($favoritesTab)

    # Tab 3: Check for Updates (DISABLED - WinGet blocked by hospital)
    # Hospital blocks Microsoft Store, preventing WinGet from working
    # This tab and all WinGet functionality moved to development branch
    <#
    $updatesTab = New-Object System.Windows.Forms.TabPage
    $updatesTab.Text = "Check for Updates"
    $updatesTab.UseVisualStyleBackColor = $true
    $tabControl.TabPages.Add($updatesTab)
    #>

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

    $script:refreshBtn = New-Object System.Windows.Forms.Button
    $script:refreshBtn.Text = "Refresh"
    $script:refreshBtn.Width = 70
    $script:refreshBtn.Height = 30
    $sourcePanel.Controls.Add($script:refreshBtn)

    # Connect button (for network shares only)
    $script:ConnectBtn = New-Object System.Windows.Forms.Button
    $script:ConnectBtn.Text = "Connect"
    $script:ConnectBtn.Width = 75
    $script:ConnectBtn.Height = 30
    $script:ConnectBtn.Visible = $false
    $sourcePanel.Controls.Add($script:ConnectBtn)

    # Connection status label (for network shares only)
    $script:ShareStatusLabel = New-Object System.Windows.Forms.Label
    $script:ShareStatusLabel.AutoSize = $true
    $script:ShareStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $script:ShareStatusLabel.Margin = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)
    $script:ShareStatusLabel.Visible = $false
    $sourcePanel.Controls.Add($script:ShareStatusLabel)

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

    $script:appListView.Columns.Add("Name", 250) | Out-Null
    $script:appListView.Columns.Add("Source Path", 400) | Out-Null
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
                         ($app.InstallerPath -and $app.InstallerPath.ToLower().Contains($filterText))
            }
            if ($match) {
                $item = New-Object System.Windows.Forms.ListViewItem($app.Name)
                $item.SubItems.Add($app.InstallerPath) | Out-Null
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
    $installedAppsBtn.Width = 110
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

    # Separator before Add to Favorites
    $favSep = New-Object System.Windows.Forms.Label
    $favSep.Text = "|"
    $favSep.AutoSize = $true
    $favSep.Padding = New-Object System.Windows.Forms.Padding(0, 8, 10, 0)
    $buttonPanel.Controls.Add($favSep)

    # Add to Favorites button
    $addToFavoritesBtn = New-Object System.Windows.Forms.Button
    $addToFavoritesBtn.Text = "Add to Favorites"
    $addToFavoritesBtn.Width = 130
    $addToFavoritesBtn.Height = 30
    $addToFavoritesBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 220)  # Light gold
    $addToFavoritesBtn.Add_Click({
        $checkedItems = @()
        foreach ($item in $script:appListView.CheckedItems) {
            $checkedItems += $item.Tag
        }

        if ($checkedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please check at least one application to add to favorites.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        $addedCount = 0
        $skippedCount = 0

        foreach ($app in $checkedItems) {
            $result = & $script:AddToFavorites -App $app
            if ($result.Success) {
                $addedCount++
            } else {
                $skippedCount++
            }
        }

        # Show summary
        $msg = ""
        if ($addedCount -gt 0) {
            $msg += "$addedCount app(s) added to favorites"
        }
        if ($skippedCount -gt 0) {
            if ($msg) { $msg += "`n" }
            $msg += "$skippedCount app(s) already in favorites (skipped)"
        }

        [System.Windows.Forms.MessageBox]::Show(
            $msg,
            "Add to Favorites",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        # Refresh favorites ListView if it exists
        if ($script:RefreshFavoritesListView) {
            & $script:RefreshFavoritesListView
        }
    })
    $buttonPanel.Controls.Add($addToFavoritesBtn)

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

    # Resolve relative paths and create Repository structure (for USB portability)
    # $PSScriptRoot is Modules directory, so go up to RushResolve root, then to parent for Repository
    $scriptRoot = Split-Path $PSScriptRoot -Parent  # RushResolve root
    $repositoryRoot = Join-Path (Split-Path $scriptRoot -Parent) "Repository"  # USB:\Repository

    # Create Repository directory structure if it doesn't exist
    $localInstallersPath = Join-Path $repositoryRoot "LocalInstallers"
    $favoritesPath = Join-Path $repositoryRoot "Favorites"

    try {
        if (-not (Test-Path $repositoryRoot)) {
            New-Item -Path $repositoryRoot -ItemType Directory -Force | Out-Null
        }
        if (-not (Test-Path $localInstallersPath)) {
            New-Item -Path $localInstallersPath -ItemType Directory -Force | Out-Null
        }
        if (-not (Test-Path $favoritesPath)) {
            New-Item -Path $favoritesPath -ItemType Directory -Force | Out-Null
        }
    }
    catch {
        # If creation fails, paths will remain as-is from settings
    }

    # Resolve relative paths to absolute (if they start with ..)
    if ($script:localPath -like "..*") {
        $resolvedPath = Join-Path $scriptRoot $script:localPath
        $script:localPath = [System.IO.Path]::GetFullPath($resolvedPath)
    }

    # Load network share UNC settings (saved/default UNC paths for drive letter fallback)
    # Ensure SoftwareInstaller settings object exists
    if (-not $script:Settings.modules) {
        $script:Settings | Add-Member -NotePropertyName 'modules' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    if (-not $script:Settings.modules.SoftwareInstaller) {
        $script:Settings.modules | Add-Member -NotePropertyName 'SoftwareInstaller' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    # Add UNC path properties if they don't exist
    if (-not ($script:Settings.modules.SoftwareInstaller.PSObject.Properties.Name -contains 'networkPathUNC')) {
        $script:Settings.modules.SoftwareInstaller | Add-Member -NotePropertyName 'networkPathUNC' -NotePropertyValue "" -Force
    }
    if (-not ($script:Settings.modules.SoftwareInstaller.PSObject.Properties.Name -contains 'networkPathUNCDefault')) {
        $script:Settings.modules.SoftwareInstaller | Add-Member -NotePropertyName 'networkPathUNCDefault' -NotePropertyValue "\\rush.edu\data\IS\Infosvcs\FLDTECH\New_Hire_Folder\Useful_Software" -Force
    }

    # Initialize favorites
    $script:FavoritesFile = Join-Path $script:ConfigPath "favorites.json"

    # Ensure favoritesLocalPath property exists
    if (-not ($script:Settings.modules.SoftwareInstaller.PSObject.Properties.Name -contains 'favoritesLocalPath')) {
        $script:Settings.modules.SoftwareInstaller | Add-Member -NotePropertyName 'favoritesLocalPath' -NotePropertyValue "..\Repository\Favorites" -Force
    }

    # Resolve favoritesLocalPath if it's relative
    $favoritesLocalPath = $script:Settings.modules.SoftwareInstaller.favoritesLocalPath
    if ($favoritesLocalPath -like "..*") {
        $resolvedFavPath = Join-Path $scriptRoot $favoritesLocalPath
        $script:Settings.modules.SoftwareInstaller.favoritesLocalPath = [System.IO.Path]::GetFullPath($resolvedFavPath)
    }

    # Load favorites from file
    & $script:LoadFavorites

    # Function to refresh app list (uses $script: scoped variables)
    $script:RefreshAppList = {
        $script:appListView.Items.Clear()
        $script:AppsList = @()

        # Read path from textbox
        $path = $script:pathTextBox.Text.Trim()
        $script:currentPath = $path

        # Validate path based on source type
        if ($script:sourceCombo.SelectedIndex -eq 0) {
            # Network Share: use EnsureShareAccess to handle authentication
            if (-not $path) {
                $timestamp = Get-Date -Format "HH:mm:ss"
                $script:installerLogBox.AppendText("[$timestamp] Please enter a network share path`r`n")
                Set-AppError "No path specified"
                return
            }

            # Ensure share is accessible (may prompt for credentials)
            $connected = & $script:EnsureShareAccess -SharePath $path -LogBox $script:installerLogBox

            if (-not $connected) {
                Set-AppError "Cannot access network share: $path"
                return
            }

            # Re-read path in case it was changed to UNC
            $path = $script:pathTextBox.Text.Trim()
            $script:currentPath = $path
        }
        else {
            # Local/USB: simple validation
            if (-not $path -or -not (Test-Path $path)) {
                $timestamp = Get-Date -Format "HH:mm:ss"
                $script:installerLogBox.AppendText("[$timestamp] Invalid path: $path`r`n")
                $script:installerLogBox.AppendText("[$timestamp] Enter a valid local path (e.g., C:\Installers or D:\Software)`r`n")
                Set-AppError "Invalid path: $path"
                return
            }
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:installerLogBox.AppendText("[$timestamp] Scanning: $path`r`n")
        Start-AppActivity "Scanning for installers..."

        # Initialize cancel flag and change button to Cancel mode
        $script:scanCancelled = $false
        $script:refreshBtn.Text = "Cancel"
        $script:refreshBtn.ForeColor = [System.Drawing.Color]::Red
        [System.Windows.Forms.Application]::DoEvents()

        $apps = & $script:ScanForApps -Path $path -LogBox $script:installerLogBox
        $script:AppsList = $apps

        # Restore button to Refresh mode
        $script:refreshBtn.Text = "Refresh"
        $script:refreshBtn.ForeColor = [System.Drawing.SystemColors]::ControlText

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
                         ($app.InstallerPath -and $app.InstallerPath.ToLower().Contains($filterText))
            }
            if ($match) {
                $item = New-Object System.Windows.Forms.ListViewItem($app.Name)
                $item.SubItems.Add($app.InstallerPath) | Out-Null
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

    # Refresh button (also acts as Cancel during scan)
    $script:refreshBtn.Add_Click({
        if ($script:refreshBtn.Text -eq "Cancel") {
            # Cancel the current scan
            $script:scanCancelled = $true
        } else {
            # Start a new scan
            & $script:RefreshAppList
        }
    })

    # Connect button (for network shares)
    $script:ConnectBtn.Add_Click({
        $path = $script:pathTextBox.Text.Trim()
        if (-not $path) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please enter a network share path first.",
                "No Path Specified",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        # Attempt connection
        $connected = & $script:EnsureShareAccess -SharePath $path -LogBox $script:installerLogBox

        if ($connected) {
            # Refresh app list on successful connection
            & $script:RefreshAppList
        }
    })

    # Source combo change - update textbox with saved path
    $script:sourceCombo.Add_SelectedIndexChanged({
        if ($script:sourceCombo.SelectedIndex -eq 0) {
            # Network Share selected
            $script:pathTextBox.Text = $script:networkPath
            $script:currentPath = $script:networkPath
            $script:ConnectBtn.Visible = $true
            $script:ShareStatusLabel.Visible = $true
        }
        else {
            # Local/USB selected
            $script:pathTextBox.Text = $script:localPath
            $script:currentPath = $script:localPath
            $script:ConnectBtn.Visible = $false
            $script:ShareStatusLabel.Visible = $false

            # Disconnect any active network share
            Disconnect-NetworkShare
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

    # Hide network share UI controls on load (Local/USB is default)
    $script:ConnectBtn.Visible = $false
    $script:ShareStatusLabel.Visible = $false

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

    #region Favorites Tab

    # Main layout - TableLayoutPanel for structured layout
    $favMainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $favMainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $favMainPanel.RowCount = 4
    $favMainPanel.ColumnCount = 1
    $favMainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null
    $favMainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null
    $favMainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
    $favMainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null

    #region Row 0: Info Bar
    $favInfoPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $favInfoPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $favInfoPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $favPathLabel = New-Object System.Windows.Forms.Label
    $favPathLabel.Text = "Download Path:"
    $favPathLabel.AutoSize = $true
    $favPathLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $favInfoPanel.Controls.Add($favPathLabel)

    $script:favPathTextBox = New-Object System.Windows.Forms.TextBox
    $script:favPathTextBox.Width = 400
    $script:favPathTextBox.Height = 25
    $script:favPathTextBox.Text = $script:Settings.modules.SoftwareInstaller.favoritesLocalPath
    $favInfoPanel.Controls.Add($script:favPathTextBox)

    $favBrowseBtn = New-Object System.Windows.Forms.Button
    $favBrowseBtn.Text = "Browse"
    $favBrowseBtn.Width = 65
    $favBrowseBtn.Height = 30
    $favBrowseBtn.Add_Click({
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select favorites download directory"
        $folderBrowser.ShowNewFolderButton = $true

        if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:favPathTextBox.Text = $folderBrowser.SelectedPath
            $script:Settings.modules.SoftwareInstaller.favoritesLocalPath = $folderBrowser.SelectedPath
            Save-Settings
        }
    })
    $favInfoPanel.Controls.Add($favBrowseBtn)

    $script:favCountLabel = New-Object System.Windows.Forms.Label
    $script:favCountLabel.Text = "0 favorite(s)"
    $script:favCountLabel.AutoSize = $true
    $script:favCountLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:favCountLabel.Padding = New-Object System.Windows.Forms.Padding(15, 5, 0, 0)
    $favInfoPanel.Controls.Add($script:favCountLabel)

    $favMainPanel.Controls.Add($favInfoPanel, 0, 0)
    #endregion

    #region Row 1: Favorites ListView
    $favListGroup = New-Object System.Windows.Forms.GroupBox
    $favListGroup.Text = "Favorite Applications"
    $favListGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $favListGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:favListView = New-Object System.Windows.Forms.ListView
    $script:favListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:favListView.View = [System.Windows.Forms.View]::Details
    $script:favListView.CheckBoxes = $true
    $script:favListView.FullRowSelect = $true
    $script:favListView.GridLines = $true
    $script:favListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:favListView.Columns.Add("Name", 250) | Out-Null
    $script:favListView.Columns.Add("Type", 60) | Out-Null
    $script:favListView.Columns.Add("Local Copy", 80) | Out-Null
    $script:favListView.Columns.Add("Added", 100) | Out-Null
    $script:favListView.Columns.Add("Source Path", 350) | Out-Null

    # Column click sorting
    $favSortColumn = 0
    $favSortAscending = $true
    $script:favListView.Add_ColumnClick({
        param($sender, $e)
        $col = $e.Column

        if ($col -eq $favSortColumn) {
            $favSortAscending = -not $favSortAscending
        } else {
            $favSortColumn = $col
            $favSortAscending = $true
        }

        $items = @($script:favListView.Items | ForEach-Object { $_ })
        $sorted = $items | Sort-Object { $_.SubItems[$col].Text } -Descending:(-not $favSortAscending)

        $script:favListView.BeginUpdate()
        $script:favListView.Items.Clear()
        foreach ($item in $sorted) {
            $script:favListView.Items.Add($item) | Out-Null
        }
        $script:favListView.EndUpdate()
    }.GetNewClosure())

    $favListGroup.Controls.Add($script:favListView)
    $favMainPanel.Controls.Add($favListGroup, 0, 1)
    #endregion

    #region Row 2: Action Buttons
    $favButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $favButtonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $favButtonPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    # Install mode radios (own set for favorites tab)
    $favModeLabel = New-Object System.Windows.Forms.Label
    $favModeLabel.Text = "Install Mode:"
    $favModeLabel.AutoSize = $true
    $favModeLabel.Padding = New-Object System.Windows.Forms.Padding(0, 8, 10, 0)
    $favButtonPanel.Controls.Add($favModeLabel)

    $script:favSilentRadio = New-Object System.Windows.Forms.RadioButton
    $script:favSilentRadio.Text = "Silent"
    $script:favSilentRadio.AutoSize = $true
    $script:favSilentRadio.Checked = $true
    $script:favSilentRadio.Padding = New-Object System.Windows.Forms.Padding(0, 5, 10, 0)
    $favButtonPanel.Controls.Add($script:favSilentRadio)

    $script:favInteractiveRadio = New-Object System.Windows.Forms.RadioButton
    $script:favInteractiveRadio.Text = "Interactive"
    $script:favInteractiveRadio.AutoSize = $true
    $script:favInteractiveRadio.Padding = New-Object System.Windows.Forms.Padding(0, 5, 20, 0)
    $favButtonPanel.Controls.Add($script:favInteractiveRadio)

    $favSep1 = New-Object System.Windows.Forms.Label
    $favSep1.Text = "|"
    $favSep1.AutoSize = $true
    $favSep1.Padding = New-Object System.Windows.Forms.Padding(0, 8, 10, 0)
    $favButtonPanel.Controls.Add($favSep1)

    # Download Selected button
    $downloadBtn = New-Object System.Windows.Forms.Button
    $downloadBtn.Text = "Download Selected"
    $downloadBtn.Width = 145
    $downloadBtn.Height = 30
    $downloadBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 240, 255)  # Light blue
    $downloadBtn.Add_Click({
        $checkedItems = @()
        foreach ($item in $script:favListView.CheckedItems) {
            $fav = $item.Tag
            # Only download if not already downloaded
            if (-not $fav.HasLocalCopy) {
                $checkedItems += $fav
            }
        }

        if ($checkedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "No items selected for download, or all selected items already have local copies.",
                "Nothing to Download",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        $destRoot = $script:favPathTextBox.Text.Trim()
        if (-not $destRoot -or -not (Test-Path $destRoot -IsValid)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please specify a valid download path.",
                "Invalid Path",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        # Create destination directory if needed
        if (-not (Test-Path $destRoot)) {
            try {
                New-Item -Path $destRoot -ItemType Directory -Force | Out-Null
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to create download directory: $_",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
                return
            }
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:favLogBox.AppendText("[$timestamp] Starting download of $($checkedItems.Count) item(s)...`r`n")

        foreach ($fav in $checkedItems) {
            $result = & $script:DownloadFavorite -Favorite $fav -DestinationRoot $destRoot -LogBox $script:favLogBox
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:favLogBox.AppendText("[$timestamp] Download batch complete.`r`n")
        $script:favLogBox.ScrollToCaret()

        # Refresh list to show updated local copy status
        & $script:RefreshFavoritesListView
    })
    $favButtonPanel.Controls.Add($downloadBtn)

    # Install Selected button
    $favInstallBtn = New-Object System.Windows.Forms.Button
    $favInstallBtn.Text = "Install Selected"
    $favInstallBtn.Width = 135
    $favInstallBtn.Height = 30
    $favInstallBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 255, 230)  # Light green
    $favInstallBtn.Add_Click({
        $checkedItems = @()
        foreach ($item in $script:favListView.CheckedItems) {
            $checkedItems += $item.Tag
        }

        if ($checkedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please check at least one application to install.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $silent = $script:favSilentRadio.Checked
        $modeText = if ($silent) { "silent" } else { "interactive" }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Install $($checkedItems.Count) favorite(s) in $modeText mode?",
            "Confirm Installation",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $total = $checkedItems.Count
            $current = 0

            foreach ($fav in $checkedItems) {
                $current++
                Set-AppProgress -Value $current -Maximum $total -Message "Installing $current of $total`: $($fav.Name)"
                & $script:InstallFromFavorite -Favorite $fav -Silent $silent -LogBox $script:favLogBox
            }

            Clear-AppStatus
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:favLogBox.AppendText("[$timestamp] --- Installation batch complete ---`r`n")
            $script:favLogBox.ScrollToCaret()
        }
    })
    $favButtonPanel.Controls.Add($favInstallBtn)

    # Remove button
    $removeBtn = New-Object System.Windows.Forms.Button
    $removeBtn.Text = "Remove"
    $removeBtn.Width = 75
    $removeBtn.Height = 30
    $removeBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 230)  # Light red
    $removeBtn.Add_Click({
        $checkedItems = @()
        foreach ($item in $script:favListView.CheckedItems) {
            $checkedItems += $item.Tag
        }

        if ($checkedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please check at least one favorite to remove.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Remove $($checkedItems.Count) favorite(s)?`n`nLocal copies will also be deleted if they exist.",
            "Confirm Removal",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            foreach ($fav in $checkedItems) {
                # Delete local copy directory if exists
                if ($fav.LocalCopyPath) {
                    try {
                        $appDir = Split-Path $fav.LocalCopyPath -Parent
                        if ($appDir -and (Test-Path $appDir)) {
                            Remove-Item -Path $appDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                    catch { }
                }

                # Remove from list
                $script:FavoritesList = @($script:FavoritesList | Where-Object { $_.Id -ne $fav.Id })
            }

            & $script:SaveFavorites
            & $script:RefreshFavoritesListView

            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:favLogBox.AppendText("[$timestamp] Removed $($checkedItems.Count) favorite(s).`r`n")
            $script:favLogBox.ScrollToCaret()
        }
    })
    $favButtonPanel.Controls.Add($removeBtn)

    # Select All button
    $favSelectAllBtn = New-Object System.Windows.Forms.Button
    $favSelectAllBtn.Text = "Select All"
    $favSelectAllBtn.Width = 80
    $favSelectAllBtn.Height = 30
    $favSelectAllBtn.Add_Click({
        foreach ($item in $script:favListView.Items) {
            $item.Checked = $true
        }
    })
    $favButtonPanel.Controls.Add($favSelectAllBtn)

    # Clear button
    $favClearBtn = New-Object System.Windows.Forms.Button
    $favClearBtn.Text = "Clear"
    $favClearBtn.Width = 60
    $favClearBtn.Height = 30
    $favClearBtn.Add_Click({
        foreach ($item in $script:favListView.Items) {
            $item.Checked = $false
        }
    })
    $favButtonPanel.Controls.Add($favClearBtn)

    $favMainPanel.Controls.Add($favButtonPanel, 0, 2)
    #endregion

    #region Row 3: Log Output
    $favLogGroup = New-Object System.Windows.Forms.GroupBox
    $favLogGroup.Text = "Favorites Log"
    $favLogGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $favLogGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:favLogBox = New-Object System.Windows.Forms.TextBox
    $script:favLogBox.Multiline = $true
    $script:favLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:favLogBox.ReadOnly = $true
    $script:favLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:favLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:favLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:favLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $favLogGroup.Controls.Add($script:favLogBox)
    $favMainPanel.Controls.Add($favLogGroup, 0, 3)
    #endregion

    # Define RefreshFavoritesListView function
    $script:RefreshFavoritesListView = {
        $script:favListView.BeginUpdate()
        $script:favListView.Items.Clear()

        foreach ($fav in $script:FavoritesList) {
            $item = New-Object System.Windows.Forms.ListViewItem($fav.Name)
            $typeText = if ($fav.InstallerType) { $fav.InstallerType.TrimStart('.').ToUpper() } else { "?" }
            $item.SubItems.Add($typeText) | Out-Null
            $localCopyText = if ($fav.HasLocalCopy) { "Yes" } else { "No" }
            $item.SubItems.Add($localCopyText) | Out-Null
            $item.SubItems.Add($fav.AddedDate) | Out-Null
            $item.SubItems.Add($fav.InstallerPath) | Out-Null
            $item.Tag = $fav

            # Color rows with local copies green
            if ($fav.HasLocalCopy) {
                $item.BackColor = [System.Drawing.Color]::FromArgb(240, 255, 240)  # Light green
            }

            $script:favListView.Items.Add($item) | Out-Null
        }

        $script:favListView.EndUpdate()
        $script:favCountLabel.Text = "$($script:FavoritesList.Count) favorite(s)"
    }

    # Initial load of favorites list
    & $script:RefreshFavoritesListView

    # Initial log message
    $timestamp = Get-Date -Format "HH:mm:ss"
    $script:favLogBox.AppendText("[$timestamp] Favorites ready. $($script:FavoritesList.Count) favorite(s) loaded.`r`n")

    $favoritesTab.Controls.Add($favMainPanel)
    #endregion Favorites Tab

    #region HP Drivers Tab

    $hpDriversTab = New-Object System.Windows.Forms.TabPage
    $hpDriversTab.Text = "HP Drivers"
    $hpDriversTab.UseVisualStyleBackColor = $true
    $tabControl.TabPages.Add($hpDriversTab)

    # HP Drivers layout - 4-row TableLayoutPanel
    $hpMainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $hpMainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hpMainPanel.RowCount = 4
    $hpMainPanel.ColumnCount = 1
    $hpMainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null   # Info bar
    $hpMainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 55))) | Out-Null    # ListView
    $hpMainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null   # Action buttons
    $hpMainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 45))) | Out-Null    # Log

    #region HP Row 0: Info Bar
    $hpInfoPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $hpInfoPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hpInfoPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:hpiaStatusLabel = New-Object System.Windows.Forms.Label
    $script:hpiaStatusLabel.AutoSize = $true
    $script:hpiaStatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $script:hpiaStatusLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 15, 0)
    $hpInfoPanel.Controls.Add($script:hpiaStatusLabel)

    $script:hpiaPathLabel = New-Object System.Windows.Forms.Label
    $script:hpiaPathLabel.AutoSize = $true
    $script:hpiaPathLabel.ForeColor = [System.Drawing.Color]::Gray
    $script:hpiaPathLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
    $hpInfoPanel.Controls.Add($script:hpiaPathLabel)

    # Detect HP status on tab load
    $isHP = & $script:DetectHP
    if ($isHP) {
        $script:hpiaStatusLabel.Text = "HP machine detected"
        $script:hpiaStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(40, 167, 69)
        $hpPath = & $script:GetHPIAPath
        if ($hpPath) {
            $script:hpiaPathLabel.Text = "HPIA: $hpPath"
        }
        else {
            $script:hpiaPathLabel.Text = "HPIA not found - download from https://ftp.hp.com/pub/caps-softpaq/cmit/HPIA.html"
        }
    }
    else {
        $script:hpiaStatusLabel.Text = "Not an HP machine"
        $script:hpiaStatusLabel.ForeColor = [System.Drawing.Color]::Gray
        $script:hpiaPathLabel.Text = "HP driver management is only available on HP computers"
    }

    $hpMainPanel.Controls.Add($hpInfoPanel, 0, 0)
    #endregion

    #region HP Row 1: Driver ListView
    $script:hpListGroup = New-Object System.Windows.Forms.GroupBox
    $script:hpListGroup.Text = "Available Driver Updates"
    $script:hpListGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:hpListGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:hpiaListView = New-Object System.Windows.Forms.ListView
    $script:hpiaListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:hpiaListView.View = [System.Windows.Forms.View]::Details
    $script:hpiaListView.FullRowSelect = $true
    $script:hpiaListView.GridLines = $true
    $script:hpiaListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:hpiaListView.Columns.Add("Priority", 90) | Out-Null
    $script:hpiaListView.Columns.Add("Driver Name", 300) | Out-Null
    $script:hpiaListView.Columns.Add("SoftPaq ID", 100) | Out-Null
    $script:hpiaListView.Columns.Add("Version", 120) | Out-Null

    $script:hpListGroup.Controls.Add($script:hpiaListView)
    $hpMainPanel.Controls.Add($script:hpListGroup, 0, 1)
    #endregion

    #region HP Row 2: Action Buttons
    $hpButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $hpButtonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hpButtonPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:hpToolTip = New-Object System.Windows.Forms.ToolTip

    $hpCheckBtn = New-Object System.Windows.Forms.Button
    $hpCheckBtn.Text = "Check Drivers"
    $hpCheckBtn.Width = 110
    $hpCheckBtn.Height = 30
    $hpCheckBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 240, 255)
    $hpCheckBtn.Add_Click({
        if (-not (& $script:DetectHP)) {
            [System.Windows.Forms.MessageBox]::Show("This is not an HP machine.", "Not HP", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        Start-AppActivity "Checking HP drivers..."
        $script:hpiaLogBox.Clear()
        $script:hpiaListView.Items.Clear()

        $logCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:hpiaLogBox.AppendText("[$ts] $Message`r`n")
            $script:hpiaLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $driverResults = & $script:RunHPIAAnalysis -Log $logCallback

        # Populate ListView
        $script:hpiaListView.BeginUpdate()
        foreach ($driver in $driverResults) {
            $item = New-Object System.Windows.Forms.ListViewItem($driver.Priority)
            $item.SubItems.Add($driver.Name) | Out-Null
            $item.SubItems.Add($driver.SoftPaqId) | Out-Null
            $item.SubItems.Add($driver.Version) | Out-Null
            $item.Tag = $driver

            # Color by priority
            $item.ForeColor = switch ($driver.Priority) {
                "Critical"    { [System.Drawing.Color]::FromArgb(180, 40, 40) }
                "Recommended" { [System.Drawing.Color]::FromArgb(180, 120, 0) }
                default       { [System.Drawing.Color]::FromArgb(0, 100, 180) }
            }

            $script:hpiaListView.Items.Add($item) | Out-Null
        }
        $script:hpiaListView.EndUpdate()

        # Update group text
        $script:hpListGroup.Text = "Available Driver Updates ($($driverResults.Count) found)"

        Clear-AppStatus
        & $logCallback "HP driver check complete. $($driverResults.Count) update(s) found."
        Write-SessionLog -Message "HP driver check: $($driverResults.Count) updates found" -Category "Software Installer"
    })
    $script:hpToolTip.SetToolTip($hpCheckBtn, "Will prompt UAC for elevation")
    $hpButtonPanel.Controls.Add($hpCheckBtn)

    # Separator
    $hpSep1 = New-Object System.Windows.Forms.Label
    $hpSep1.Text = "|"
    $hpSep1.AutoSize = $true
    $hpSep1.Padding = New-Object System.Windows.Forms.Padding(3, 8, 3, 0)
    $hpButtonPanel.Controls.Add($hpSep1)

    $hpInstallAllBtn = New-Object System.Windows.Forms.Button
    $hpInstallAllBtn.Text = "Install All"
    $hpInstallAllBtn.Width = 90
    $hpInstallAllBtn.Height = 30
    $hpInstallAllBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 255, 230)
    $hpInstallAllBtn.Add_Click({
        Start-AppActivity "Installing HP drivers..."
        $logCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:hpiaLogBox.AppendText("[$ts] $Message`r`n")
            $script:hpiaLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        & $script:RunHPIAUpdate -Log $logCallback -Selection "All"
        Clear-AppStatus
    })
    $script:hpToolTip.SetToolTip($hpInstallAllBtn, "Will prompt UAC for elevation")
    $hpButtonPanel.Controls.Add($hpInstallAllBtn)

    $hpInstallCritBtn = New-Object System.Windows.Forms.Button
    $hpInstallCritBtn.Text = "Install Critical Only"
    $hpInstallCritBtn.Width = 130
    $hpInstallCritBtn.Height = 30
    $hpInstallCritBtn.Add_Click({
        Start-AppActivity "Installing critical HP drivers..."
        $logCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:hpiaLogBox.AppendText("[$ts] $Message`r`n")
            $script:hpiaLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        & $script:RunHPIAUpdate -Log $logCallback -Selection "Critical"
        Clear-AppStatus
    })
    $script:hpToolTip.SetToolTip($hpInstallCritBtn, "Will prompt UAC for elevation")
    $hpButtonPanel.Controls.Add($hpInstallCritBtn)

    $hpInstallRecBtn = New-Object System.Windows.Forms.Button
    $hpInstallRecBtn.Text = "Critical + Recommended"
    $hpInstallRecBtn.Width = 170
    $hpInstallRecBtn.Height = 30
    $hpInstallRecBtn.Add_Click({
        Start-AppActivity "Installing HP drivers..."
        $logCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:hpiaLogBox.AppendText("[$ts] $Message`r`n")
            $script:hpiaLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        & $script:RunHPIAUpdate -Log $logCallback -Selection "Recommended"
        Clear-AppStatus
    })
    $script:hpToolTip.SetToolTip($hpInstallRecBtn, "Will prompt UAC for elevation")
    $hpButtonPanel.Controls.Add($hpInstallRecBtn)

    $hpMainPanel.Controls.Add($hpButtonPanel, 0, 2)
    #endregion

    #region HP Row 3: Log TextBox
    $hpLogGroup = New-Object System.Windows.Forms.GroupBox
    $hpLogGroup.Text = "Log"
    $hpLogGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:hpiaLogBox = New-Object System.Windows.Forms.TextBox
    $script:hpiaLogBox.Multiline = $true
    $script:hpiaLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:hpiaLogBox.ReadOnly = $true
    $script:hpiaLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:hpiaLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:hpiaLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:hpiaLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $hpLogGroup.Controls.Add($script:hpiaLogBox)
    $hpMainPanel.Controls.Add($hpLogGroup, 0, 3)
    #endregion

    $hpDriversTab.Controls.Add($hpMainPanel)

    # Initial log message
    $timestamp = Get-Date -Format "HH:mm:ss"
    if ($isHP) {
        $script:hpiaLogBox.AppendText("[$timestamp] HP machine detected. Click 'Check Drivers' to scan for updates.`r`n")
    }
    else {
        $script:hpiaLogBox.AppendText("[$timestamp] Not an HP machine. HP driver management is not available.`r`n")
    }

    #endregion HP Drivers Tab

    <#
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

    # Add TabControl to main tab
    $tab.Controls.Add($tabControl)
}
