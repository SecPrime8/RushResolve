<#
.SYNOPSIS
    AppLocker Troubleshooting Module for Rush Resolve
.DESCRIPTION
    Diagnoses AppLocker blocks and regenerates rules for packaged apps
    and executables. Primary use case: apps blocked after Win10->Win11
    in-place upgrades where AppLocker rules go stale.

.NOTES
    Requires elevation for all operations:
    - Reading AppLocker event logs
    - Getting current AppLocker policy
    - Regenerating and applying rules
#>

$script:ModuleName = "AppLocker"
$script:ModuleDescription = "Diagnose AppLocker blocks and regenerate rules"

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    #region Activity Log Helper
    $script:AppLockerLog = {
        param([string]$Message)
        if ($script:appLockerLogBox) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:appLockerLogBox.AppendText("[$timestamp] $Message`r`n")
            $script:appLockerLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    #endregion

    #region Main Layout
    $script:mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $script:mainLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:mainLayout.RowCount = 3
    $script:mainLayout.ColumnCount = 1
    $script:mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 80))) | Out-Null   # Action buttons
    $script:mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null    # Recent blocks
    $script:mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null    # Activity log
    #endregion

    #region Action Buttons Panel
    $script:actionGroup = New-Object System.Windows.Forms.GroupBox
    $script:actionGroup.Text = "Actions"
    $script:actionGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:actionPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $script:actionPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:actionPanel.Padding = New-Object System.Windows.Forms.Padding(5, 5, 5, 5)
    $script:actionPanel.WrapContents = $true

    # View Recent Blocks button
    $script:viewBlocksBtn = New-Object System.Windows.Forms.Button
    $script:viewBlocksBtn.Text = "View Recent Blocks"
    $script:viewBlocksBtn.AutoSize = $true
    $script:viewBlocksBtn.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowOnly
    $script:viewBlocksBtn.Height = 30
    $script:viewBlocksBtn.Add_Click({
        & $script:AppLockerLog "Scanning AppLocker event logs for recent blocks..."
        $script:blocksListView.Items.Clear()
        [System.Windows.Forms.Application]::DoEvents()

        $result = Invoke-Elevated -ScriptBlock {
            $events = @()
            $logNames = @(
                "Microsoft-Windows-AppLocker/EXE and DLL",
                "Microsoft-Windows-AppLocker/Packaged app-Deployment",
                "Microsoft-Windows-AppLocker/Packaged app-Execution",
                "Microsoft-Windows-AppLocker/MSI and Script"
            )
            foreach ($logName in $logNames) {
                try {
                    # Event IDs: 8004 (EXE blocked), 8007 (MSI/Script blocked),
                    # 8023 (Packaged deploy blocked), 8025 (Packaged exec blocked)
                    $blocked = Get-WinEvent -LogName $logName -MaxEvents 50 -ErrorAction SilentlyContinue |
                        Where-Object { $_.Id -in @(8004, 8007, 8023, 8025) }
                    if ($blocked) {
                        foreach ($evt in $blocked) {
                            $events += [PSCustomObject]@{
                                Time     = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                                Log      = ($logName -replace "Microsoft-Windows-AppLocker/", "")
                                EventId  = $evt.Id
                                Message  = $evt.Message.Substring(0, [Math]::Min(200, $evt.Message.Length))
                            }
                        }
                    }
                } catch {
                    # Log may not exist or be empty
                }
            }
            return $events | Sort-Object Time -Descending | Select-Object -First 100
        } -OperationName "read AppLocker event logs"

        if ($result.Success) {
            $events = $result.Output
            if ($events -and $events.Count -gt 0) {
                foreach ($evt in $events) {
                    $item = New-Object System.Windows.Forms.ListViewItem($evt.Time)
                    $item.SubItems.Add($evt.Log) | Out-Null
                    $item.SubItems.Add($evt.EventId.ToString()) | Out-Null
                    $item.SubItems.Add($evt.Message) | Out-Null
                    $script:blocksListView.Items.Add($item) | Out-Null
                }
                & $script:AppLockerLog "Found $($events.Count) blocked event(s)"
            } else {
                & $script:AppLockerLog "No recent AppLocker blocks found"
            }
        } else {
            & $script:AppLockerLog "ERROR: $($result.Error)"
        }
    })
    $script:actionPanel.Controls.Add($script:viewBlocksBtn)

    # Separator
    $script:sep1 = New-Object System.Windows.Forms.Label
    $script:sep1.Text = "|"
    $script:sep1.AutoSize = $true
    $script:sep1.Padding = New-Object System.Windows.Forms.Padding(3, 6, 3, 0)
    $script:actionPanel.Controls.Add($script:sep1)

    # Regenerate Packaged App Rules button (primary action)
    $script:regenPackagedBtn = New-Object System.Windows.Forms.Button
    $script:regenPackagedBtn.Text = "Regenerate Packaged App Rules"
    $script:regenPackagedBtn.AutoSize = $true
    $script:regenPackagedBtn.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowOnly
    $script:regenPackagedBtn.Height = 30
    $script:regenPackagedBtn.BackColor = [System.Drawing.Color]::FromArgb(220, 240, 255)
    $script:regenPackagedBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This will scan all installed packaged apps and regenerate AppLocker rules for Everyone.`n`nExisting packaged app rules will be merged with the new rules.`n`nContinue?",
            "Regenerate Packaged App Rules",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        & $script:AppLockerLog "=== Regenerating Packaged App Rules ==="
        & $script:AppLockerLog "Scanning installed packaged apps..."
        [System.Windows.Forms.Application]::DoEvents()

        $result = Invoke-Elevated -ScriptBlock {
            $output = [System.Text.StringBuilder]::new()

            # Get all packaged apps
            $packages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            [void]$output.AppendLine("Found $($packages.Count) packaged apps")

            if ($packages.Count -eq 0) {
                [void]$output.AppendLine("ERROR: No packaged apps found")
                return @{ Success = $false; Log = $output.ToString(); RuleCount = 0 }
            }

            # Get file information for AppLocker rule generation
            [void]$output.AppendLine("Generating AppLocker file information...")
            $fileInfo = $packages | Get-AppLockerFileInformation -ErrorAction SilentlyContinue

            if (-not $fileInfo -or $fileInfo.Count -eq 0) {
                [void]$output.AppendLine("ERROR: Could not generate file information from packages")
                return @{ Success = $false; Log = $output.ToString(); RuleCount = 0 }
            }

            [void]$output.AppendLine("Generated info for $($fileInfo.Count) items")

            # Create new policy with publisher rules for Everyone, optimized (grouped)
            [void]$output.AppendLine("Creating optimized AppLocker policy...")
            $policy = $fileInfo | New-AppLockerPolicy -RuleType Publisher -User Everyone -Optimize -ErrorAction Stop

            # Count rules in new policy
            $ruleCount = 0
            $xml = [xml]$policy.ToXml()
            $ruleCollections = $xml.AppLockerPolicy.RuleCollection
            foreach ($rc in $ruleCollections) {
                if ($rc.Rule) {
                    $ruleCount += $rc.Rule.Count
                }
            }
            [void]$output.AppendLine("New policy contains $ruleCount rule(s)")

            # Merge into existing local policy
            [void]$output.AppendLine("Merging into local AppLocker policy...")
            Set-AppLockerPolicy -PolicyObject $policy -Merge -ErrorAction Stop
            [void]$output.AppendLine("Policy applied successfully")

            return @{ Success = $true; Log = $output.ToString(); RuleCount = $ruleCount }
        } -OperationName "regenerate packaged app rules"

        if ($result.Success -and $result.Output) {
            $data = $result.Output
            $logLines = $data.Log -split "`n"
            foreach ($line in $logLines) {
                $trimmed = $line.Trim()
                if ($trimmed) {
                    & $script:AppLockerLog "  $trimmed"
                }
            }
            if ($data.Success) {
                & $script:AppLockerLog "[OK] Packaged app rules regenerated ($($data.RuleCount) rules)"
                Write-SessionLog -Message "Regenerated AppLocker packaged app rules ($($data.RuleCount) rules)" -Category "AppLocker"
                [System.Windows.Forms.MessageBox]::Show(
                    "Packaged app rules regenerated successfully.`n`n$($data.RuleCount) rules applied.",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            } else {
                & $script:AppLockerLog "[FAIL] $($data.Log)"
            }
        } else {
            & $script:AppLockerLog "ERROR: $($result.Error)"
        }
        & $script:AppLockerLog "=== Done ==="
    })
    $script:actionPanel.Controls.Add($script:regenPackagedBtn)

    # Regenerate EXE Rules button (secondary action)
    $script:regenExeBtn = New-Object System.Windows.Forms.Button
    $script:regenExeBtn.Text = "Regenerate EXE Rules"
    $script:regenExeBtn.AutoSize = $true
    $script:regenExeBtn.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowOnly
    $script:regenExeBtn.Height = 30
    $script:regenExeBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This will scan Program Files and Windows directories to regenerate EXE AppLocker rules for Everyone.`n`nExisting EXE rules will be merged with the new rules.`n`nThis may take a few minutes. Continue?",
            "Regenerate EXE Rules",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        & $script:AppLockerLog "=== Regenerating EXE Rules ==="
        & $script:AppLockerLog "Scanning Program Files and Windows directories..."
        & $script:AppLockerLog "This may take a few minutes..."
        [System.Windows.Forms.Application]::DoEvents()

        $result = Invoke-Elevated -ScriptBlock {
            $output = [System.Text.StringBuilder]::new()

            $scanPaths = @(
                "$env:ProgramFiles",
                "${env:ProgramFiles(x86)}",
                "$env:SystemRoot"
            )

            $allFileInfo = @()
            foreach ($scanPath in $scanPaths) {
                if (Test-Path $scanPath) {
                    [void]$output.AppendLine("Scanning: $scanPath")
                    $fi = Get-AppLockerFileInformation -Directory $scanPath -Recurse -FileType Exe -ErrorAction SilentlyContinue
                    if ($fi) {
                        $allFileInfo += $fi
                        [void]$output.AppendLine("  Found $($fi.Count) executables")
                    }
                }
            }

            if ($allFileInfo.Count -eq 0) {
                [void]$output.AppendLine("ERROR: No executables found to generate rules for")
                return @{ Success = $false; Log = $output.ToString(); RuleCount = 0 }
            }

            [void]$output.AppendLine("Total: $($allFileInfo.Count) executables")
            [void]$output.AppendLine("Creating optimized AppLocker policy...")

            $policy = $allFileInfo | New-AppLockerPolicy -RuleType Publisher,Path -User Everyone -Optimize -ErrorAction Stop

            $ruleCount = 0
            $xml = [xml]$policy.ToXml()
            $ruleCollections = $xml.AppLockerPolicy.RuleCollection
            foreach ($rc in $ruleCollections) {
                if ($rc.Rule) {
                    $ruleCount += $rc.Rule.Count
                }
            }
            [void]$output.AppendLine("New policy contains $ruleCount rule(s)")

            [void]$output.AppendLine("Merging into local AppLocker policy...")
            Set-AppLockerPolicy -PolicyObject $policy -Merge -ErrorAction Stop
            [void]$output.AppendLine("Policy applied successfully")

            return @{ Success = $true; Log = $output.ToString(); RuleCount = $ruleCount }
        } -OperationName "regenerate EXE rules"

        if ($result.Success -and $result.Output) {
            $data = $result.Output
            $logLines = $data.Log -split "`n"
            foreach ($line in $logLines) {
                $trimmed = $line.Trim()
                if ($trimmed) {
                    & $script:AppLockerLog "  $trimmed"
                }
            }
            if ($data.Success) {
                & $script:AppLockerLog "[OK] EXE rules regenerated ($($data.RuleCount) rules)"
                Write-SessionLog -Message "Regenerated AppLocker EXE rules ($($data.RuleCount) rules)" -Category "AppLocker"
                [System.Windows.Forms.MessageBox]::Show(
                    "EXE rules regenerated successfully.`n`n$($data.RuleCount) rules applied.",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            } else {
                & $script:AppLockerLog "[FAIL] $($data.Log)"
            }
        } else {
            & $script:AppLockerLog "ERROR: $($result.Error)"
        }
        & $script:AppLockerLog "=== Done ==="
    })
    $script:actionPanel.Controls.Add($script:regenExeBtn)

    # Separator
    $script:sep2 = New-Object System.Windows.Forms.Label
    $script:sep2.Text = "|"
    $script:sep2.AutoSize = $true
    $script:sep2.Padding = New-Object System.Windows.Forms.Padding(3, 6, 3, 0)
    $script:actionPanel.Controls.Add($script:sep2)

    # Open Local Security Policy button
    $script:openSecPolBtn = New-Object System.Windows.Forms.Button
    $script:openSecPolBtn.Text = "Open Security Policy"
    $script:openSecPolBtn.AutoSize = $true
    $script:openSecPolBtn.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowOnly
    $script:openSecPolBtn.Height = 30
    $script:openSecPolBtn.Add_Click({
        & $script:AppLockerLog "Opening Local Security Policy (secpol.msc)..."
        Write-SessionLog -Message "Opened secpol.msc via AppLocker module" -Category "AppLocker"
        Start-ElevatedProcess -FilePath "mmc.exe" -ArgumentList "secpol.msc" -OperationName "open Local Security Policy"
    })
    $script:actionPanel.Controls.Add($script:openSecPolBtn)

    # View Current Policy button
    $script:viewPolicyBtn = New-Object System.Windows.Forms.Button
    $script:viewPolicyBtn.Text = "View Current Policy"
    $script:viewPolicyBtn.AutoSize = $true
    $script:viewPolicyBtn.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowOnly
    $script:viewPolicyBtn.Height = 30
    $script:viewPolicyBtn.Add_Click({
        & $script:AppLockerLog "Retrieving current AppLocker policy..."
        [System.Windows.Forms.Application]::DoEvents()

        $result = Invoke-Elevated -ScriptBlock {
            $policy = Get-AppLockerPolicy -Local -ErrorAction Stop
            $xml = [xml]$policy.ToXml()
            $summary = @()
            foreach ($rc in $xml.AppLockerPolicy.RuleCollection) {
                $enforcement = $rc.EnforcementMode
                $ruleCount = 0
                if ($rc.FilePublisherRule) { $ruleCount += $rc.FilePublisherRule.Count }
                if ($rc.FilePathRule) { $ruleCount += $rc.FilePathRule.Count }
                if ($rc.FileHashRule) { $ruleCount += $rc.FileHashRule.Count }
                $summary += [PSCustomObject]@{
                    Collection  = $rc.Type
                    Enforcement = $enforcement
                    Rules       = $ruleCount
                }
            }
            return $summary
        } -OperationName "read AppLocker policy"

        if ($result.Success -and $result.Output) {
            & $script:AppLockerLog "--- Current AppLocker Policy ---"
            foreach ($item in $result.Output) {
                & $script:AppLockerLog "  $($item.Collection): $($item.Rules) rules (Mode: $($item.Enforcement))"
            }
            & $script:AppLockerLog "--------------------------------"
        } else {
            & $script:AppLockerLog "ERROR: $($result.Error)"
        }
    })
    $script:actionPanel.Controls.Add($script:viewPolicyBtn)

    $script:actionGroup.Controls.Add($script:actionPanel)
    $script:mainLayout.Controls.Add($script:actionGroup, 0, 0)
    #endregion

    #region Recent Blocks ListView
    $script:blocksGroup = New-Object System.Windows.Forms.GroupBox
    $script:blocksGroup.Text = "Recent AppLocker Blocks"
    $script:blocksGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:blocksListView = New-Object System.Windows.Forms.ListView
    $script:blocksListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:blocksListView.View = [System.Windows.Forms.View]::Details
    $script:blocksListView.FullRowSelect = $true
    $script:blocksListView.GridLines = $true
    $script:blocksListView.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:blocksListView.Columns.Add("Time", 140) | Out-Null
    $script:blocksListView.Columns.Add("Type", 120) | Out-Null
    $script:blocksListView.Columns.Add("Event ID", 70) | Out-Null
    $script:blocksListView.Columns.Add("Details", 600) | Out-Null

    $script:blocksGroup.Controls.Add($script:blocksListView)
    $script:mainLayout.Controls.Add($script:blocksGroup, 0, 1)
    #endregion

    #region Activity Log
    $script:logGroup = New-Object System.Windows.Forms.GroupBox
    $script:logGroup.Text = "Activity Log"
    $script:logGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:appLockerLogBox = New-Object System.Windows.Forms.RichTextBox
    $script:appLockerLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:appLockerLogBox.ReadOnly = $true
    $script:appLockerLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:appLockerLogBox.WordWrap = $false
    $script:appLockerLogBox.BackColor = [System.Drawing.Color]::White

    $script:logGroup.Controls.Add($script:appLockerLogBox)
    $script:mainLayout.Controls.Add($script:logGroup, 0, 2)
    #endregion

    $tab.Controls.Add($script:mainLayout)

    # Initial log message
    & $script:AppLockerLog "AppLocker Troubleshooting module loaded"
    & $script:AppLockerLog "Click 'View Recent Blocks' to scan for blocked apps"
    & $script:AppLockerLog "Click 'Regenerate Packaged App Rules' to fix apps blocked after Win10->11 upgrade"
}
