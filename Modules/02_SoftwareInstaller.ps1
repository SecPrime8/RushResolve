<#
.SYNOPSIS
    Software Installer Module for Windows Tech Toolkit
.DESCRIPTION
    Install specialty applications from network share or local/USB directory.
    Supports optional install.json config files for silent install parameters.
#>

$script:ModuleName = "Software Installer"
$script:ModuleDescription = "Install applications from network share or local directory"

#region Script Blocks (defined first to avoid scope issues)

# Scan directory for installable applications
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

    # Scan subfolders for apps with optional config
    $subfolders = Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue

    foreach ($folder in $subfolders) {
        $configPath = Join-Path $folder.FullName "install.json"
        $hasConfig = Test-Path $configPath

        if ($hasConfig) {
            # Load config file
            try {
                $config = Get-Content $configPath -Raw | ConvertFrom-Json

                # Find the installer file
                $installerFile = $null
                if ($config.installer) {
                    $installerFile = Join-Path $folder.FullName $config.installer
                } else {
                    # Auto-detect installer
                    $found = Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension -in '.msi', '.exe' } |
                        Select-Object -First 1
                    if ($found) { $installerFile = $found.FullName }
                }

                if ($installerFile -and (Test-Path $installerFile)) {
                    $ext = [System.IO.Path]::GetExtension($installerFile)
                    $isMsi = ($ext -eq '.msi')

                    # Build values with proper conditionals
                    $appName = if ($config.name) { $config.name } else { $folder.Name }
                    $appVersion = if ($config.version) { $config.version } else { "" }
                    $appDesc = if ($config.description) { $config.description } else { "" }
                    $defaultSilent = if ($isMsi) { "/qn /norestart" } else { "/S" }
                    $defaultInteractive = if ($isMsi) { "/qb" } else { "" }
                    $silentArgs = if ($config.silentArgs) { $config.silentArgs } else { $defaultSilent }
                    $interactiveArgs = if ($config.interactiveArgs) { $config.interactiveArgs } else { $defaultInteractive }
                    $requiresElev = if ($null -ne $config.requiresElevation) { $config.requiresElevation } else { $true }

                    $apps += @{
                        Name = $appName
                        Version = $appVersion
                        Description = $appDesc
                        InstallerPath = $installerFile
                        InstallerType = $ext
                        SilentArgs = $silentArgs
                        InteractiveArgs = $interactiveArgs
                        RequiresElevation = $requiresElev
                        HasConfig = $true
                        FolderPath = $folder.FullName
                    }
                }
            }
            catch {
                # Config parse failed, skip this folder
            }
        }
        else {
            # No config, look for installer file
            $installer = Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.msi', '.exe' } |
                Select-Object -First 1

            if ($installer) {
                $isMsi = ($installer.Extension -eq '.msi')
                $silentArgs = if ($isMsi) { "/qn /norestart" } else { "/S" }
                $interactiveArgs = if ($isMsi) { "/qb" } else { "" }

                $apps += @{
                    Name = $folder.Name
                    Version = ""
                    Description = ""
                    InstallerPath = $installer.FullName
                    InstallerType = $installer.Extension
                    SilentArgs = $silentArgs
                    InteractiveArgs = $interactiveArgs
                    RequiresElevation = $true
                    HasConfig = $false
                    FolderPath = $folder.FullName
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

    try {
        $installArgs = if ($Silent) { $App.SilentArgs } else { $App.InteractiveArgs }
        $hideWindow = $Silent

        if ($App.InstallerType -eq '.msi') {
            # MSI installer - use msiexec
            $result = Start-ElevatedProcess -FilePath "msiexec.exe" `
                -ArgumentList "/i `"$($App.InstallerPath)`" $installArgs" `
                -Wait -Hidden:$hideWindow `
                -OperationName "install $($App.Name)"
        }
        else {
            # EXE installer - run directly
            $result = Start-ElevatedProcess -FilePath $App.InstallerPath `
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
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null
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
    $installBtn.Width = 110
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

    # Capture references for closures
    $listViewRef = $script:appListView
    $logBoxRef = $script:logBox
    $sourceComboRef = $script:sourceCombo
    $silentRadioRef = $script:silentRadio
    $scanBlockRef = $script:ScanForApps
    $installBlockRef = $script:InstallApp

    # Current path tracker
    $script:currentPath = ""
    $script:networkPath = Get-ModuleSetting -ModuleName "SoftwareInstaller" -Key "networkPath" -Default ""
    $script:localPath = Get-ModuleSetting -ModuleName "SoftwareInstaller" -Key "localPath" -Default ""

    # Function to refresh app list (uses $script: scoped variables)
    $script:RefreshAppList = {
        $script:appListView.Items.Clear()
        $script:AppsList = @()

        $path = $script:currentPath
        if (-not $path -or -not (Test-Path $path)) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:logBox.AppendText("[$timestamp] No valid path selected. Use Browse to select a directory.`r`n")
            return
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:logBox.AppendText("[$timestamp] Scanning: $path`r`n")

        $apps = & $script:ScanForApps -Path $path
        $script:AppsList = $apps

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

    # Capture refresh block for closures
    $refreshBlockRef = $script:RefreshAppList

    # Browse button
    $browseBtn.Add_Click({
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select installer directory"
        $folderBrowser.ShowNewFolderButton = $false

        if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:currentPath = $folderBrowser.SelectedPath

            if ($sourceComboRef.SelectedIndex -eq 0) {
                $script:networkPath = $script:currentPath
                Set-ModuleSetting -ModuleName "SoftwareInstaller" -Key "networkPath" -Value $script:currentPath
            }
            else {
                $script:localPath = $script:currentPath
                Set-ModuleSetting -ModuleName "SoftwareInstaller" -Key "localPath" -Value $script:currentPath
            }

            & $refreshBlockRef
        }
    }.GetNewClosure())

    # Refresh button
    $refreshBtn.Add_Click({
        & $refreshBlockRef
    }.GetNewClosure())

    # Source combo change
    $sourceComboRef.Add_SelectedIndexChanged({
        if ($sourceComboRef.SelectedIndex -eq 0) {
            $script:currentPath = $script:networkPath
        }
        else {
            $script:currentPath = $script:localPath
        }
        & $refreshBlockRef
    }.GetNewClosure())

    # Install button
    $installBtn.Add_Click({
        $selectedItems = @()
        foreach ($item in $listViewRef.CheckedItems) {
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

        $silent = $silentRadioRef.Checked
        $modeText = if ($silent) { "silent" } else { "interactive" }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Install $($selectedItems.Count) application(s) in $modeText mode?",
            "Confirm Installation",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            foreach ($app in $selectedItems) {
                & $installBlockRef -App $app -Silent $silent -LogBox $logBoxRef
            }

            $timestamp = Get-Date -Format "HH:mm:ss"
            $logBoxRef.AppendText("[$timestamp] --- Installation batch complete ---`r`n")
            $logBoxRef.ScrollToCaret()
        }
    }.GetNewClosure())

    # Select All button
    $selectAllBtn.Add_Click({
        foreach ($item in $listViewRef.Items) {
            $item.Checked = $true
        }
    }.GetNewClosure())

    # Clear Selection button
    $clearSelBtn.Add_Click({
        foreach ($item in $listViewRef.Items) {
            $item.Checked = $false
        }
    }.GetNewClosure())

    # View Details button
    $detailsBtn.Add_Click({
        if ($listViewRef.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please select an application to view details.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        $app = $listViewRef.SelectedItems[0].Tag

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
    }.GetNewClosure())

    #endregion

    $tab.Controls.Add($mainPanel)

    # Initial log message
    $timestamp = Get-Date -Format "HH:mm:ss"
    $script:logBox.AppendText("[$timestamp] Software Installer ready. Select a source and click Browse or Refresh.`r`n")
}
