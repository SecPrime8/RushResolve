<#
.SYNOPSIS
    Printer Management Module for Rush Resolve
.DESCRIPTION
    Add, remove, and manage network printers.
    Integrates with Rush print server and printer backup/restore.
#>

$script:ModuleName = "Printers"
$script:ModuleDescription = "Add, remove, and manage network printers"

#region Configuration
# SECURITY: Hardcoded allowlist of approved print servers
# Only these servers can be used - prevents path injection attacks
$script:AllowedPrintServers = @(
    "\\RUDWV-PS401",       # Primary RMC print server
    "\\RUDWV-PS402",       # Secondary RMC print server
    "\\RUCPMC-PS01",       # CPMC print server
    "\\RUSH-PS01"          # Main campus print server
)

# Load default server from settings (must be in allowlist)
$script:PrintServer = Get-ModuleSetting -ModuleName "PrinterManagement" -Key "defaultServer" -Default "\\RUDWV-PS401"
# Validate default is in allowlist
if ($script:PrintServer -and $script:AllowedPrintServers -notcontains $script:PrintServer) {
    $script:PrintServer = $script:AllowedPrintServers[0]
}
$script:PrinterBackupShare = "\\rush.edu\vdi\apphub\tools\NetworkPrinters"
#endregion

#region Security Functions
function Test-PrinterPathAllowed {
    <#
    .SYNOPSIS
        Validates that a printer path uses an allowed print server
    .PARAMETER PrinterPath
        Full printer path (e.g., \\SERVER\PrinterName)
    .RETURNS
        Hashtable with Allowed (bool) and Reason (string)
    #>
    param([string]$PrinterPath)

    if (-not $PrinterPath) {
        return @{ Allowed = $false; Reason = "Printer path is empty" }
    }

    # Extract server from path (\\SERVER\Share format)
    if ($PrinterPath -match '^\\\\([^\\]+)\\') {
        $serverName = "\\$($Matches[1])"

        # Check against allowlist (case-insensitive)
        foreach ($allowedServer in $script:AllowedPrintServers) {
            if ($serverName -ieq $allowedServer) {
                return @{ Allowed = $true; Reason = $null }
            }
        }

        return @{
            Allowed = $false
            Reason = "Server '$serverName' is not in the approved print server list.`n`nAllowed servers: $($script:AllowedPrintServers -join ', ')"
        }
    }

    return @{ Allowed = $false; Reason = "Invalid printer path format. Expected: \\SERVER\PrinterName" }
}
#endregion

#region Script Blocks

