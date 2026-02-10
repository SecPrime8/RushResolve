<#
.SYNOPSIS
    System Information Module for Rush Resolve
.DESCRIPTION
    Displays system information and provides quick access to common admin tools.
#>

$script:ModuleName = "System Info"
$script:ModuleDescription = "View system information and launch admin tools"

# Use script block instead of function to avoid scope issues
$script:GetSysInfoData = {
    $info = [System.Text.StringBuilder]::new()

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

        [void]$info.AppendLine("=========================================================")
        [void]$info.AppendLine("  SYSTEM INFORMATION")
        [void]$info.AppendLine("=========================================================")
        [void]$info.AppendLine("")

        [void]$info.AppendLine("  COMPUTER")
        [void]$info.AppendLine("  ---------------------------------------------------------")
        [void]$info.AppendLine("  Computer Name:    $env:COMPUTERNAME")
        if ($cs) {
            [void]$info.AppendLine("  Manufacturer:     $($cs.Manufacturer)")
            [void]$info.AppendLine("  Model:            $($cs.Model)")
        }
        if ($bios) {
            [void]$info.AppendLine("  Serial Number:    $($bios.SerialNumber)")
        }
        [void]$info.AppendLine("")

        [void]$info.AppendLine("  OPERATING SYSTEM")
        [void]$info.AppendLine("  ---------------------------------------------------------")
        if ($os) {
            [void]$info.AppendLine("  OS Name:          $($os.Caption)")
            [void]$info.AppendLine("  Version:          $($os.Version)")
            [void]$info.AppendLine("  Build:            $($os.BuildNumber)")
            [void]$info.AppendLine("  Architecture:     $($os.OSArchitecture)")
            $uptime = (Get-Date) - $os.LastBootUpTime
            $uptimeStr = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
            [void]$info.AppendLine("  Last Boot:        $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'))")
            [void]$info.AppendLine("  Uptime:           $uptimeStr")
        }
        [void]$info.AppendLine("")

        [void]$info.AppendLine("  NETWORK IDENTITY")
        [void]$info.AppendLine("  ---------------------------------------------------------")
        if ($cs) {
            if ($cs.PartOfDomain) {
                [void]$info.AppendLine("  Domain:           $($cs.Domain)")
                try {
                    $trust = Test-ComputerSecureChannel -ErrorAction Stop
                    $trustStatus = if ($trust) { "HEALTHY" } else { "BROKEN" }
                }
                catch {
                    $trustStatus = "N/A (not domain joined or check failed)"
                }
                [void]$info.AppendLine("  Trust Status:     $trustStatus")
            }
            else {
                [void]$info.AppendLine("  Workgroup:        $($cs.Workgroup)")
            }
        }
        [void]$info.AppendLine("  Current User:     $env:USERDOMAIN\$env:USERNAME")
        [void]$info.AppendLine("")

        [void]$info.AppendLine("  HARDWARE")
        [void]$info.AppendLine("  ---------------------------------------------------------")
        if ($cpu) {
            [void]$info.AppendLine("  CPU:              $($cpu.Name.Trim())")
            [void]$info.AppendLine("  Cores:            $($cpu.NumberOfCores) cores, $($cpu.NumberOfLogicalProcessors) threads")
        }
        if ($cs) {
            $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            [void]$info.AppendLine("  RAM:              $ramGB GB")
        }
        [void]$info.AppendLine("")

        [void]$info.AppendLine("  STORAGE")
        [void]$info.AppendLine("  ---------------------------------------------------------")
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        foreach ($disk in $disks) {
            $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
            $totalGB = [math]::Round($disk.Size / 1GB, 1)
            $usedPercent = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 0)
            [void]$info.AppendLine("  $($disk.DeviceID)              $freeGB GB free / $totalGB GB ($usedPercent% used)")
        }
        [void]$info.AppendLine("")

        [void]$info.AppendLine("  NETWORK")
        [void]$info.AppendLine("  ---------------------------------------------------------")
        # Only show adapters that are Up (connected)
        $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" }
        foreach ($adapter in $adapters) {
            $netAdapter = Get-NetAdapter -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
            if ($netAdapter -and $netAdapter.Status -eq 'Up') {
                [void]$info.AppendLine("  $($netAdapter.Name):")
                [void]$info.AppendLine("    IP:   $($adapter.IPAddress)")
                [void]$info.AppendLine("    MAC:  $($netAdapter.MacAddress)")
            }
        }

        [void]$info.AppendLine("")
        [void]$info.AppendLine("=========================================================")
        [void]$info.AppendLine("  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        [void]$info.AppendLine("=========================================================")
    }
    catch {
        [void]$info.AppendLine("Error gathering system information: $_")
    }

    return $info.ToString()
}

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Main layout
    $mainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.RowCount = 2
    $mainPanel.ColumnCount = 1
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 65))) | Out-Null
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 35))) | Out-Null

    # Top Panel - System Info
    $topPanel = New-Object System.Windows.Forms.Panel
    $topPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $topPanel.Padding = New-Object System.Windows.Forms.Padding(10)

    $infoGroup = New-Object System.Windows.Forms.GroupBox
    $infoGroup.Text = "System Information"
    $infoGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $infoGroup.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    $script:infoTextBox = New-Object System.Windows.Forms.TextBox
    $script:infoTextBox.Multiline = $true
    $script:infoTextBox.ReadOnly = $true
    $script:infoTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:infoTextBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:infoTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:infoTextBox.BackColor = [System.Drawing.Color]::White

    # Invoke script block with &
    $script:infoTextBox.Text = (& $script:GetSysInfoData)

    $infoGroup.Controls.Add($script:infoTextBox)
    $topPanel.Controls.Add($infoGroup)

    # Bottom Panel - Buttons
    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $buttonPanel.Height = 90
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(5)
    $buttonPanel.WrapContents = $true

    # Capture references for closures
    $textBoxRef = $script:infoTextBox
    $scriptBlockRef = $script:GetSysInfoData

    # Refresh button
    $refreshBtn = New-Object System.Windows.Forms.Button
    $refreshBtn.Text = "Refresh"
    $refreshBtn.Width = 80
    $refreshBtn.Height = 30
    $refreshBtn.Add_Click({
        param($sender, $e)
        $textBoxRef.Text = (& $scriptBlockRef)
    }.GetNewClosure())
    $buttonPanel.Controls.Add($refreshBtn)

    # Copy button
    $copyBtn = New-Object System.Windows.Forms.Button
    $copyBtn.Text = "Copy"
    $copyBtn.Width = 60
    $copyBtn.Height = 30
    $copyBtn.Add_Click({
        param($sender, $e)
        if ($textBoxRef.Text) {
            [System.Windows.Forms.Clipboard]::SetText($textBoxRef.Text)
            [System.Windows.Forms.MessageBox]::Show("Copied to clipboard!", "Info", [System.Windows.Forms.MessageBoxButtons]::OK)
        }
    }.GetNewClosure())
    $buttonPanel.Controls.Add($copyBtn)

    # Separator
    $sep1 = New-Object System.Windows.Forms.Label
    $sep1.Text = " | "
    $sep1.AutoSize = $true
    $sep1.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $buttonPanel.Controls.Add($sep1)

    # Device Manager (elevated - uses cached credentials)
    $devMgrBtn = New-Object System.Windows.Forms.Button
    $devMgrBtn.Text = "Device Mgr"
    $devMgrBtn.Width = 105
    $devMgrBtn.Height = 30
    $devMgrBtn.Add_Click({
        Start-ElevatedProcess -FilePath "mmc.exe" -ArgumentList "devmgmt.msc" -OperationName "open Device Manager"
    })
    $buttonPanel.Controls.Add($devMgrBtn)

    # Task Manager (elevated - shows all processes)
    $taskMgrBtn = New-Object System.Windows.Forms.Button
    $taskMgrBtn.Text = "Task Mgr"
    $taskMgrBtn.Width = 75
    $taskMgrBtn.Height = 30
    $taskMgrBtn.Add_Click({
        Start-ElevatedProcess -FilePath "taskmgr.exe" -OperationName "open Task Manager"
    })
    $buttonPanel.Controls.Add($taskMgrBtn)

    # Event Viewer (elevated - full log access)
    $eventBtn = New-Object System.Windows.Forms.Button
    $eventBtn.Text = "Events"
    $eventBtn.Width = 60
    $eventBtn.Height = 30
    $eventBtn.Add_Click({
        Start-ElevatedProcess -FilePath "mmc.exe" -ArgumentList "eventvwr.msc" -OperationName "open Event Viewer"
    })
    $buttonPanel.Controls.Add($eventBtn)

    # Services (elevated - can start/stop services)
    $svcBtn = New-Object System.Windows.Forms.Button
    $svcBtn.Text = "Services"
    $svcBtn.Width = 70
    $svcBtn.Height = 30
    $svcBtn.Add_Click({
        Start-ElevatedProcess -FilePath "mmc.exe" -ArgumentList "services.msc" -OperationName "open Services"
    })
    $buttonPanel.Controls.Add($svcBtn)

    # Separator for Admin Consoles
    $sep2 = New-Object System.Windows.Forms.Label
    $sep2.Text = " | "
    $sep2.AutoSize = $true
    $sep2.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $buttonPanel.Controls.Add($sep2)

    # Active Directory Users and Computers (elevated)
    $adBtn = New-Object System.Windows.Forms.Button
    $adBtn.Text = "AD Users"
    $adBtn.Width = 75
    $adBtn.Height = 30
    $adBtn.Add_Click({
        # Check if RSAT (Remote Server Administration Tools) is installed
        $dsaPath = Join-Path $env:SystemRoot "System32\dsa.msc"

        if (Test-Path $dsaPath) {
            Start-ElevatedProcess -FilePath "mmc.exe" -ArgumentList "dsa.msc" -OperationName "open Active Directory Users and Computers"
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "Active Directory Users and Computers (dsa.msc) not found.`n`n" +
                "RSAT (Remote Server Administration Tools) must be installed.`n`n" +
                "To install RSAT:`n" +
                "1. Open Settings > Apps > Optional Features`n" +
                "2. Click 'Add a feature'`n" +
                "3. Search for 'RSAT: Active Directory'`n" +
                "4. Install 'RSAT: Active Directory Domain Services and Lightweight Directory Services Tools'`n`n" +
                "Or use PowerShell (as Administrator):`n" +
                "Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0",
                "RSAT Not Installed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            Write-SessionLog -Message "AD Users button clicked but RSAT not installed" -Category "System Info" -Result "Error: dsa.msc not found"
        }
    })
    $buttonPanel.Controls.Add($adBtn)

    # SCCM Console (elevated)
    $sccmBtn = New-Object System.Windows.Forms.Button
    $sccmBtn.Text = "SCCM"
    $sccmBtn.Width = 60
    $sccmBtn.Height = 30
    $sccmBtn.Add_Click({
        # Check common SCCM console paths
        $sccmPaths = @(
            "${env:ProgramFiles(x86)}\Microsoft Endpoint Manager\AdminConsole\bin\Microsoft.ConfigurationManagement.exe",
            "${env:ProgramFiles(x86)}\Microsoft Configuration Manager\AdminConsole\bin\Microsoft.ConfigurationManagement.exe",
            "${env:ProgramFiles}\Microsoft Endpoint Manager\AdminConsole\bin\Microsoft.ConfigurationManagement.exe",
            "${env:ProgramFiles}\Microsoft Configuration Manager\AdminConsole\bin\Microsoft.ConfigurationManagement.exe"
        )
        $sccmPath = $sccmPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($sccmPath) {
            Start-ElevatedProcess -FilePath $sccmPath -OperationName "open SCCM Console"
        } else {
            [System.Windows.Forms.MessageBox]::Show("SCCM Console not found.`n`nExpected locations:`n- Program Files (x86)\Microsoft Endpoint Manager\AdminConsole`n- Program Files (x86)\Microsoft Configuration Manager\AdminConsole", "SCCM Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    $buttonPanel.Controls.Add($sccmBtn)

    # MSInfo32
    $msInfoBtn = New-Object System.Windows.Forms.Button
    $msInfoBtn.Text = "MSInfo32"
    $msInfoBtn.Width = 75
    $msInfoBtn.Height = 30
    $msInfoBtn.Add_Click({ Start-Process "msinfo32.exe" })
    $buttonPanel.Controls.Add($msInfoBtn)

    # Memory Diagnostic
    $memDiagBtn = New-Object System.Windows.Forms.Button
    $memDiagBtn.Text = "Memory Test"
    $memDiagBtn.Width = 110
    $memDiagBtn.Height = 30
    $memDiagBtn.Add_Click({
        $msg = "Windows Memory Diagnostic will check your RAM for errors.`n`nThe computer must restart to run the test.`n`nSchedule memory test?"
        $confirm = [System.Windows.Forms.MessageBox]::Show($msg, "Memory Diagnostic", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-SessionLog -Message "Memory Diagnostic scheduled via mdsched.exe" -Category "System Info"
            Start-ElevatedProcess -FilePath "mdsched.exe" -OperationName "schedule Memory Diagnostic"
        }
    })
    $buttonPanel.Controls.Add($memDiagBtn)

    # Separator before power buttons
    $sep2 = New-Object System.Windows.Forms.Label
    $sep2.Text = " | "
    $sep2.AutoSize = $true
    $sep2.Padding = New-Object System.Windows.Forms.Padding(5, 8, 5, 0)
    $buttonPanel.Controls.Add($sep2)

    # Reboot
    $rebootBtn = New-Object System.Windows.Forms.Button
    $rebootBtn.Text = "Reboot"
    $rebootBtn.Width = 70
    $rebootBtn.Height = 30
    $rebootBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 220, 220)
    $rebootBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show("Reboot this computer?", "Confirm", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-SessionLog -Message "REBOOT initiated (30 second delay)" -Category "System Info"
            shutdown /r /t 30 /c "Reboot initiated by Rush Resolve"
        }
    })
    $buttonPanel.Controls.Add($rebootBtn)

    # Shutdown
    $shutdownBtn = New-Object System.Windows.Forms.Button
    $shutdownBtn.Text = "Shutdown"
    $shutdownBtn.Width = 90
    $shutdownBtn.Height = 30
    $shutdownBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 220, 220)
    $shutdownBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show("Shut down this computer?", "Confirm", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-SessionLog -Message "SHUTDOWN initiated (30 second delay)" -Category "System Info"
            shutdown /s /t 30 /c "Shutdown initiated by Rush Resolve"
        }
    })
    $buttonPanel.Controls.Add($shutdownBtn)

    $bottomPanel.Controls.Add($buttonPanel)

    $mainPanel.Controls.Add($topPanel, 0, 0)
    $mainPanel.Controls.Add($bottomPanel, 0, 1)

    $tab.Controls.Add($mainPanel)
}
