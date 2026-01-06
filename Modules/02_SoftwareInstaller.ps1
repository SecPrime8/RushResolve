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
    param([string]$Path)

    $apps = @()

    if (-not (Test-Path $Path)) {
        return $apps
    }

    # Scan root level for standalone installers
    $rootInstallers = Get-ChildItem -Path $Path -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.msi', '.exe' }

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
    $level1Folders = Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue

    foreach ($folder in $level1Folders) {
        $result = & $script:ProcessFolder -Folder $folder
        if ($result) {
            $apps += $result
        }
        else {
            # No installer at level 1, check level 2 subfolders
            $level2Folders = Get-ChildItem -Path $folder.FullName -Directory -ErrorAction SilentlyContinue
            foreach ($subfolder in $level2Folders) {
                $subResult = & $script:ProcessFolder -Folder $subfolder
                if ($subResult) {
                    # Prefix name with parent folder for clarity
                    $subResult.Name = "$($folder.Name) / $($subResult.Name)"
                    $apps += $subResult
                }
            }
        }
    }

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

        # If installer is on a network share, copy to local temp first
        # (elevated sessions may not have access to network shares)
        if ($installerPath -like "\\*") {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $LogBox.AppendText("[$timestamp] Source: $installerPath`r`n")
            $LogBox.AppendText("[$timestamp] Copying from network to local temp...`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()

            $tempDir = Join-Path $env:TEMP "RushResolve_Install"
            $LogBox.AppendText("[$timestamp] Temp dir: $tempDir`r`n")

            if (-not (Test-Path $tempDir)) {
                New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
                $LogBox.AppendText("[$timestamp] Created temp directory`r`n")
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
                $LogBox.AppendText("[$timestamp] Copying: 0 / $fileSizeMB MB (0%)`r`n")

                while (($bytesRead = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $destStream.Write($buffer, 0, $bytesRead)
                    $totalRead += $bytesRead
                    $percent = [math]::Floor(($totalRead / $sourceFile.Length) * 100)

                    if ($percent -ne $lastPercent -and ($percent % 5 -eq 0 -or $percent -eq 100)) {
                        Set-AppProgress -Value $percent -Maximum 100
                        $copiedMB = [math]::Round($totalRead / 1MB, 1)
                        $LogBox.AppendText("[$timestamp] Copying: $copiedMB / $fileSizeMB MB ($percent%)`r`n")
                        $LogBox.SelectionStart = $LogBox.Text.Length
                        $LogBox.ScrollToCaret()
                        [System.Windows.Forms.Application]::DoEvents()
                        $lastPercent = $percent
                    }
                }
                $copySuccess = $true
                $LogBox.AppendText("[$timestamp] Copy complete.`r`n")
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
    $browseBtn.Height = 25
    $sourcePanel.Controls.Add($browseBtn)

    $refreshBtn = New-Object System.Windows.Forms.Button
    $refreshBtn.Text = "Refresh"
    $refreshBtn.Width = 70
    $refreshBtn.Height = 25
    $sourcePanel.Controls.Add($refreshBtn)

    $mainPanel.Controls.Add($sourcePanel, 0, 0)
    #endregion

    #region Row 1: Application ListView
    $listGroup = New-Object System.Windows.Forms.GroupBox
    $listGroup.Text = "Available Applications"
    $listGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $listGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:appListView = New-Object System.Windows.Forms.ListView
    $script:appListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:appListView.View = [System.Windows.Forms.View]::Details
    $script:appListView.CheckBoxes = $true
    $script:appListView.FullRowSelect = $true
    $script:appListView.GridLines = $true
    $script:appListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:appListView.Columns.Add("Name", 200) | Out-Null
    $script:appListView.Columns.Add("Version", 80) | Out-Null
    $script:appListView.Columns.Add("Description", 250) | Out-Null
    $script:appListView.Columns.Add("Type", 60) | Out-Null
    $script:appListView.Columns.Add("Config", 50) | Out-Null

    $listGroup.Controls.Add($script:appListView)
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
    $installBtn.Width = 120
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

    $script:logBox = New-Object System.Windows.Forms.TextBox
    $script:logBox.Multiline = $true
    $script:logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:logBox.ReadOnly = $true
    $script:logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:logBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:logBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:logBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $logGroup.Controls.Add($script:logBox)
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
            $script:logBox.AppendText("[$timestamp] Invalid path: $path`r`n")
            $script:logBox.AppendText("[$timestamp] Enter a valid local or network path (e.g., C:\Installers or \\server\share)`r`n")
            Set-AppError "Invalid path: $path"
            return
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:logBox.AppendText("[$timestamp] Scanning: $path`r`n")
        Start-AppActivity "Scanning for installers..."

        $apps = & $script:ScanForApps -Path $path
        $script:AppsList = $apps
        Clear-AppStatus

        foreach ($app in $apps) {
            $item = New-Object System.Windows.Forms.ListViewItem($app.Name)
            $item.SubItems.Add($app.Version) | Out-Null
            $item.SubItems.Add($app.Description) | Out-Null
            $typeText = $app.InstallerType.TrimStart('.').ToUpper()
            $item.SubItems.Add($typeText) | Out-Null
            $configText = if ($app.HasConfig) { "Yes" } else { "No" }
            $item.SubItems.Add($configText) | Out-Null
            $item.Tag = $app
            $script:appListView.Items.Add($item) | Out-Null
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:logBox.AppendText("[$timestamp] Found $($apps.Count) application(s)`r`n")
        $script:logBox.ScrollToCaret()
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
                & $script:InstallApp -App $app -Silent $silent -LogBox $script:logBox
            }

            Clear-AppStatus
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:logBox.AppendText("[$timestamp] --- Installation batch complete ---`r`n")
            $script:logBox.ScrollToCaret()
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
    $script:logBox.AppendText("[$timestamp] Software Installer ready.`r`n")

    # Auto-load if path exists
    if ($script:currentPath -and (Test-Path $script:currentPath -ErrorAction SilentlyContinue)) {
        & $script:RefreshAppList
    }
    else {
        $script:logBox.AppendText("[$timestamp] Enter a path or Browse, then click Refresh.`r`n")
    }
}
