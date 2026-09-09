<#
.SYNOPSIS
    Welcome Module for Rush Resolve
.DESCRIPTION
    First tab a tech sees on launch. Puts every credential action (set, copy,
    QR code, lock, clear) one click away and shows a quick summary of the
    computer. Loads instantly - all other modules load in the background.
#>

$script:ModuleName = "Welcome"
$script:ModuleDescription = "Credentials and computer overview - your starting point"

# Use script blocks instead of functions to avoid scope issues
# (functions defined here don't survive the module loader's scope)

# Builds the computer summary text from the shell's cached session info
$script:GetWelcomeSummary = {
    $lines = [System.Text.StringBuilder]::new()

    [void]$lines.AppendLine("  Computer:   $env:COMPUTERNAME")
    [void]$lines.AppendLine("  User:       $env:USERDOMAIN\$env:USERNAME")

    $info = $script:SessionStartInfo
    if ($info) {
        if ($info.IPv4)   { [void]$lines.AppendLine("  IPv4:       $($info.IPv4)") }
        if ($info.OS)     { [void]$lines.AppendLine("  OS:         $($info.OS) (build $($info.Build))") }
        if ($info.Model)  { [void]$lines.AppendLine("  Model:      $($info.Manufacturer) $($info.Model)") }
        if ($info.Serial) { [void]$lines.AppendLine("  Serial:     $($info.Serial)") }
        if ($info.RAM)    { [void]$lines.AppendLine("  RAM:        $($info.RAM)") }
        if ($info.DomainJoined) {
            [void]$lines.AppendLine("  Domain:     $($info.Domain)")
        } elseif ($info.Workgroup) {
            [void]$lines.AppendLine("  Workgroup:  $($info.Workgroup)")
        }
    }
    else {
        [void]$lines.AppendLine("")
        [void]$lines.AppendLine("  Gathering system details...")
    }

    return $lines.ToString()
}

# Called by the shell once Complete-SessionLogSystemInfo finishes (and by Refresh)
$script:UpdateWelcomeSystemInfo = {
    if ($script:welcomeInfoBox -and -not $script:welcomeInfoBox.IsDisposed) {
        $script:welcomeInfoBox.Text = (& $script:GetWelcomeSummary)
    }
}

