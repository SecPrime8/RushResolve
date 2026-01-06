<#
.SYNOPSIS
    Printer Management Module for Windows Tech Toolkit
.DESCRIPTION
    Add, remove, and manage network printers.
    Integrates with Rush print server and printer backup/restore.
#>

$script:ModuleName = "Printers"
$script:ModuleDescription = "Add, remove, and manage network printers"

#region Configuration
$script:PrintServer = "\\RUDWV-PS401"
$script:PrinterBackupShare = "\\rush.edu\vdi\apphub\tools\NetworkPrinters"
#endregion

#region Script Blocks

# Get installed printers
$script:GetInstalledPrinters = {
    $printers = @()
    try {
        $wmiPrinters = Get-WmiObject -Query "SELECT * FROM Win32_Printer" -ErrorAction Stop
        foreach ($p in $wmiPrinters) {
            $printers += @{
                Name = $p.Name
                IsDefault = $p.Default
                IsNetwork = ($p.Name -like "\\*")
                Status = $p.PrinterStatus
                PortName = $p.PortName
                Location = $p.Location
                Comment = $p.Comment
            }
        }
    }
    catch {
        # Fallback to Get-Printer if WMI fails
        try {
            $getPrinters = Get-Printer -ErrorAction Stop
            foreach ($p in $getPrinters) {
                $isDefault = ($p.Name -eq (Get-WmiObject -Query "SELECT * FROM Win32_Printer WHERE Default=TRUE" -ErrorAction SilentlyContinue).Name)
                $printers += @{
                    Name = $p.Name
                    IsDefault = $isDefault
                    IsNetwork = ($p.Type -eq "Connection")
                    Status = $p.PrinterStatus
                    PortName = $p.PortName
                    Location = $p.Location
                    Comment = $p.Comment
                }
            }
        }
        catch {
            # Return empty if both fail
        }
    }
    return $printers
}

