<#
.SYNOPSIS
    Workstation Module for Rush Resolve
.DESCRIPTION
    Displays workstation information and provides quick access to
    elevated admin tools grouped by category.
#>

$script:ModuleName = "Workstation"
$script:ModuleDescription = "View workstation info and launch elevated admin tools"

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
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 55))) | Out-Null
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 45))) | Out-Null

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

    # Bottom Panel - Scrollable launcher area with categorized groups
    $script:bottomPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $script:bottomPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:bottomPanel.AutoScroll = $true
    $script:bottomPanel.ColumnCount = 1
    $script:bottomPanel.Padding = New-Object System.Windows.Forms.Padding(5)
    $script:bottomPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null

    # Helper to add a row with autosize style
    $addAutoRow = {
        param($ctl)
        $script:bottomPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
        $script:bottomPanel.Controls.Add($ctl)
    }

    # --- Row 1: Info Actions (Refresh / Copy) ---
    $script:row1 = New-Object System.Windows.Forms.FlowLayoutPanel
    $script:row1.AutoSize = $true
    $script:row1.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $script:row1.Dock = [System.Windows.Forms.DockStyle]::Top
    $script:row1.Padding = New-Object System.Windows.Forms.Padding(5, 5, 5, 5)
    $script:row1.WrapContents = $false

    $script:refreshBtn = New-Object System.Windows.Forms.Button
    $script:refreshBtn.Text = "Refresh"
    $script:refreshBtn.AutoSize = $true
    $script:refreshBtn.Height = 30
    $script:refreshBtn.Add_Click({
        $script:infoTextBox.Text = (& $script:GetSysInfoData)
    })
    $script:row1.Controls.Add($script:refreshBtn)

    $script:copyBtn = New-Object System.Windows.Forms.Button
    $script:copyBtn.Text = "Copy to Clipboard"
    $script:copyBtn.AutoSize = $true
    $script:copyBtn.Height = 30
    $script:copyBtn.Add_Click({
        if ($script:infoTextBox.Text) {
            [System.Windows.Forms.Clipboard]::SetText($script:infoTextBox.Text)
            [System.Windows.Forms.MessageBox]::Show("Copied to clipboard!", "Info", [System.Windows.Forms.MessageBoxButtons]::OK)
        }
    })
    $script:row1.Controls.Add($script:copyBtn)

    & $addAutoRow $script:row1

    # --- Categorized launcher groups ---
    # Each item: Label, Exe, Args (string, "" if none)
    $categories = @(
        @{ Title = "Security & Policy"; Items = @(
            @{ Label = "Local Security Policy"; Exe = "mmc.exe"; Args = "secpol.msc" }
            @{ Label = "Group Policy Editor";   Exe = "mmc.exe"; Args = "gpedit.msc" }
            @{ Label = "Local Users & Groups";  Exe = "mmc.exe"; Args = "lusrmgr.msc" }
        )}
        @{ Title = "System Management"; Items = @(
            @{ Label = "Computer Mgmt";     Exe = "mmc.exe";     Args = "compmgmt.msc" }
            @{ Label = "Services";          Exe = "mmc.exe";     Args = "services.msc" }
            @{ Label = "Task Scheduler";    Exe = "mmc.exe";     Args = "taskschd.msc" }
            @{ Label = "Event Viewer";      Exe = "mmc.exe";     Args = "eventvwr.msc" }
            @{ Label = "Task Manager";      Exe = "taskmgr.exe"; Args = "" }
            @{ Label = "System Properties"; Exe = "control.exe"; Args = "sysdm.cpl" }
        )}
        @{ Title = "Hardware & Storage"; Items = @(
            @{ Label = "Device Manager";   Exe = "mmc.exe"; Args = "devmgmt.msc" }
            @{ Label = "Disk Management";  Exe = "mmc.exe"; Args = "diskmgmt.msc" }
            @{ Label = "Print Management"; Exe = "mmc.exe"; Args = "printmanagement.msc" }
        )}
        @{ Title = "Advanced"; Items = @(
            @{ Label = "Registry Editor";     Exe = "regedit.exe";    Args = "" }
            @{ Label = "Elevated PowerShell"; Exe = "powershell.exe"; Args = "" }
            @{ Label = "Elevated CMD";        Exe = "cmd.exe";        Args = "" }
        )}
    )

    foreach ($cat in $categories) {
        $group = New-Object System.Windows.Forms.GroupBox
        $group.Text = $cat.Title
        $group.AutoSize = $true
        $group.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $group.Dock = [System.Windows.Forms.DockStyle]::Top
        $group.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 5)
        $group.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

        $flow = New-Object System.Windows.Forms.FlowLayoutPanel
        $flow.AutoSize = $true
        $flow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $flow.Dock = [System.Windows.Forms.DockStyle]::Fill
        $flow.WrapContents = $true
        $flow.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)

        foreach ($item in $cat.Items) {
            $btn = New-Object System.Windows.Forms.Button
            $btn.Text = $item.Label
            $btn.AutoSize = $true
            $btn.Height = 30
            $btn.Margin = New-Object System.Windows.Forms.Padding(3)
            $itemExe  = $item.Exe
            $itemArgs = $item.Args
            $itemName = $item.Label
            $btn.Add_Click({
                if ($itemArgs) {
                    Start-ElevatedProcess -FilePath $itemExe -ArgumentList $itemArgs -OperationName "launch $itemName"
                } else {
                    Start-ElevatedProcess -FilePath $itemExe -OperationName "launch $itemName"
                }
            }.GetNewClosure())
            $flow.Controls.Add($btn)
        }

        # Special-case extras for specific groups
        if ($cat.Title -eq "System Management") {
            # MSInfo32 runs unelevated (no admin needed)
            $msInfoBtn = New-Object System.Windows.Forms.Button
            $msInfoBtn.Text = "MSInfo32"
            $msInfoBtn.AutoSize = $true
            $msInfoBtn.Height = 30
            $msInfoBtn.Margin = New-Object System.Windows.Forms.Padding(3)
            $msInfoBtn.Add_Click({ Start-Process "msinfo32.exe" })
            $flow.Controls.Add($msInfoBtn)
        }
        elseif ($cat.Title -eq "Hardware & Storage") {
            # Memory Test requires confirmation dialog
            $memDiagBtn = New-Object System.Windows.Forms.Button
            $memDiagBtn.Text = "Memory Test"
            $memDiagBtn.AutoSize = $true
            $memDiagBtn.Height = 30
            $memDiagBtn.Margin = New-Object System.Windows.Forms.Padding(3)
            $memDiagBtn.Add_Click({
                $msg = "Windows Memory Diagnostic will check your RAM for errors.`n`nThe computer must restart to run the test.`n`nSchedule memory test?"
                $confirm = [System.Windows.Forms.MessageBox]::Show($msg, "Memory Diagnostic", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
                if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Write-SessionLog -Message "Memory Diagnostic scheduled via mdsched.exe" -Category "Workstation"
                    Start-ElevatedProcess -FilePath "mdsched.exe" -OperationName "schedule Memory Diagnostic"
                }
            })
            $flow.Controls.Add($memDiagBtn)

            # Printers folder must open through explorer as the CURRENT user
            # (shell: URIs don't work through elevation/alternate credentials)
            $printersBtn = New-Object System.Windows.Forms.Button
            $printersBtn.Text = "Printers Folder"
            $printersBtn.AutoSize = $true
            $printersBtn.Height = 30
            $printersBtn.Margin = New-Object System.Windows.Forms.Padding(3)
            $printersBtn.Add_Click({
                Start-Process "explorer.exe" -ArgumentList "shell:PrintersFolder"
                Write-SessionLog -Message "Opened Printers folder" -Category "Workstation"
            })
            $flow.Controls.Add($printersBtn)
        }

        if ($cat.Title -eq "Advanced") {
            # Terminal with ENT's FULL admin token (two-hop: PowerShell as ENT,
            # then -Verb RunAs inside that session). Plain Start-ElevatedProcess
            # gives the ENT user a UAC-filtered token, which many tools reject.
            $entTermBtn = New-Object System.Windows.Forms.Button
            $entTermBtn.Text = "Terminal (ENT Admin)"
            $entTermBtn.AutoSize = $true
            $entTermBtn.Height = 30
            $entTermBtn.Margin = New-Object System.Windows.Forms.Padding(3)
            $entTermBtn.Add_Click({
                # Windows Terminal is a per-user Store app - it usually doesn't
                # exist for the ENT profile, so fall back to PowerShell
                $termExe = "powershell.exe"
                $wt = Get-Command "wt.exe" -ErrorAction SilentlyContinue
                if ($wt) { $termExe = $wt.Source }

                $launch = Start-AsENTElevated -FilePath $termExe -OperationName "open an elevated ENT terminal"
                if (-not $launch.Success -and $launch.Error -and $launch.Error -notlike "*cancelled*") {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Could not open ENT terminal:`n$($launch.Error)",
                        "Terminal (ENT Admin)",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                }
            })
            $flow.Controls.Add($entTermBtn)

            # Registry Editor with the full ENT admin token
            $entRegBtn = New-Object System.Windows.Forms.Button
            $entRegBtn.Text = "Regedit (ENT Admin)"
            $entRegBtn.AutoSize = $true
            $entRegBtn.Height = 30
            $entRegBtn.Margin = New-Object System.Windows.Forms.Padding(3)
            $entRegBtn.Add_Click({
                Start-AsENTElevated -FilePath "regedit.exe" -OperationName "open Registry Editor as ENT" | Out-Null
            })
            $flow.Controls.Add($entRegBtn)
        }

        $group.Controls.Add($flow)
        & $addAutoRow $group
    }

    # --- Power group: Reboot / Shutdown ---
    $powerGroup = New-Object System.Windows.Forms.GroupBox
    $powerGroup.Text = "Power"
    $powerGroup.AutoSize = $true
    $powerGroup.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $powerGroup.Dock = [System.Windows.Forms.DockStyle]::Top
    $powerGroup.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 5)
    $powerGroup.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

    $powerFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $powerFlow.AutoSize = $true
    $powerFlow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $powerFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $powerFlow.WrapContents = $true
    $powerFlow.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)

    $script:rebootBtn = New-Object System.Windows.Forms.Button
    $script:rebootBtn.Text = "Reboot"
    $script:rebootBtn.AutoSize = $true
    $script:rebootBtn.Height = 30
    $script:rebootBtn.Margin = New-Object System.Windows.Forms.Padding(3)
    $script:rebootBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 220, 220)
    $script:rebootBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show("Reboot this computer?", "Confirm", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-SessionLog -Message "REBOOT initiated (30 second delay)" -Category "Workstation"
            shutdown /r /t 30 /c "Reboot initiated by Rush Resolve"
        }
    })
    $powerFlow.Controls.Add($script:rebootBtn)

    $script:shutdownBtn = New-Object System.Windows.Forms.Button
    $script:shutdownBtn.Text = "Shutdown"
    $script:shutdownBtn.AutoSize = $true
    $script:shutdownBtn.Height = 30
    $script:shutdownBtn.Margin = New-Object System.Windows.Forms.Padding(3)
    $script:shutdownBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 220, 220)
    $script:shutdownBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show("Shut down this computer?", "Confirm", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-SessionLog -Message "SHUTDOWN initiated (30 second delay)" -Category "Workstation"
            shutdown /s /t 30 /c "Shutdown initiated by Rush Resolve"
        }
    })
    $powerFlow.Controls.Add($script:shutdownBtn)

    $powerGroup.Controls.Add($powerFlow)
    & $addAutoRow $powerGroup

    $mainPanel.Controls.Add($topPanel, 0, 0)
    $mainPanel.Controls.Add($script:bottomPanel, 0, 1)

    $tab.Controls.Add($mainPanel)
}
