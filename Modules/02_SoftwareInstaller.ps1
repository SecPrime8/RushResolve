<#
.SYNOPSIS
    Software Installer Module for Rush Resolve
.DESCRIPTION
    Install specialty applications from network share or local/USB directory.
    Supports optional install.json config files for silent install parameters.
#>

$script:ModuleName = "Software Installer"
$script:ModuleDescription = "Install applications from network share or local directory"

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

# Scan directory for installable applications (2 levels deep)
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

    # Scan subfolders (level 1) for apps
    & $logMsg "Scanning level 1 subfolders..."
    try {
        $level1Folders = Get-ChildItem -Path $Path -Directory -ErrorAction Stop
        & $logMsg "Found $($level1Folders.Count) subfolder(s) at level 1"
    }
    catch {
        & $logMsg "ERROR reading level 1 folders: $($_.Exception.Message)"
        $level1Folders = @()
    }

    foreach ($folder in $level1Folders) {
        & $logMsg "  Checking: $($folder.Name)"
        $result = & $script:ProcessFolder -Folder $folder
        if ($result) {
            & $logMsg "    -> Found installer: $($result.Name)"
            $apps += $result
        }
        else {
            # No installer at level 1, check level 2 subfolders
            try {
                $level2Folders = Get-ChildItem -Path $folder.FullName -Directory -ErrorAction Stop
                if ($level2Folders.Count -gt 0) {
                    & $logMsg "    -> No installer, checking $($level2Folders.Count) level 2 subfolder(s)"
                }
            }
            catch {
                & $logMsg "    -> ERROR reading level 2: $($_.Exception.Message)"
                $level2Folders = @()
            }
            foreach ($subfolder in $level2Folders) {
                $subResult = & $script:ProcessFolder -Folder $subfolder
                if ($subResult) {
                    # Prefix name with parent folder for clarity
                    $subResult.Name = "$($folder.Name) / $($subResult.Name)"
                    & $logMsg "      -> Found installer: $($subResult.Name)"
                    $apps += $subResult
                }
            }
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

#endregion

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Store apps list at script level
    $script:AppsList = @()

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

    $tab.Controls.Add($mainPanel)

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
}