# Get printers from print server
$script:GetServerPrinters = {
    param([string]$Server)

    $printers = @()
    try {
        $serverPrinters = Get-Printer -ComputerName ($Server.TrimStart('\')) -ErrorAction Stop
        foreach ($p in $serverPrinters) {
            $printers += @{
                Name = $p.Name
                ShareName = $p.ShareName
                FullPath = "$Server\$($p.ShareName)"
                Location = $p.Location
                Comment = $p.Comment
                DriverName = $p.DriverName
            }
        }
    }
    catch {
        # Try WMI approach if Get-Printer fails
        try {
            $wmiPrinters = Get-WmiObject -Class Win32_Printer -ComputerName ($Server.TrimStart('\').Split('\')[0]) -ErrorAction Stop |
                Where-Object { $_.Shared -eq $true }
            foreach ($p in $wmiPrinters) {
                $printers += @{
                    Name = $p.Name
                    ShareName = $p.ShareName
                    FullPath = "$Server\$($p.ShareName)"
                    Location = $p.Location
                    Comment = $p.Comment
                    DriverName = $p.DriverName
                }
            }
        }
        catch {
            # Return empty
        }
    }
    return $printers | Sort-Object { $_.Name }
}

# Add network printer
$script:AddNetworkPrinter = {
    param([string]$PrinterPath)

    try {
        Add-Printer -ConnectionName $PrinterPath -ErrorAction Stop
        return @{ Success = $true; Error = $null }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# Remove printer
$script:RemovePrinterByName = {
    param([string]$PrinterName)

    try {
        Remove-Printer -Name $PrinterName -ErrorAction Stop
        return @{ Success = $true; Error = $null }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# Set default printer
$script:SetDefaultPrinter = {
    param([string]$PrinterName)

    try {
        $wscript = New-Object -ComObject WScript.Network
        $wscript.SetDefaultPrinter($PrinterName)
        return @{ Success = $true; Error = $null }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# Clear print queue
$script:ClearPrintQueue = {
    param([string]$PrinterName)

    try {
        $printer = Get-WmiObject -Query "SELECT * FROM Win32_Printer WHERE Name='$($PrinterName -replace '\\','\\\\')'" -ErrorAction Stop
        if ($printer) {
            $printer.CancelAllJobs() | Out-Null
        }
        return @{ Success = $true; Error = $null }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# Test print
$script:SendTestPage = {
    param([string]$PrinterName)

    try {
        $printer = Get-WmiObject -Query "SELECT * FROM Win32_Printer WHERE Name='$($PrinterName -replace '\\','\\\\')'" -ErrorAction Stop
        if ($printer) {
            $printer.PrintTestPage() | Out-Null
        }
        return @{ Success = $true; Error = $null }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

#endregion

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Main layout - split panel (left: installed, right: server browser)
    $script:splitContainer = New-Object System.Windows.Forms.SplitContainer
    $script:splitContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:splitContainer.Orientation = [System.Windows.Forms.Orientation]::Vertical
    # Note: SplitterDistance set after adding to tab to avoid size conflicts
    $script:splitContainer.Panel1MinSize = 100
    $script:splitContainer.Panel2MinSize = 100

    #region Left Panel - Installed Printers
    $leftPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $leftPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $leftPanel.RowCount = 3
    $leftPanel.ColumnCount = 1
    $leftPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
    $leftPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $leftPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null

    # Header
    $installedLabel = New-Object System.Windows.Forms.Label
    $installedLabel.Text = "Installed Printers"
    $installedLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $installedLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $installedLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $leftPanel.Controls.Add($installedLabel, 0, 0)

    # ListView for installed printers
    $script:installedListView = New-Object System.Windows.Forms.ListView
    $script:installedListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:installedListView.View = [System.Windows.Forms.View]::Details
    $script:installedListView.FullRowSelect = $true
    $script:installedListView.GridLines = $true
    $script:installedListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:installedListView.Columns.Add("Printer Name", 220) | Out-Null
    $script:installedListView.Columns.Add("Default", 55) | Out-Null
    $script:installedListView.Columns.Add("Type", 60) | Out-Null
    $leftPanel.Controls.Add($script:installedListView, 0, 1)

    # Buttons for installed printers
    $installedBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $installedBtnPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $installedBtnPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)

    $refreshInstalledBtn = New-Object System.Windows.Forms.Button
    $refreshInstalledBtn.Text = "Refresh"
    $refreshInstalledBtn.Width = 65
    $refreshInstalledBtn.Height = 28
    $installedBtnPanel.Controls.Add($refreshInstalledBtn)

    $setDefaultBtn = New-Object System.Windows.Forms.Button
    $setDefaultBtn.Text = "Set Default"
    $setDefaultBtn.Width = 90
    $setDefaultBtn.Height = 28
    $installedBtnPanel.Controls.Add($setDefaultBtn)

    $removeBtn = New-Object System.Windows.Forms.Button
    $removeBtn.Text = "Remove"
    $removeBtn.Width = 75
    $removeBtn.Height = 28
    $removeBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 230)
    $installedBtnPanel.Controls.Add($removeBtn)

    $clearQueueBtn = New-Object System.Windows.Forms.Button
    $clearQueueBtn.Text = "Clear Queue"
    $clearQueueBtn.Width = 95
    $clearQueueBtn.Height = 28
    $installedBtnPanel.Controls.Add($clearQueueBtn)

    $testPrintBtn = New-Object System.Windows.Forms.Button
    $testPrintBtn.Text = "Test Page"
    $testPrintBtn.Width = 75
    $testPrintBtn.Height = 28
    $installedBtnPanel.Controls.Add($testPrintBtn)

    $leftPanel.Controls.Add($installedBtnPanel, 0, 2)
    $script:splitContainer.Panel1.Controls.Add($leftPanel)
    #endregion

    #region Right Panel - Add Printer from Server
    $rightPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rightPanel.RowCount = 4
    $rightPanel.ColumnCount = 1
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 35))) | Out-Null
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null

    # Header
    $serverLabel = New-Object System.Windows.Forms.Label
    $serverLabel.Text = "Add Printer from Server"
    $serverLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $serverLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $serverLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $rightPanel.Controls.Add($serverLabel, 0, 0)

    # Server input row
    $serverInputPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $serverInputPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $serverInputPanel.Padding = New-Object System.Windows.Forms.Padding(0, 3, 0, 0)

    $serverInputLabel = New-Object System.Windows.Forms.Label
    $serverInputLabel.Text = "Server:"
    $serverInputLabel.AutoSize = $true
    $serverInputLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $serverInputPanel.Controls.Add($serverInputLabel)

    $script:serverTextBox = New-Object System.Windows.Forms.TextBox
    $script:serverTextBox.Text = $script:PrintServer
    $script:serverTextBox.Width = 200
    $serverInputPanel.Controls.Add($script:serverTextBox)

    $browseServerBtn = New-Object System.Windows.Forms.Button
    $browseServerBtn.Text = "Browse"
    $browseServerBtn.Width = 65
    $browseServerBtn.Height = 25
    $serverInputPanel.Controls.Add($browseServerBtn)

    $filterLabel = New-Object System.Windows.Forms.Label
    $filterLabel.Text = "Filter:"
    $filterLabel.AutoSize = $true
    $filterLabel.Padding = New-Object System.Windows.Forms.Padding(10, 5, 5, 0)
    $serverInputPanel.Controls.Add($filterLabel)

    $script:filterTextBox = New-Object System.Windows.Forms.TextBox
    $script:filterTextBox.Width = 120
    $serverInputPanel.Controls.Add($script:filterTextBox)

    $rightPanel.Controls.Add($serverInputPanel, 0, 1)

    # ListView for server printers
    $script:serverListView = New-Object System.Windows.Forms.ListView
    $script:serverListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:serverListView.View = [System.Windows.Forms.View]::Details
    $script:serverListView.FullRowSelect = $true
    $script:serverListView.GridLines = $true
    $script:serverListView.CheckBoxes = $true
    $script:serverListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:serverListView.Columns.Add("Printer Name", 180) | Out-Null
    $script:serverListView.Columns.Add("Location", 150) | Out-Null
    $script:serverListView.Columns.Add("Comment", 150) | Out-Null
    $rightPanel.Controls.Add($script:serverListView, 0, 2)

    # Buttons for adding printers
    $serverBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $serverBtnPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $serverBtnPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)

    $addSelectedBtn = New-Object System.Windows.Forms.Button
    $addSelectedBtn.Text = "Add Selected"
    $addSelectedBtn.Width = 110
    $addSelectedBtn.Height = 28
    $addSelectedBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 255, 230)
    $serverBtnPanel.Controls.Add($addSelectedBtn)

    $manualAddBtn = New-Object System.Windows.Forms.Button
    $manualAddBtn.Text = "Add by Path..."
    $manualAddBtn.Width = 95
    $manualAddBtn.Height = 28
    $serverBtnPanel.Controls.Add($manualAddBtn)

    $rightPanel.Controls.Add($serverBtnPanel, 0, 3)
    $script:splitContainer.Panel2.Controls.Add($rightPanel)
    #endregion

    #region State Variables
    $script:ServerPrintersList = @()
    #endregion

    #region Helper Functions as Script Blocks
    $script:RefreshInstalledPrinters = {
        $script:installedListView.Items.Clear()
        $printers = & $script:GetInstalledPrinters

        foreach ($p in $printers) {
            $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
            $defaultText = if ($p.IsDefault) { "Yes" } else { "" }
            $typeText = if ($p.IsNetwork) { "Network" } else { "Local" }
            $item.SubItems.Add($defaultText) | Out-Null
            $item.SubItems.Add($typeText) | Out-Null
            $item.Tag = $p

            if ($p.IsDefault) {
                $item.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
            }

            $script:installedListView.Items.Add($item) | Out-Null
        }
    }

    $script:RefreshServerPrinters = {
        $script:serverListView.Items.Clear()
        $server = $script:serverTextBox.Text.Trim()

        if (-not $server) {
            return
        }

        $script:ServerPrintersList = & $script:GetServerPrinters -Server $server
        $filter = $script:filterTextBox.Text.Trim().ToLower()

        foreach ($p in $script:ServerPrintersList) {
            # Apply filter
            if ($filter -and ($p.Name.ToLower() -notlike "*$filter*") -and
                ($p.Location -and $p.Location.ToLower() -notlike "*$filter*") -and
                ($p.Comment -and $p.Comment.ToLower() -notlike "*$filter*")) {
                continue
            }

            $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
            $locationText = if ($p.Location) { $p.Location } else { "" }
            $commentText = if ($p.Comment) { $p.Comment } else { "" }
            $item.SubItems.Add($locationText) | Out-Null
            $item.SubItems.Add($commentText) | Out-Null
            $item.Tag = $p
            $script:serverListView.Items.Add($item) | Out-Null
        }
    }

    $script:ApplyFilter = {
        $script:serverListView.Items.Clear()
        $filter = $script:filterTextBox.Text.Trim().ToLower()

        foreach ($p in $script:ServerPrintersList) {
            # Apply filter
            if ($filter -and ($p.Name.ToLower() -notlike "*$filter*") -and
                ($p.Location -and $p.Location.ToLower() -notlike "*$filter*") -and
                ($p.Comment -and $p.Comment.ToLower() -notlike "*$filter*")) {
                continue
            }

            $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
            $locationText = if ($p.Location) { $p.Location } else { "" }
            $commentText = if ($p.Comment) { $p.Comment } else { "" }
            $item.SubItems.Add($locationText) | Out-Null
            $item.SubItems.Add($commentText) | Out-Null
            $item.Tag = $p
            $script:serverListView.Items.Add($item) | Out-Null
        }
    }
    #endregion

    #region Event Handlers

    # Refresh installed printers
    $refreshInstalledBtn.Add_Click({
        & $script:RefreshInstalledPrinters
    })

    # Browse server
    $browseServerBtn.Add_Click({
        $script:serverListView.Items.Clear()
        $script:serverListView.Items.Add("Loading printers from server...") | Out-Null
        $script:serverListView.Refresh()
        & $script:RefreshServerPrinters
    })

    # Filter text changed
    $script:filterTextBox.Add_TextChanged({
        & $script:ApplyFilter
    })

    # Set default printer
    $setDefaultBtn.Add_Click({
        if ($script:installedListView.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please select a printer to set as default.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $printerName = $script:installedListView.SelectedItems[0].Text
        $result = & $script:SetDefaultPrinter -PrinterName $printerName

        if ($result.Success) {
            [System.Windows.Forms.MessageBox]::Show(
                "Default printer set to: $printerName",
                "Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            & $script:RefreshInstalledPrinters
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to set default printer: $($result.Error)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })

    # Remove printer
    $removeBtn.Add_Click({
        if ($script:installedListView.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please select a printer to remove.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $printerName = $script:installedListView.SelectedItems[0].Text

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Remove printer: $printerName?",
            "Confirm Remove",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $result = & $script:RemovePrinterByName -PrinterName $printerName

            if ($result.Success) {
                & $script:RefreshInstalledPrinters
            }
            else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to remove printer: $($result.Error)",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        }
    })

    # Clear print queue
    $clearQueueBtn.Add_Click({
        if ($script:installedListView.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please select a printer to clear its queue.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $printerName = $script:installedListView.SelectedItems[0].Text
        $result = & $script:ClearPrintQueue -PrinterName $printerName

        if ($result.Success) {
            [System.Windows.Forms.MessageBox]::Show(
                "Print queue cleared for: $printerName",
                "Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to clear queue: $($result.Error)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })

    # Test print
    $testPrintBtn.Add_Click({
        if ($script:installedListView.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please select a printer to send a test page.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $printerName = $script:installedListView.SelectedItems[0].Text
        $result = & $script:SendTestPage -PrinterName $printerName

        if ($result.Success) {
            [System.Windows.Forms.MessageBox]::Show(
                "Test page sent to: $printerName",
                "Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to send test page: $($result.Error)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })

    # Add selected printers from server
    $addSelectedBtn.Add_Click({
        $checkedItems = @()
        foreach ($item in $script:serverListView.CheckedItems) {
            $checkedItems += $item.Tag
        }

        if ($checkedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please check at least one printer to add.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $successCount = 0
        $failedPrinters = @()

        foreach ($printer in $checkedItems) {
            $result = & $script:AddNetworkPrinter -PrinterPath $printer.FullPath
            if ($result.Success) {
                $successCount++
            }
            else {
                $failedPrinters += "$($printer.Name): $($result.Error)"
            }
        }

        if ($failedPrinters.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Successfully added $successCount printer(s).",
                "Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
        else {
            $message = "Added $successCount printer(s).`n`nFailed:`n" + ($failedPrinters -join "`n")
            [System.Windows.Forms.MessageBox]::Show(
                $message,
                "Partial Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }

        & $script:RefreshInstalledPrinters
    })

    # Manual add by path
    $manualAddBtn.Add_Click({
        $inputForm = New-Object System.Windows.Forms.Form
        $inputForm.Text = "Add Printer by Path"
        $inputForm.Size = New-Object System.Drawing.Size(450, 150)
        $inputForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $inputForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $inputForm.MaximizeBox = $false
        $inputForm.MinimizeBox = $false

        $pathLabel = New-Object System.Windows.Forms.Label
        $pathLabel.Text = "Enter printer path (e.g., \\server\printername):"
        $pathLabel.Location = New-Object System.Drawing.Point(10, 15)
        $pathLabel.AutoSize = $true
        $inputForm.Controls.Add($pathLabel)

        $pathTextBox = New-Object System.Windows.Forms.TextBox
        $pathTextBox.Location = New-Object System.Drawing.Point(10, 40)
        $pathTextBox.Width = 410
        $pathTextBox.Text = $script:serverTextBox.Text + "\"
        $inputForm.Controls.Add($pathTextBox)

        $okBtn = New-Object System.Windows.Forms.Button
        $okBtn.Text = "Add"
        $okBtn.Location = New-Object System.Drawing.Point(260, 75)
        $okBtn.Width = 75
        $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $inputForm.Controls.Add($okBtn)

        $cancelBtn = New-Object System.Windows.Forms.Button
        $cancelBtn.Text = "Cancel"
        $cancelBtn.Location = New-Object System.Drawing.Point(345, 75)
        $cancelBtn.Width = 75
        $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $inputForm.Controls.Add($cancelBtn)

        $inputForm.AcceptButton = $okBtn
        $inputForm.CancelButton = $cancelBtn

        if ($inputForm.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $printerPath = $pathTextBox.Text.Trim()
            if ($printerPath) {
                $result = & $script:AddNetworkPrinter -PrinterPath $printerPath
                if ($result.Success) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Printer added successfully.",
                        "Success",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    )
                    & $script:RefreshInstalledPrinters
                }
                else {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Failed to add printer: $($result.Error)",
                        "Error",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    )
                }
            }
        }
        $inputForm.Dispose()
    })

    #endregion

    # Add to tab
    $tab.Controls.Add($script:splitContainer)

    # Set splitter position after adding (avoids size conflicts)
    $script:splitContainer.SplitterDistance = 400

    # Initial load
    & $script:RefreshInstalledPrinters
}