# Log helper function
$script:PrinterLog = {
    param([string]$Message)
    if ($script:printerLogBox) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:printerLogBox.AppendText("[$timestamp] $Message`r`n")
        $script:printerLogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

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
        # Fallback to Get-Printer if WMI fails (only if PrintManagement available)
        if ($script:HasPrintManagement) {
            try {
                $getPrinters = Get-Printer -ErrorAction Stop
                foreach ($p in $getPrinters) {
                    $isDefault = $false
                    try {
                        $defaultPrinter = Get-WmiObject -Query "SELECT * FROM Win32_Printer WHERE Default=TRUE" -ErrorAction SilentlyContinue
                        $isDefault = ($p.Name -eq $defaultPrinter.Name)
                    }
                    catch {
                        # Ignore error checking default status
                    }
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
    }
    return $printers
}

# Get printers from print server (with progress updates via app-wide status bar)
$script:GetServerPrinters = {
    param([string]$Server)

    $printers = @()
    $serverName = $Server.TrimStart('\')

    # Quick connectivity check (fail fast if server unreachable)
    Start-AppActivity "Testing connection to $serverName..."
    try {
        # Use WMI ping with 2-second timeout (compatible with PowerShell 5.1)
        $pingResult = Get-WmiObject -Class Win32_PingStatus -Filter "Address='$serverName' AND Timeout=2000" -ErrorAction Stop
        if ($pingResult.StatusCode -ne 0) {
            Write-SessionLog -Message "Print server $serverName is unreachable (ping failed)" -Category "Printer Management"
            return @()
        }
    }
    catch {
        Write-SessionLog -Message "Cannot reach print server $serverName - $($_.Exception.Message)" -Category "Printer Management"
        return @()
    }

    # Method 1: Try Get-Printer cmdlet (requires Print Management) - Skip if not available
    if ($script:HasPrintManagement) {
        Start-AppActivity "Trying Get-Printer cmdlet..."
        try {
            $serverPrinters = Get-Printer -ComputerName $serverName -ErrorAction Stop
            foreach ($p in $serverPrinters) {
                if ($p.Shared) {
                    $shareName = if ($p.ShareName) { $p.ShareName } else { $p.Name }
                    $printers += @{
                        Name = $p.Name
                        ShareName = $shareName
                        FullPath = "\\$serverName\$shareName"
                        Location = $p.Location
                        Comment = $p.Comment
                        DriverName = $p.DriverName
                    }
                }
            }
            if ($printers.Count -gt 0) {
                return $printers | Sort-Object { $_.Name }
            }
        }
        catch {
            # Method 1 failed, try next
        }
    }

    # Method 2: Try WMI (older but often works)
    Start-AppActivity "Trying WMI query..."
    try {
        $wmiPrinters = Get-WmiObject -Class Win32_Printer -ComputerName $serverName -ErrorAction Stop |
            Where-Object { $_.Shared -eq $true }
        foreach ($p in $wmiPrinters) {
            $shareName = if ($p.ShareName) { $p.ShareName } else { $p.Name }
            $printers += @{
                Name = $p.Name
                ShareName = $shareName
                FullPath = "\\$serverName\$shareName"
                Location = $p.Location
                Comment = $p.Comment
                DriverName = $p.DriverName
            }
        }
        if ($printers.Count -gt 0) {
            return $printers | Sort-Object { $_.Name }
        }
    }
    catch {
        # Method 2 failed, try next
    }

    # Method 3: Enumerate shared printers via net view (most compatible)
    Start-AppActivity "Trying net view command..."
    try {
        $netOutput = net view "\\$serverName" 2>&1
        $lines = $netOutput -split "`n"
        foreach ($line in $lines) {
            if ($line -match "Print") {
                # Format: "ShareName    Print    Comment"
                $parts = $line -split '\s{2,}'
                if ($parts.Count -ge 1) {
                    $shareName = $parts[0].Trim()
                    $comment = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }
                    if ($shareName -and $shareName -ne "") {
                        $printers += @{
                            Name = $shareName
                            ShareName = $shareName
                            FullPath = "\\$serverName\$shareName"
                            Location = ""
                            Comment = $comment
                            DriverName = ""
                        }
                    }
                }
            }
        }
    }
    catch {
        # Method 3 failed
    }

    return $printers | Sort-Object { $_.Name }
}

# Add network printer (current user only)
# Uses rundll32 printui.dll in a background process with responsive wait loop
$script:AddNetworkPrinter = {
    param([string]$PrinterPath)

    try {
        & $script:PrinterLog "  Connecting to print server (downloading drivers)..."
        & $script:PrinterLog "  This may take 1-3 minutes for first-time installs..."

        # Use printui.dll /in to add printer connection for current user
        # Run as background process so we can pump DoEvents during the wait
        $process = Start-Process -FilePath "rundll32.exe" `
            -ArgumentList "printui.dll,PrintUIEntry /in /n`"$PrinterPath`"" `
            -PassThru -WindowStyle Hidden

        # Responsive wait loop with elapsed time feedback
        $startTime = [DateTime]::Now
        $lastLogSeconds = 0

        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.Application]::DoEvents()

            $elapsed = [int]([DateTime]::Now - $startTime).TotalSeconds
            # Log progress every 10 seconds
            if ($elapsed -gt 0 -and $elapsed % 10 -eq 0 -and $elapsed -ne $lastLogSeconds) {
                $lastLogSeconds = $elapsed
                & $script:PrinterLog "  Still working... (${elapsed}s elapsed)"
                Start-AppActivity "Adding printer... (${elapsed}s)"
            }
        }

        $elapsed = [int]([DateTime]::Now - $startTime).TotalSeconds
        $exitCode = $process.ExitCode

        if ($exitCode -eq 0) {
            & $script:PrinterLog "  [OK] Printer added (${elapsed}s)"
            return @{ Success = $true; Error = $null }
        }
        else {
            & $script:PrinterLog "  printui.dll exited with code $exitCode, trying fallback..."

            # Fallback: Try Add-Printer cmdlet
            if ($script:HasPrintManagement) {
                try {
                    & $script:PrinterLog "  Trying Add-Printer cmdlet..."
                    Add-Printer -ConnectionName $PrinterPath -ErrorAction Stop
                    & $script:PrinterLog "  [OK] Printer added via Add-Printer cmdlet"
                    return @{ Success = $true; Error = $null }
                }
                catch {
                    & $script:PrinterLog "  Add-Printer failed: $($_.Exception.Message)"
                }
            }

            # Fallback: Try WScript.Network COM object
            try {
                & $script:PrinterLog "  Trying WScript.Network fallback..."
                $wscript = New-Object -ComObject WScript.Network
                $wscript.AddWindowsPrinterConnection($PrinterPath)
                & $script:PrinterLog "  [OK] Printer added via WScript.Network"
                return @{ Success = $true; Error = $null }
            }
            catch {
                & $script:PrinterLog "  [FAIL] All methods failed"
                return @{ Success = $false; Error = "printui.dll exit code $exitCode. Fallback also failed: $($_.Exception.Message)" }
            }
        }
    }
    catch {
        & $script:PrinterLog "  [FAIL] Error: $($_.Exception.Message)"
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# Add network printer for ALL users (requires elevation, fire-and-forget)
# Uses printui.dll /ga to add per-machine printer connection
# This runs in the background - printer persistence applies at next user logon
$script:AddNetworkPrinterAllUsers = {
    param([string]$PrinterPath)

    try {
        # Use printui.dll with /ga flag (add per-machine printer connection)
        # Fire-and-forget: don't wait since current user already has the printer
        $result = Start-ElevatedProcess -FilePath "rundll32.exe" `
            -ArgumentList "printui.dll,PrintUIEntry /ga /n`"$PrinterPath`"" `
            -Hidden `
            -OperationName "install printer for all users"

        [System.Windows.Forms.Application]::DoEvents()

        if ($result.Success) {
            return @{ Success = $true; Error = $null }
        }
        else {
            return @{ Success = $false; Error = $result.Error }
        }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# Remove printer
$script:RemovePrinterByName = {
    param([string]$PrinterName)

    # Method 1: Try Remove-Printer cmdlet (if available)
    if ($script:HasPrintManagement) {
        try {
            Remove-Printer -Name $PrinterName -ErrorAction Stop
            return @{ Success = $true; Error = $null }
        }
        catch {
            # Fall through to WMI method
        }
    }

    # Method 2: Use WScript.Network COM object (Windows 10 compatible)
    try {
        $wscript = New-Object -ComObject WScript.Network
        $wscript.RemovePrinterConnection($PrinterName, $true, $true)
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
        & $script:PrinterLog "Sending test page to: $PrinterName"

        # Use PowerShell filter instead of WQL to avoid backslash escaping issues
        $printer = Get-WmiObject Win32_Printer -ErrorAction Stop | Where-Object { $_.Name -eq $PrinterName }

        if ($printer) {
            & $script:PrinterLog "  Printer found. Sending test page..."
            $testResult = $printer.PrintTestPage()
            if ($testResult.ReturnValue -eq 0) {
                & $script:PrinterLog "  [OK] Test page sent successfully"
                return @{ Success = $true; Error = $null }
            }
            else {
                & $script:PrinterLog "  [FAIL] PrintTestPage returned code: $($testResult.ReturnValue)"
                return @{ Success = $false; Error = "PrintTestPage returned error code $($testResult.ReturnValue)" }
            }
        }
        else {
            # List available printers to help debug
            & $script:PrinterLog "  [FAIL] Printer not found in WMI"
            $allPrinters = Get-WmiObject Win32_Printer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            & $script:PrinterLog "  Available printers in WMI:"
            foreach ($p in $allPrinters) {
                & $script:PrinterLog "    - $p"
            }
            return @{ Success = $false; Error = "Printer '$PrinterName' not found. Check the Activity Log for available names." }
        }
    }
    catch {
        & $script:PrinterLog "  [FAIL] Error: $($_.Exception.Message)"
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

#endregion

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Windows 10 compatibility check - verify PrintManagement module availability
    $script:HasPrintManagement = $null -ne (Get-Command "Get-Printer" -ErrorAction SilentlyContinue)
    if (-not $script:HasPrintManagement) {
        Write-SessionLog -Message "PrintManagement module not available - using WMI fallback mode" -Category "Printer Management"
    }

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
    $leftPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 70))) | Out-Null

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

    # Enable sorting
    $script:installedListView.Sorting = [System.Windows.Forms.SortOrder]::Ascending
    $script:installedListView.Add_ColumnClick({
        param($sender, $e)
        # Toggle sort order on column click
        if ($sender.Sorting -eq [System.Windows.Forms.SortOrder]::Ascending) {
            $sender.Sorting = [System.Windows.Forms.SortOrder]::Descending
        } else {
            $sender.Sorting = [System.Windows.Forms.SortOrder]::Ascending
        }
        # Sort by clicked column (basic alphabetic sort)
        $sender.ListViewItemSorter = New-Object System.Collections.CaseInsensitiveComparer
        $sender.Sort()
    })

    # Auto-resize columns to content after items loaded
    $script:installedListView.Add_ClientSizeChanged({
        foreach ($col in $this.Columns) {
            $col.Width = -1  # Auto-size to content
        }
    })

    $leftPanel.Controls.Add($script:installedListView, 0, 1)

    # Buttons for installed printers
    $installedBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $installedBtnPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $installedBtnPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)

    $refreshInstalledBtn = New-Object System.Windows.Forms.Button
    $refreshInstalledBtn.Text = "Refresh"
    $refreshInstalledBtn.Width = 65
    $refreshInstalledBtn.Height = 30
    $installedBtnPanel.Controls.Add($refreshInstalledBtn)

    $setDefaultBtn = New-Object System.Windows.Forms.Button
    $setDefaultBtn.Text = "Set Default"
    $setDefaultBtn.Width = 105
    $setDefaultBtn.Height = 30
    $installedBtnPanel.Controls.Add($setDefaultBtn)

    $testPrintBtn = New-Object System.Windows.Forms.Button
    $testPrintBtn.Text = "Test Page"
    $testPrintBtn.Width = 85
    $testPrintBtn.Height = 30
    $installedBtnPanel.Controls.Add($testPrintBtn)

    $clearQueueBtn = New-Object System.Windows.Forms.Button
    $clearQueueBtn.Text = "Clear Queue"
    $clearQueueBtn.Width = 110
    $clearQueueBtn.Height = 30
    $installedBtnPanel.Controls.Add($clearQueueBtn)

    $removeBtn = New-Object System.Windows.Forms.Button
    $removeBtn.Text = "Remove"
    $removeBtn.Width = 75
    $removeBtn.Height = 30
    $removeBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 230)
    $installedBtnPanel.Controls.Add($removeBtn)

    # Backup button
    $backupBtn = New-Object System.Windows.Forms.Button
    $backupBtn.Text = "Backup"
    $backupBtn.Width = 75
    $backupBtn.Height = 30
    $backupBtn.Add_Click({
        try {
            $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
            $saveDialog.Filter = "XML files (*.xml)|*.xml|All files (*.*)|*.*"
            $saveDialog.Title = "Save Printer Backup"
            $saveDialog.FileName = "PrinterBackup_$(Get-Date -Format 'yyyy-MM-dd').xml"

            if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                # Get all printers with their configuration
                if ($script:HasPrintManagement) {
                    $printers = Get-Printer | Select-Object Name, DriverName, PortName, Shared, Published, Location, Comment
                } else {
                    $printers = Get-WmiObject -Class Win32_Printer | Select-Object Name, DriverName, PortName, Shared, Location, Comment
                }

                # Export to XML
                $printers | Export-Clixml -Path $saveDialog.FileName

                [System.Windows.Forms.MessageBox]::Show(
                    "Printer configurations backed up successfully to:`n$($saveDialog.FileName)",
                    "Backup Complete",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )

                Write-SessionLog -Message "Printer configurations backed up to $($saveDialog.FileName)" -Category "PrinterManagement"
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to backup printers: $($_.Exception.Message)",
                "Backup Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })
    $installedBtnPanel.Controls.Add($backupBtn)

    # Restore button
    $restoreBtn = New-Object System.Windows.Forms.Button
    $restoreBtn.Text = "Restore"
    $restoreBtn.Width = 75
    $restoreBtn.Height = 30
    $restoreBtn.Add_Click({
        try {
            $openDialog = New-Object System.Windows.Forms.OpenFileDialog
            $openDialog.Filter = "XML files (*.xml)|*.xml|All files (*.*)|*.*"
            $openDialog.Title = "Open Printer Backup"

            if ($openDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                # Import printer configurations
                $printers = Import-Clixml -Path $openDialog.FileName

                $confirm = [System.Windows.Forms.MessageBox]::Show(
                    "This will restore $($printers.Count) printer(s) from backup.`n`nNote: Drivers and ports must exist on this system.`n`nContinue?",
                    "Confirm Restore",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )

                if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
                    $restored = 0
                    $failed = 0

                    foreach ($printer in $printers) {
                        try {
                            # Check if printer already exists
                            if ($script:HasPrintManagement) {
                                $exists = Get-Printer -Name $printer.Name -ErrorAction SilentlyContinue
                            } else {
                                $exists = Get-WmiObject -Class Win32_Printer -Filter "Name='$($printer.Name)'" -ErrorAction SilentlyContinue
                            }

                            if (-not $exists) {
                                if ($script:HasPrintManagement) {
                                    Add-Printer -Name $printer.Name -DriverName $printer.DriverName -PortName $printer.PortName -ErrorAction Stop
                                    if ($printer.Shared) {
                                        Set-Printer -Name $printer.Name -Shared $true -ShareName $printer.Name -ErrorAction SilentlyContinue
                                    }
                                } else {
                                    # WMI-based method for Windows 10 compatibility
                                    $wmi = ([wmiclass]"Win32_Printer")
                                    $newPrinter = $wmi.CreateInstance()
                                    $newPrinter.Name = $printer.Name
                                    $newPrinter.DriverName = $printer.DriverName
                                    $newPrinter.PortName = $printer.PortName
                                    $newPrinter.Put() | Out-Null
                                }
                                $restored++
                            }
                        }
                        catch {
                            $failed++
                            Write-SessionLog -Message "Failed to restore printer '$($printer.Name)': $($_.Exception.Message)" -Category "PrinterManagement"
                        }
                    }

                    [System.Windows.Forms.MessageBox]::Show(
                        "Restore complete:`n`nRestored: $restored`nFailed: $failed`nSkipped (already exist): $($printers.Count - $restored - $failed)",
                        "Restore Complete",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    )

                    Write-SessionLog -Message "Printer restore completed: $restored restored, $failed failed" -Category "PrinterManagement"

                    # Refresh installed printer list
                    $refreshInstalledBtn.PerformClick()
                }
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to restore printers: $($_.Exception.Message)",
                "Restore Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })
    $installedBtnPanel.Controls.Add($restoreBtn)

    $leftPanel.Controls.Add($installedBtnPanel, 0, 2)
    $script:splitContainer.Panel1.Controls.Add($leftPanel)
    #endregion

    #region Right Panel - Add Printer from Server
    $rightPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rightPanel.RowCount = 4
    $rightPanel.ColumnCount = 1
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 85))) | Out-Null
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null

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

    # SECURITY: Dropdown restricted to allowed print servers only
    $script:serverComboBox = New-Object System.Windows.Forms.ComboBox
    $script:serverComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList  # Prevents typing
    $script:serverComboBox.Width = 200
    foreach ($server in $script:AllowedPrintServers) {
        $script:serverComboBox.Items.Add($server) | Out-Null
    }
    # Select the default server
    $defaultIndex = $script:serverComboBox.Items.IndexOf($script:PrintServer)
    if ($defaultIndex -ge 0) {
        $script:serverComboBox.SelectedIndex = $defaultIndex
    } elseif ($script:serverComboBox.Items.Count -gt 0) {
        $script:serverComboBox.SelectedIndex = 0
    }
    $serverInputPanel.Controls.Add($script:serverComboBox)

    $script:browseServerBtn = New-Object System.Windows.Forms.Button
    $script:browseServerBtn.Text = "Browse"
    $script:browseServerBtn.Width = 65
    $script:browseServerBtn.Height = 30
    $serverInputPanel.Controls.Add($script:browseServerBtn)

    # Line break spacer (forces filter to second line)
    $filterRowSpacer = New-Object System.Windows.Forms.Label
    $filterRowSpacer.Text = ""
    $filterRowSpacer.Width = 2000
    $filterRowSpacer.Height = 1
    $serverInputPanel.Controls.Add($filterRowSpacer)

    $filterLabel = New-Object System.Windows.Forms.Label
    $filterLabel.Text = "Filter:"
    $filterLabel.AutoSize = $true
    $filterLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $serverInputPanel.Controls.Add($filterLabel)

    $script:printerFilterBox = New-Object System.Windows.Forms.TextBox
    $script:printerFilterBox.Width = 200
    $serverInputPanel.Controls.Add($script:printerFilterBox)

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

    # Enable sorting
    $script:serverListView.Sorting = [System.Windows.Forms.SortOrder]::Ascending
    $script:serverListView.Add_ColumnClick({
        param($sender, $e)
        # Toggle sort order on column click
        if ($sender.Sorting -eq [System.Windows.Forms.SortOrder]::Ascending) {
            $sender.Sorting = [System.Windows.Forms.SortOrder]::Descending
        } else {
            $sender.Sorting = [System.Windows.Forms.SortOrder]::Ascending
        }
        # Sort by clicked column (basic alphabetic sort)
        $sender.ListViewItemSorter = New-Object System.Collections.CaseInsensitiveComparer
        $sender.Sort()
    })

    # Auto-resize columns to content after items loaded
    $script:serverListView.Add_ClientSizeChanged({
        foreach ($col in $this.Columns) {
            $col.Width = -1  # Auto-size to content
        }
    })

    $rightPanel.Controls.Add($script:serverListView, 0, 2)

    # Buttons for adding printers
    $serverBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $serverBtnPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $serverBtnPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)

    $addSelectedBtn = New-Object System.Windows.Forms.Button
    $addSelectedBtn.Text = "Add Selected"
    $addSelectedBtn.Width = 110
    $addSelectedBtn.Height = 30
    $addSelectedBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 255, 230)
    $serverBtnPanel.Controls.Add($addSelectedBtn)

    $manualAddBtn = New-Object System.Windows.Forms.Button
    $manualAddBtn.Text = "Add by Path..."
    $manualAddBtn.Width = 95
    $manualAddBtn.Height = 30
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
        $server = $script:serverComboBox.SelectedItem

        if (-not $server) {
            Set-AppError "Enter a server name and click Browse"
            return
        }

        Start-AppActivity "Connecting to $server..."
        $script:ServerPrintersList = & $script:GetServerPrinters -Server $server
        $filter = $script:printerFilterBox.Text.Trim().ToLower()

        if ($script:ServerPrintersList.Count -eq 0) {
            Set-AppError "No printers found on $server - try Add by Path"
            return
        }

        Clear-AppStatus

        $script:serverListView.BeginUpdate()
        foreach ($p in $script:ServerPrintersList) {
            # Apply filter - check if ANY field matches
            if ($filter) {
                $nameMatch = $p.Name -and $p.Name.ToLower() -like "*$filter*"
                $locMatch = $p.Location -and $p.Location.ToLower() -like "*$filter*"
                $commentMatch = $p.Comment -and $p.Comment.ToLower() -like "*$filter*"
                if (-not ($nameMatch -or $locMatch -or $commentMatch)) {
                    continue
                }
            }

            $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
            $locationText = if ($p.Location) { $p.Location } else { "" }
            $commentText = if ($p.Comment) { $p.Comment } else { "" }
            $item.SubItems.Add($locationText) | Out-Null
            $item.SubItems.Add($commentText) | Out-Null
            $item.Tag = $p
            $script:serverListView.Items.Add($item) | Out-Null
        }
        $script:serverListView.EndUpdate()
    }

    $script:ApplyFilter = {
        $script:serverListView.BeginUpdate()
        $script:serverListView.Items.Clear()
        $filter = $script:printerFilterBox.Text.Trim().ToLower()

        foreach ($p in $script:ServerPrintersList) {
            # Apply filter - check if ANY field matches
            if ($filter) {
                $nameMatch = $p.Name -and $p.Name.ToLower() -like "*$filter*"
                $locMatch = $p.Location -and $p.Location.ToLower() -like "*$filter*"
                $commentMatch = $p.Comment -and $p.Comment.ToLower() -like "*$filter*"
                if (-not ($nameMatch -or $locMatch -or $commentMatch)) {
                    continue
                }
            }

            $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
            $locationText = if ($p.Location) { $p.Location } else { "" }
            $commentText = if ($p.Comment) { $p.Comment } else { "" }
            $item.SubItems.Add($locationText) | Out-Null
            $item.SubItems.Add($commentText) | Out-Null
            $item.Tag = $p
            $script:serverListView.Items.Add($item) | Out-Null
        }
        $script:serverListView.EndUpdate()
    }
    #endregion

    #region Event Handlers

    # Refresh installed printers
    $refreshInstalledBtn.Add_Click({
        & $script:RefreshInstalledPrinters
    })

    # Browse server
    $script:browseServerBtn.Add_Click({
        $script:serverListView.Items.Clear()

        # Disable button during load
        $script:browseServerBtn.Enabled = $false
        $script:browseServerBtn.Text = "Loading..."
        [System.Windows.Forms.Application]::DoEvents()

        try {
            & $script:RefreshServerPrinters
        }
        finally {
            # Re-enable button
            $script:browseServerBtn.Enabled = $true
            $script:browseServerBtn.Text = "Browse"
        }
    })

    # Filter text changed
    $script:printerFilterBox.Add_TextChanged({
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
            & $script:PrinterLog "Test Page: No printer selected"
            [System.Windows.Forms.MessageBox]::Show(
                "Please click on a printer in the Installed Printers list first, then click Test Page.",
                "No Printer Selected",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $printerName = $script:installedListView.SelectedItems[0].Text
        & $script:PrinterLog "Selected printer: '$printerName' (length: $($printerName.Length))"
        Start-AppActivity "Sending test page..."
        [System.Windows.Forms.Application]::DoEvents()
        $result = & $script:SendTestPage -PrinterName $printerName
        Clear-AppStatus

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
        $modeText = "all users"
        $totalPrinters = $checkedItems.Count

        & $script:PrinterLog "=== Adding $totalPrinters printer(s) ==="
        Start-AppActivity "Adding printer(s)..."
        [System.Windows.Forms.Application]::DoEvents()

        $currentIndex = 0
        foreach ($printer in $checkedItems) {
            $currentIndex++
            & $script:PrinterLog "[$currentIndex/$totalPrinters] Processing: $($printer.Name)"
            & $script:PrinterLog "  Path: $($printer.FullPath)"
            Set-AppProgress -Value $currentIndex -Maximum $totalPrinters -Message "Adding printer $currentIndex of ${totalPrinters}: $($printer.Name)..."
            [System.Windows.Forms.Application]::DoEvents()

            # Step 1: Add for current user first (fast, no elevation)
            & $script:PrinterLog "  Adding for current user..."
            $result = & $script:AddNetworkPrinter -PrinterPath $printer.FullPath

            if ($result.Success) {
                & $script:PrinterLog "  [OK] Printer added for current user"
                $successCount++

                # Step 2: Persist for all users (fire-and-forget, runs in background)
                & $script:PrinterLog "  Persisting for all users (background)..."
                $allUsersResult = & $script:AddNetworkPrinterAllUsers -PrinterPath $printer.FullPath
                if ($allUsersResult.Success) {
                    & $script:PrinterLog "  [OK] All-users persistence queued"
                }
                else {
                    & $script:PrinterLog "  ! Warning: All-users persistence failed: $($allUsersResult.Error)"
                    & $script:PrinterLog "    (Printer still works for current user)"
                }
            }
            else {
                & $script:PrinterLog "  [FAIL] FAILED: $($result.Error)"
                $failedPrinters += "$($printer.Name): $($result.Error)"
            }

            [System.Windows.Forms.Application]::DoEvents()
        }

        & $script:PrinterLog "Refreshing installed printer list..."
        Clear-AppStatus

        if ($failedPrinters.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Successfully added $successCount printer(s) for $modeText.",
                "Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
        else {
            $message = "Added $successCount printer(s) for ${modeText}.`n`nFailed:`n" + ($failedPrinters -join "`n")
            [System.Windows.Forms.MessageBox]::Show(
                $message,
                "Partial Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }

        & $script:RefreshInstalledPrinters
        & $script:PrinterLog "[OK] Complete! Added $successCount printer(s) successfully."
        if ($failedPrinters.Count -gt 0) {
            & $script:PrinterLog "[FAIL] Failed: $($failedPrinters.Count) printer(s)"
        }
    })

    # Manual add by path - SECURITY: Server dropdown + printer name only
    $manualAddBtn.Add_Click({
        $inputForm = New-Object System.Windows.Forms.Form
        $inputForm.Text = "Add Printer Manually"
        $inputForm.Size = New-Object System.Drawing.Size(400, 180)
        $inputForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $inputForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $inputForm.MaximizeBox = $false
        $inputForm.MinimizeBox = $false

        # Server dropdown (restricted to allowlist)
        $serverLabel = New-Object System.Windows.Forms.Label
        $serverLabel.Text = "Print Server:"
        $serverLabel.Location = New-Object System.Drawing.Point(10, 15)
        $serverLabel.AutoSize = $true
        $inputForm.Controls.Add($serverLabel)

        $dialogServerCombo = New-Object System.Windows.Forms.ComboBox
        $dialogServerCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        $dialogServerCombo.Location = New-Object System.Drawing.Point(100, 12)
        $dialogServerCombo.Width = 270
        foreach ($server in $script:AllowedPrintServers) {
            $dialogServerCombo.Items.Add($server) | Out-Null
        }
        # Default to currently selected server
        $currentServer = $script:serverComboBox.SelectedItem
        $serverIndex = $dialogServerCombo.Items.IndexOf($currentServer)
        if ($serverIndex -ge 0) {
            $dialogServerCombo.SelectedIndex = $serverIndex
        } elseif ($dialogServerCombo.Items.Count -gt 0) {
            $dialogServerCombo.SelectedIndex = 0
        }
        $inputForm.Controls.Add($dialogServerCombo)

        # Printer name input
        $printerLabel = New-Object System.Windows.Forms.Label
        $printerLabel.Text = "Printer Name:"
        $printerLabel.Location = New-Object System.Drawing.Point(10, 50)
        $printerLabel.AutoSize = $true
        $inputForm.Controls.Add($printerLabel)

        $printerNameTextBox = New-Object System.Windows.Forms.TextBox
        $printerNameTextBox.Location = New-Object System.Drawing.Point(100, 47)
        $printerNameTextBox.Width = 270
        $inputForm.Controls.Add($printerNameTextBox)

        # Preview label
        $previewLabel = New-Object System.Windows.Forms.Label
        $previewLabel.Text = "Path: (select server and enter printer name)"
        $previewLabel.Location = New-Object System.Drawing.Point(10, 80)
        $previewLabel.AutoSize = $true
        $previewLabel.ForeColor = [System.Drawing.Color]::Gray
        $inputForm.Controls.Add($previewLabel)

        # Update preview when either control changes
        $updatePreview = {
            $server = $dialogServerCombo.SelectedItem
            $name = $printerNameTextBox.Text.Trim()
            if ($server -and $name) {
                $previewLabel.Text = "Path: $server\$name"
                $previewLabel.ForeColor = [System.Drawing.Color]::DarkGreen
            } else {
                $previewLabel.Text = "Path: (select server and enter printer name)"
                $previewLabel.ForeColor = [System.Drawing.Color]::Gray
            }
        }
        $dialogServerCombo.Add_SelectedIndexChanged($updatePreview)
        $printerNameTextBox.Add_TextChanged($updatePreview)

        $okBtn = New-Object System.Windows.Forms.Button
        $okBtn.Text = "Add"
        $okBtn.Location = New-Object System.Drawing.Point(210, 110)
        $okBtn.Width = 75
        $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $inputForm.Controls.Add($okBtn)

        $cancelBtn = New-Object System.Windows.Forms.Button
        $cancelBtn.Text = "Cancel"
        $cancelBtn.Location = New-Object System.Drawing.Point(295, 110)
        $cancelBtn.Width = 75
        $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $inputForm.Controls.Add($cancelBtn)

        $inputForm.AcceptButton = $okBtn
        $inputForm.CancelButton = $cancelBtn

        if ($inputForm.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $selectedServer = $dialogServerCombo.SelectedItem
            $printerName = $printerNameTextBox.Text.Trim()

            if (-not $selectedServer) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Please select a print server.",
                    "Missing Server",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                return
            }

            if (-not $printerName) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Please enter a printer name.",
                    "Missing Printer Name",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                return
            }

            # Sanitize printer name - remove any path characters
            $printerName = $printerName -replace '[\\\/]', ''

            # Build the full path from validated components
            $printerPath = "$selectedServer\$printerName"

            $modeText = "all users"

            & $script:PrinterLog "=== Manual printer add ==="
            & $script:PrinterLog "Printer: $printerName"
            & $script:PrinterLog "Path: $printerPath"
            Start-AppActivity "Adding printer: $printerName..."
            [System.Windows.Forms.Application]::DoEvents()

            # Step 1: Add for current user first (fast, no elevation)
            & $script:PrinterLog "Adding for current user..."
            $result = & $script:AddNetworkPrinter -PrinterPath $printerPath

            if ($result.Success) {
                & $script:PrinterLog "[OK] Printer added for current user"

                # Step 2: Persist for all users (fire-and-forget, background)
                & $script:PrinterLog "Persisting for all users (background)..."
                $allUsersResult = & $script:AddNetworkPrinterAllUsers -PrinterPath $printerPath
                if ($allUsersResult.Success) {
                    & $script:PrinterLog "[OK] All-users persistence queued"
                }
                else {
                    & $script:PrinterLog "! Warning: All-users persistence failed: $($allUsersResult.Error)"
                    & $script:PrinterLog "  (Printer still works for current user)"
                }
            }
            else {
                & $script:PrinterLog "[FAIL] FAILED: $($result.Error)"
            }

            & $script:PrinterLog "Refreshing installed printer list..."
            Clear-AppStatus

            if ($result.Success) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Printer added successfully for ${modeText}.`n`nPath: $printerPath",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                & $script:RefreshInstalledPrinters
                & $script:PrinterLog "[OK] Complete!"
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
        $inputForm.Dispose()
    })

    #endregion

    # Main layout - split container on top, log box on bottom
    $mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $mainLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainLayout.RowCount = 2
    $mainLayout.ColumnCount = 1
    $mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 70))) | Out-Null
    $mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 30))) | Out-Null

    # Add split container to top row
    $mainLayout.Controls.Add($script:splitContainer, 0, 0)

    # Log box at bottom
    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = "Activity Log"
    $logGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:printerLogBox = New-Object System.Windows.Forms.RichTextBox
    $script:printerLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:printerLogBox.ReadOnly = $true
    $script:printerLogBox.BackColor = [System.Drawing.Color]::White
    $script:printerLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:printerLogBox.WordWrap = $false
    $logGroup.Controls.Add($script:printerLogBox)

    $mainLayout.Controls.Add($logGroup, 0, 1)

    # Add to tab
    $tab.Controls.Add($mainLayout)

    # Set splitter position to 50/50 after form is sized
    $tab.Add_SizeChanged({
        if ($script:splitContainer.Width -gt 0) {
            $script:splitContainer.SplitterDistance = [int]($script:splitContainer.Width / 2)
        }
    })

    # Initial log message
    & $script:PrinterLog "Printer Management module loaded."
    & $script:PrinterLog "Ready to add, remove, and manage network printers."
    & $script:PrinterLog ""

    # Initial load - installed printers (with error handling for Windows 10 compatibility)
    try {
        & $script:RefreshInstalledPrinters
    }
    catch {
        Write-SessionLog -Message "Failed to load installed printers during module init: $($_.Exception.Message)" -Category "Printer Management"
        & $script:PrinterLog "Warning: Could not load installed printers automatically."
        # UI will still load, user can manually refresh
    }

    # Auto-load server printers if default server is configured (with error handling)
    if ($script:PrintServer) {
        try {
            & $script:RefreshServerPrinters
        }
        catch {
            Write-SessionLog -Message "Failed to auto-load server printers during module init: $($_.Exception.Message)" -Category "Printer Management"
            & $script:PrinterLog "Warning: Could not load server printers automatically."
            # UI will still load, user can manually browse
        }
    }

    # Show compatibility note if PrintManagement module not available
    if (-not $script:HasPrintManagement) {
        Set-AppStatus "Note: Using Windows 10 compatibility mode (WMI-based printer management)"
    }
}
