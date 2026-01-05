<#
.SYNOPSIS
    System Information Module for Windows Tech Toolkit
.DESCRIPTION
    Displays system information and provides quick access to common admin tools.
    Tests the elevation system with battery report generation.
#>

$script:ModuleName = "System Info"
$script:ModuleDescription = "View system information and launch admin tools"

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Main layout panel
    $mainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.RowCount = 2
    $mainPanel.ColumnCount = 1
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null

    #region Top Panel - System Info Display
    $topPanel = New-Object System.Windows.Forms.Panel
    $topPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $topPanel.Padding = New-Object System.Windows.Forms.Padding(10)

    # Info GroupBox
    $infoGroup = New-Object System.Windows.Forms.GroupBox
    $infoGroup.Text = "System Information"
    $infoGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $infoGroup.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    # Info TextBox
    $infoTextBox = New-Object System.Windows.Forms.TextBox
    $infoTextBox.Multiline = $true
    $infoTextBox.ReadOnly = $true
    $infoTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $infoTextBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $infoTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $infoTextBox.BackColor = [System.Drawing.Color]::White

    # Gather system info
    $sysInfo = Get-SystemInfo
    $infoTextBox.Text = $sysInfo
    $infoTextBox.SelectionStart = 0
    $infoTextBox.SelectionLength = 0

    $infoGroup.Controls.Add($infoTextBox)
    $topPanel.Controls.Add($infoGroup)
    #endregion

    #region Bottom Panel - Buttons and Log
    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    # Button panel
    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $buttonPanel.Height = 100
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(5)
    $buttonPanel.WrapContents = $true

    # Refresh button
    $refreshBtn = New-Object System.Windows.Forms.Button
    $refreshBtn.Text = "Refresh"
    $refreshBtn.Width = 100
    $refreshBtn.Height = 35
    $refreshBtn.Add_Click({
        $infoTextBox.Text = Get-SystemInfo
        $infoTextBox.SelectionStart = 0
        Write-Log -TextBox $logBox -Message "System info refreshed"
    })
    $buttonPanel.Controls.Add($refreshBtn)

    # Copy to Clipboard button
    $copyBtn = New-Object System.Windows.Forms.Button
    $copyBtn.Text = "Copy to Clipboard"
    $copyBtn.Width = 120
    $copyBtn.Height = 35
    $copyBtn.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($infoTextBox.Text)
        Write-Log -TextBox $logBox -Message "System info copied to clipboard"
    })
    $buttonPanel.Controls.Add($copyBtn)

    # Separator label
    $sep1 = New-Object System.Windows.Forms.Label
    $sep1.Text = "|"
    $sep1.AutoSize = $true
    $sep1.Padding = New-Object System.Windows.Forms.Padding(5, 10, 5, 0)
    $buttonPanel.Controls.Add($sep1)

    # Launch Tools buttons
    $devMgrBtn = New-Object System.Windows.Forms.Button
    $devMgrBtn.Text = "Device Manager"
    $devMgrBtn.Width = 110
    $devMgrBtn.Height = 35
    $devMgrBtn.Add_Click({
        Start-Process "devmgmt.msc"
        Write-Log -TextBox $logBox -Message "Launched Device Manager"
    })
    $buttonPanel.Controls.Add($devMgrBtn)

    $taskMgrBtn = New-Object System.Windows.Forms.Button
    $taskMgrBtn.Text = "Task Manager"
    $taskMgrBtn.Width = 100
    $taskMgrBtn.Height = 35
    $taskMgrBtn.Add_Click({
        Start-Process "taskmgr.exe"
        Write-Log -TextBox $logBox -Message "Launched Task Manager"
    })
    $buttonPanel.Controls.Add($taskMgrBtn)

    $eventViewerBtn = New-Object System.Windows.Forms.Button
    $eventViewerBtn.Text = "Event Viewer"
    $eventViewerBtn.Width = 100
    $eventViewerBtn.Height = 35
    $eventViewerBtn.Add_Click({
        Start-Process "eventvwr.msc"
        Write-Log -TextBox $logBox -Message "Launched Event Viewer"
    })
    $buttonPanel.Controls.Add($eventViewerBtn)

    $servicesBtn = New-Object System.Windows.Forms.Button
    $servicesBtn.Text = "Services"
    $servicesBtn.Width = 80
    $servicesBtn.Height = 35
    $servicesBtn.Add_Click({
        Start-Process "services.msc"
        Write-Log -TextBox $logBox -Message "Launched Services"
    })
    $buttonPanel.Controls.Add($servicesBtn)

    # Second row - Elevation test and power options
    $sep2 = New-Object System.Windows.Forms.Label
    $sep2.Text = ""
    $sep2.Width = 800
    $buttonPanel.Controls.Add($sep2)

    # Battery Report button (requires elevation)
    $batteryBtn = New-Object System.Windows.Forms.Button
    $batteryBtn.Text = "Battery Report *"
    $batteryBtn.Width = 110
    $batteryBtn.Height = 35
    $batteryBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    $batteryBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $batteryBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 180, 100)
    $batteryBtn.Add_Click({
        Write-Log -TextBox $logBox -Message "Generating battery report (requires admin)..."

        $reportPath = "$env:USERPROFILE\Desktop\battery-report.html"

        $result = Invoke-Elevated -ScriptBlock {
            param($path)
            powercfg /batteryreport /output $path
            return $path
        } -ArgumentList $reportPath -OperationName "generate battery report"

        if ($result.Success) {
            Write-Log -TextBox $logBox -Message "SUCCESS: Battery report saved to Desktop"
            Start-Process $reportPath
        }
        else {
            Write-Log -TextBox $logBox -Message "ERROR: $($result.Error)"
        }
    })
    $buttonPanel.Controls.Add($batteryBtn)

    # MSInfo32 button
    $msInfoBtn = New-Object System.Windows.Forms.Button
    $msInfoBtn.Text = "Full MSInfo32"
    $msInfoBtn.Width = 100
    $msInfoBtn.Height = 35
    $msInfoBtn.Add_Click({
        Start-Process "msinfo32.exe"
        Write-Log -TextBox $logBox -Message "Launched MSInfo32"
    })
    $buttonPanel.Controls.Add($msInfoBtn)

    # Separator
    $sep3 = New-Object System.Windows.Forms.Label
    $sep3.Text = "|"
    $sep3.AutoSize = $true
    $sep3.Padding = New-Object System.Windows.Forms.Padding(5, 10, 5, 0)
    $buttonPanel.Controls.Add($sep3)

    # Reboot button
    $rebootBtn = New-Object System.Windows.Forms.Button
    $rebootBtn.Text = "Reboot"
    $rebootBtn.Width = 80
    $rebootBtn.Height = 35
    $rebootBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 200, 200)
    $rebootBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Are you sure you want to reboot this computer?",
            "Confirm Reboot",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log -TextBox $logBox -Message "Initiating reboot..."
            shutdown /r /t 30 /c "Reboot initiated by Tech Toolkit"
        }
    })
    $buttonPanel.Controls.Add($rebootBtn)

    # Shutdown button
    $shutdownBtn = New-Object System.Windows.Forms.Button
    $shutdownBtn.Text = "Shutdown"
    $shutdownBtn.Width = 80
    $shutdownBtn.Height = 35
    $shutdownBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 200, 200)
    $shutdownBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Are you sure you want to shut down this computer?",
            "Confirm Shutdown",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log -TextBox $logBox -Message "Initiating shutdown..."
            shutdown /s /t 30 /c "Shutdown initiated by Tech Toolkit"
        }
    })
    $buttonPanel.Controls.Add($shutdownBtn)

    # Note label
    $noteLabel = New-Object System.Windows.Forms.Label
    $noteLabel.Text = "* Requires admin credentials"
    $noteLabel.AutoSize = $true
    $noteLabel.ForeColor = [System.Drawing.Color]::Gray
    $noteLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $noteLabel.Padding = New-Object System.Windows.Forms.Padding(10, 12, 0, 0)
    $buttonPanel.Controls.Add($noteLabel)

    # Log output box
    $logBox = New-OutputTextBox
    $logBox.Height = 100

    $bottomPanel.Controls.Add($logBox)
    $bottomPanel.Controls.Add($buttonPanel)
    #endregion

    # Add panels to main layout
    $mainPanel.Controls.Add($topPanel, 0, 0)
    $mainPanel.Controls.Add($bottomPanel, 0, 1)

    $tab.Controls.Add($mainPanel)

    # Initial log entry
    Write-Log -TextBox $logBox -Message "System Info module loaded"
}