# Mirrors the shell's status-bar credential indicator onto the Welcome tab
$script:UpdateWelcomeCredStatus = {
    if (-not $script:welcomeCredStatus -or $script:welcomeCredStatus.IsDisposed) { return }

    if ($script:credStatusLabel) {
        $script:welcomeCredStatus.Text = "Status: $($script:credStatusLabel.Text)"
        $script:welcomeCredStatus.ForeColor = $script:credStatusLabel.ForeColor
    }
    elseif ($script:CachedCredential) {
        $script:welcomeCredStatus.Text = "Status: Credentials cached"
        $script:welcomeCredStatus.ForeColor = [System.Drawing.Color]::ForestGreen
    }
    else {
        $script:welcomeCredStatus.Text = "Status: No credentials cached"
        $script:welcomeCredStatus.ForeColor = [System.Drawing.Color]::Gray
    }
}

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Two columns: credentials (left) | computer summary (right)
    $mainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.ColumnCount = 2
    $mainPanel.RowCount = 1
    $mainPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 45))) | Out-Null
    $mainPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 55))) | Out-Null
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $mainPanel.Padding = New-Object System.Windows.Forms.Padding(10)

    # --- Left: Credentials ---
    $credGroup = New-Object System.Windows.Forms.GroupBox
    $credGroup.Text = "Credentials (ENT)"
    $credGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $credGroup.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $credGroup.Padding = New-Object System.Windows.Forms.Padding(12)

    $credFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $credFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $credFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $credFlow.WrapContents = $false
    $credFlow.AutoScroll = $true
    $credFlow.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)

    # Credential status (mirrors the status-bar indicator)
    $script:welcomeCredStatus = New-Object System.Windows.Forms.Label
    $script:welcomeCredStatus.Text = "Checking credential status..."
    $script:welcomeCredStatus.AutoSize = $true
    $script:welcomeCredStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:welcomeCredStatus.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 12)
    $credFlow.Controls.Add($script:welcomeCredStatus)

    # Big credential action buttons - wired straight to the shell's existing functions
    $credActions = @(
        @{ Label = "Set / Update Credentials...";  Action = { Set-ManualCredentials } }
        @{ Label = "Copy Password to Clipboard";   Action = { Copy-PasswordToClipboard } }
        @{ Label = "QR Code Authenticator";        Action = { Show-QRCodeAuthenticator } }
        @{ Label = "Lock Now (Require PIN)";       Action = { Lock-CachedCredentials } }
        @{ Label = "Clear Cached Credentials";     Action = { Clear-CachedCredentials } }
    )

    foreach ($item in $credActions) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $item.Label
        $btn.Width = 260
        $btn.Height = 38
        $btn.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 6)
        $btn.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $btn.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
        # GetNewClosure captures LOCALS only - $script: vars resolve to $null
        # inside the closure's module scope, so copy the callback to a local first
        $itemAction = $item.Action
        $updateStatus = $script:UpdateWelcomeCredStatus
        $btn.Add_Click({
            try {
                & $itemAction
                if ($updateStatus) { & $updateStatus }
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Credential action failed:`n$($_.Exception.Message)",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
        }.GetNewClosure())
        $credFlow.Controls.Add($btn)
    }

    $credGroup.Controls.Add($credFlow)

    $leftPanel = New-Object System.Windows.Forms.Panel
    $leftPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $leftPanel.Padding = New-Object System.Windows.Forms.Padding(0, 0, 5, 0)
    $leftPanel.Controls.Add($credGroup)

    # --- Right: This Computer ---
    $infoGroup = New-Object System.Windows.Forms.GroupBox
    $infoGroup.Text = "This Computer"
    $infoGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $infoGroup.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $infoGroup.Padding = New-Object System.Windows.Forms.Padding(12)

    $infoLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $infoLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $infoLayout.ColumnCount = 1
    $infoLayout.RowCount = 2
    $infoLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $infoLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null

    $script:welcomeInfoBox = New-Object System.Windows.Forms.TextBox
    $script:welcomeInfoBox.Multiline = $true
    $script:welcomeInfoBox.ReadOnly = $true
    $script:welcomeInfoBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:welcomeInfoBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:welcomeInfoBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:welcomeInfoBox.BackColor = [System.Drawing.Color]::White
    $script:welcomeInfoBox.Text = (& $script:GetWelcomeSummary)
    $infoLayout.Controls.Add($script:welcomeInfoBox, 0, 0)

    $infoButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $infoButtons.AutoSize = $true
    $infoButtons.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $infoButtons.Dock = [System.Windows.Forms.DockStyle]::Top
    $infoButtons.WrapContents = $false
    $infoButtons.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)

    $refreshInfoBtn = New-Object System.Windows.Forms.Button
    $refreshInfoBtn.Text = "Refresh"
    $refreshInfoBtn.AutoSize = $true
    $refreshInfoBtn.Height = 30
    $refreshInfoBtn.Add_Click({
        # Force a fresh gather (hardware/IP may have changed mid-session)
        $script:SessionStartInfo = $null
        Complete-SessionLogSystemInfo
        & $script:UpdateWelcomeSystemInfo
    })
    $infoButtons.Controls.Add($refreshInfoBtn)

    $copyInfoBtn = New-Object System.Windows.Forms.Button
    $copyInfoBtn.Text = "Copy to Clipboard"
    $copyInfoBtn.AutoSize = $true
    $copyInfoBtn.Height = 30
    $copyInfoBtn.Add_Click({
        if ($script:welcomeInfoBox.Text) {
            [System.Windows.Forms.Clipboard]::SetText($script:welcomeInfoBox.Text)
        }
    })
    $infoButtons.Controls.Add($copyInfoBtn)

    $viewLogBtn = New-Object System.Windows.Forms.Button
    $viewLogBtn.Text = "View Session Log"
    $viewLogBtn.AutoSize = $true
    $viewLogBtn.Height = 30
    $viewLogBtn.Add_Click({
        if ($script:SessionLogFile -and (Test-Path $script:SessionLogFile)) {
            Start-Process notepad.exe -ArgumentList "`"$script:SessionLogFile`""
        }
        else {
            Open-SessionLogsFolder
        }
    })
    $infoButtons.Controls.Add($viewLogBtn)

    $infoLayout.Controls.Add($infoButtons, 0, 1)
    $infoGroup.Controls.Add($infoLayout)

    $rightPanel = New-Object System.Windows.Forms.Panel
    $rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rightPanel.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
    $rightPanel.Controls.Add($infoGroup)

    $mainPanel.Controls.Add($leftPanel, 0, 0)
    $mainPanel.Controls.Add($rightPanel, 1, 0)
    $tab.Controls.Add($mainPanel)

    # Keep the credential status label current (cheap - reads cached state only)
    & $script:UpdateWelcomeCredStatus
    $script:welcomeCredTimer = New-Object System.Windows.Forms.Timer
    $script:welcomeCredTimer.Interval = 2000
    # Ticks fire during modal dialogs too - never let an exception escape
    $script:welcomeCredTimer.Add_Tick({ try { & $script:UpdateWelcomeCredStatus } catch { } })
    $script:welcomeCredTimer.Start()
}