function Get-SystemInfo {
    <#
    .SYNOPSIS
        Gathers comprehensive system information.
    #>
    $info = [System.Text.StringBuilder]::new()

    try {
        # Computer Info
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

        [void]$info.AppendLine("═══════════════════════════════════════════════════════")
        [void]$info.AppendLine("  SYSTEM INFORMATION")
        [void]$info.AppendLine("═══════════════════════════════════════════════════════")
        [void]$info.AppendLine("")

        # Computer
        [void]$info.AppendLine("  COMPUTER")
        [void]$info.AppendLine("  ────────────────────────────────────────────────────")
        [void]$info.AppendLine("  Computer Name:    $env:COMPUTERNAME")
        if ($cs) {
            [void]$info.AppendLine("  Manufacturer:     $($cs.Manufacturer)")
            [void]$info.AppendLine("  Model:            $($cs.Model)")
        }
        if ($bios) {
            [void]$info.AppendLine("  Serial Number:    $($bios.SerialNumber)")
        }
        [void]$info.AppendLine("")

        # Operating System
        [void]$info.AppendLine("  OPERATING SYSTEM")
        [void]$info.AppendLine("  ────────────────────────────────────────────────────")
        if ($os) {
            [void]$info.AppendLine("  OS Name:          $($os.Caption)")
            [void]$info.AppendLine("  Version:          $($os.Version)")
            [void]$info.AppendLine("  Build:            $($os.BuildNumber)")
            [void]$info.AppendLine("  Architecture:     $($os.OSArchitecture)")

            # Uptime
            $uptime = (Get-Date) - $os.LastBootUpTime
            $uptimeStr = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
            [void]$info.AppendLine("  Last Boot:        $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'))")
            [void]$info.AppendLine("  Uptime:           $uptimeStr")
        }
        [void]$info.AppendLine("")

        # Domain/Workgroup
        [void]$info.AppendLine("  NETWORK IDENTITY")
        [void]$info.AppendLine("  ────────────────────────────────────────────────────")
        if ($cs) {
            if ($cs.PartOfDomain) {
                [void]$info.AppendLine("  Domain:           $($cs.Domain)")

                # Check trust relationship
                try {
                    $trust = Test-ComputerSecureChannel -ErrorAction Stop
                    $trustStatus = if ($trust) { "HEALTHY" } else { "BROKEN" }
                }
                catch {
                    $trustStatus = "UNKNOWN (check failed)"
                }
                [void]$info.AppendLine("  Trust Status:     $trustStatus")
            }
            else {
                [void]$info.AppendLine("  Workgroup:        $($cs.Workgroup)")
            }
        }
        [void]$info.AppendLine("  Current User:     $env:USERDOMAIN\$env:USERNAME")
        [void]$info.AppendLine("")

        # Hardware
        [void]$info.AppendLine("  HARDWARE")
        [void]$info.AppendLine("  ────────────────────────────────────────────────────")
        if ($cpu) {
            [void]$info.AppendLine("  CPU:              $($cpu.Name.Trim())")
            [void]$info.AppendLine("  Cores:            $($cpu.NumberOfCores) cores, $($cpu.NumberOfLogicalProcessors) threads")
        }
        if ($cs) {
            $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            [void]$info.AppendLine("  RAM:              $ramGB GB")
        }
        [void]$info.AppendLine("")

        # Disk Space
        [void]$info.AppendLine("  STORAGE")
        [void]$info.AppendLine("  ────────────────────────────────────────────────────")
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        foreach ($disk in $disks) {
            $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
            $totalGB = [math]::Round($disk.Size / 1GB, 1)
            $usedPercent = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 0)
            [void]$info.AppendLine("  $($disk.DeviceID)              $freeGB GB free / $totalGB GB ($usedPercent% used)")
        }
        [void]$info.AppendLine("")

        # Network
        [void]$info.AppendLine("  NETWORK")
        [void]$info.AppendLine("  ────────────────────────────────────────────────────")
        $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" }
        foreach ($adapter in $adapters) {
            $ifName = (Get-NetAdapter -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue).Name
            if ($ifName) {
                [void]$info.AppendLine("  $($ifName): $($adapter.IPAddress)")
            }
        }

        [void]$info.AppendLine("")
        [void]$info.AppendLine("═══════════════════════════════════════════════════════")
        [void]$info.AppendLine("  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        [void]$info.AppendLine("═══════════════════════════════════════════════════════")
    }
    catch {
        [void]$info.AppendLine("Error gathering system information: $_")
    }

    return $info.ToString()
}
