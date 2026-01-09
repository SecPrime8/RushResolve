<#
.SYNOPSIS
    Network Tools Module for Rush Resolve
.DESCRIPTION
    Network diagnostics, wireless tools, and LLDP switch discovery.
#>

$script:ModuleName = "Network Tools"
$script:ModuleDescription = "Network diagnostics, wireless tools, and switch discovery"

#region Script Blocks

# Get network adapters with details
$script:GetAdapters = {
    $adapters = @()
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Disconnected' } | ForEach-Object {
        $ip = (Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress | Select-Object -First 1
        $gateway = (Get-NetRoute -InterfaceIndex $_.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).NextHop | Select-Object -First 1
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ', '

        $adapters += [PSCustomObject]@{
            Name = $_.Name
            Status = $_.Status
            MAC = $_.MacAddress
            IP = if ($ip) { $ip } else { "N/A" }
            Gateway = if ($gateway) { $gateway } else { "N/A" }
            DNS = if ($dns) { $dns } else { "N/A" }
            Speed = $_.LinkSpeed
            InterfaceIndex = $_.InterfaceIndex
        }
    }
    return $adapters
}

# Run ping test
$script:RunPing = {
    param([string]$Target, [int]$Count = 4, [System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Pinging $Target...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $results = Test-Connection -ComputerName $Target -Count $Count -ErrorAction Stop
        foreach ($result in $results) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $LogBox.AppendText("[$timestamp] Reply from $($result.Address): time=$($result.ResponseTime)ms TTL=$($result.TimeToLive)`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $avg = ($results | Measure-Object -Property ResponseTime -Average).Average
        $LogBox.AppendText("`r`n[$timestamp] Average: $([math]::Round($avg, 1))ms`r`n")
    }
    catch {
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
    }
    $LogBox.ScrollToCaret()
}

# Run traceroute
$script:RunTraceroute = {
    param([string]$Target, [System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Tracing route to $Target...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $result = Test-NetConnection -ComputerName $Target -TraceRoute -ErrorAction Stop
        $hop = 1
        foreach ($ip in $result.TraceRoute) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $LogBox.AppendText("[$timestamp]   $hop  $ip`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
            $hop++
        }
        $LogBox.AppendText("`r`n[$timestamp] Trace complete.`r`n")
    }
    catch {
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
    }
    $LogBox.ScrollToCaret()
}

# Flush DNS
$script:FlushDns = {
    param([System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Flushing DNS cache...`r`n")

    try {
        Clear-DnsClientCache
        $LogBox.AppendText("[$timestamp] DNS cache flushed successfully.`r`n")
    }
    catch {
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
    }
    $LogBox.ScrollToCaret()
}

# IP Release/Renew
$script:ReleaseRenewIP = {
    param([string]$AdapterName, [string]$Action, [System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] $Action IP for $AdapterName...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        if ($Action -eq 'Release') {
            $output = ipconfig /release "$AdapterName" 2>&1
        } else {
            $output = ipconfig /renew "$AdapterName" 2>&1
        }
        $LogBox.AppendText("[$timestamp] $Action complete.`r`n")
    }
    catch {
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
    }
    $LogBox.ScrollToCaret()
}

# Setup LLDP (one-time on tech laptop) - requires elevation
$script:SetupLldp = {
    param([System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Checking LLDP prerequisites...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    # Get credentials first
    $cred = Get-ElevatedCredential -Message "Enter admin credentials to configure LLDP"
    if (-not $cred) {
        $LogBox.AppendText("[$timestamp] Operation cancelled - credentials required.`r`n")
        $LogBox.ScrollToCaret()
        return
    }

    # Check if DCB is installed (this check can run without elevation)
    $LogBox.AppendText("[$timestamp] Checking Data Center Bridging feature...`r`n")
    [System.Windows.Forms.Application]::DoEvents()

    $checkResult = Invoke-Elevated -ScriptBlock {
        $dcb = Get-WindowsOptionalFeature -Online -FeatureName "DataCenterBridging" -ErrorAction SilentlyContinue
        @{
            Installed = ($dcb -and $dcb.State -eq "Enabled")
            State = if ($dcb) { $dcb.State } else { "NotFound" }
        }
    } -Credential $cred -OperationName "check DCB feature"

    if (-not $checkResult.Success) {
        $LogBox.AppendText("[$timestamp] ERROR: $($checkResult.Error)`r`n")
        $LogBox.ScrollToCaret()
        return
    }

    $dcbStatus = $checkResult.Output

    if (-not $dcbStatus.Installed) {
        $LogBox.AppendText("[$timestamp] Data Center Bridging not installed (State: $($dcbStatus.State)).`r`n")
        $result = [System.Windows.Forms.MessageBox]::Show(
            "LLDP requires the Data Center Bridging feature.`n`nInstall now? (Requires reboot after)`n`nNote: This only needs to be done once on your tech laptop.",
            "Install DCB Feature",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            $LogBox.AppendText("[$timestamp] Installing Data Center Bridging (this may take a minute)...`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()

            $installResult = Invoke-Elevated -ScriptBlock {
                Enable-WindowsOptionalFeature -Online -FeatureName "DataCenterBridging" -All -NoRestart -ErrorAction Stop
                "DCB_INSTALLED"
            } -Credential $cred -OperationName "install DCB feature"

            if ($installResult.Success) {
                $LogBox.AppendText("[$timestamp] DCB installed successfully.`r`n")
                $LogBox.AppendText("[$timestamp] REBOOT REQUIRED - After reboot, click 'Setup LLDP' again.`r`n")
                [System.Windows.Forms.MessageBox]::Show(
                    "Data Center Bridging installed.`n`nPlease REBOOT your computer, then click 'Setup LLDP' again to complete setup.",
                    "Reboot Required",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            } else {
                $LogBox.AppendText("[$timestamp] ERROR: Failed to install DCB - $($installResult.Error)`r`n")
            }
        }
        $LogBox.ScrollToCaret()
        return
    }

    # DCB is installed - enable LLDP on adapters
    $LogBox.AppendText("[$timestamp] DCB feature is installed. Enabling LLDP on adapters...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    $enableResult = Invoke-Elevated -ScriptBlock {
        $results = @()
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -ne 'Unspecified' }
        foreach ($adapter in $adapters) {
            try {
                Enable-NetLldpAgent -NetAdapterName $adapter.Name -ErrorAction Stop
                $results += @{ Name = $adapter.Name; Success = $true; Error = $null }
            }
            catch {
                $results += @{ Name = $adapter.Name; Success = $false; Error = $_.Exception.Message }
            }
        }
        $results
    } -Credential $cred -OperationName "enable LLDP agents"

    if ($enableResult.Success -and $enableResult.Output) {
        $enabledCount = 0
        foreach ($adapterResult in $enableResult.Output) {
            if ($adapterResult.Success) {
                $LogBox.AppendText("[$timestamp] LLDP enabled on: $($adapterResult.Name)`r`n")
                $enabledCount++
            } else {
                $LogBox.AppendText("[$timestamp] Skipped $($adapterResult.Name): $($adapterResult.Error)`r`n")
            }
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        if ($enabledCount -gt 0) {
            $LogBox.AppendText("`r`n[$timestamp] Setup complete! LLDP enabled on $enabledCount adapter(s).`r`n")
            $LogBox.AppendText("[$timestamp] Wait ~30 seconds for switch to send data, then click 'Get Switch Info'.`r`n")
        } else {
            $LogBox.AppendText("[$timestamp] No adapters could be configured for LLDP.`r`n")
        }
    } else {
        $LogBox.AppendText("[$timestamp] ERROR: $($enableResult.Error)`r`n")
    }
    $LogBox.ScrollToCaret()
}

# Get LLDP info using Get-NetLldpNeighborInformation - requires elevation
$script:GetLldpInfo = {
    param([string]$AdapterName, [PSCredential]$Credential)

    $info = @{
        Available = $false
        SwitchName = "N/A"
        SwitchIP = "N/A"
        Port = "N/A"
        PortDesc = "N/A"
        VLAN = "N/A"
        Error = $null
    }

    # If no credential provided, try to get one
    if (-not $Credential) {
        $Credential = Get-ElevatedCredential -Message "Enter admin credentials to query LLDP"
        if (-not $Credential) {
            $info.Error = "Credentials required to query LLDP data."
            return [PSCustomObject]$info
        }
    }

    # Run LLDP query with elevation
    $result = Invoke-Elevated -ScriptBlock {
        param($AdapterName)
        $info = @{
            Available = $false
            SwitchName = "N/A"
            SwitchIP = "N/A"
            Port = "N/A"
            PortDesc = "N/A"
            VLAN = "N/A"
            Error = $null
        }

        try {
            $neighbor = Get-NetLldpAgent -NetAdapterName $AdapterName -ErrorAction Stop |
                Get-NetLldpNeighborInformation -ErrorAction Stop

            if ($neighbor) {
                $info.Available = $true
                $info.SwitchName = if ($neighbor.ChassisId) { $neighbor.ChassisId } else { "N/A" }
                $info.SwitchIP = if ($neighbor.ManagementAddress) { $neighbor.ManagementAddress } else { "N/A" }
                $info.Port = if ($neighbor.PortId) { $neighbor.PortId } else { "N/A" }
                $info.PortDesc = if ($neighbor.PortDescription) { $neighbor.PortDescription } else { "N/A" }
                if ($neighbor.SystemDescription -match "VLAN[:\s]*(\d+)") {
                    $info.VLAN = $matches[1]
                }
            } else {
                $info.Error = "No LLDP data received yet. Wait 30 seconds and try again."
            }
        }
        catch {
            $dcb = Get-WindowsOptionalFeature -Online -FeatureName "DataCenterBridging" -ErrorAction SilentlyContinue
            if (-not $dcb -or $dcb.State -ne "Enabled") {
                $info.Error = "Click 'Setup LLDP' to configure (one-time setup)."
            } else {
                $info.Error = "LLDP agent not enabled on this adapter. Click 'Setup LLDP'."
            }
        }
        $info
    } -ArgumentList $AdapterName -Credential $Credential -OperationName "query LLDP info"

    if ($result.Success -and $result.Output) {
        return [PSCustomObject]$result.Output
    } else {
        $info.Error = if ($result.Error) { $result.Error } else { "Failed to query LLDP data." }
        return [PSCustomObject]$info
    }
}

# Get wireless info
$script:GetWirelessInfo = {
    $output = netsh wlan show interfaces 2>&1
    $info = @{
        Connected = $false
        SSID = "Not connected"
        BSSID = "N/A"
        Signal = 0
        Channel = 0
        Band = "N/A"
        Auth = "N/A"
        Speed = "N/A"
    }

    if ($output -match "There is no wireless interface") {
        $info.SSID = "No Wi-Fi adapter"
        return [PSCustomObject]$info
    }

    foreach ($line in $output) {
        if ($line -match "^\s+State\s+:\s+connected") { $info.Connected = $true }
        if ($line -match "^\s+SSID\s+:\s+(.+)$") { $info.SSID = $matches[1].Trim() }
        if ($line -match "^\s+BSSID\s+:\s+(.+)$") { $info.BSSID = $matches[1].Trim() }
        if ($line -match "^\s+Signal\s+:\s+(\d+)%") { $info.Signal = [int]$matches[1] }
        if ($line -match "^\s+Channel\s+:\s+(\d+)") { $info.Channel = [int]$matches[1] }
        if ($line -match "^\s+Radio type\s+:\s+(.+)$") { $info.Band = $matches[1].Trim() }
        if ($line -match "^\s+Authentication\s+:\s+(.+)$") { $info.Auth = $matches[1].Trim() }
        if ($line -match "^\s+Receive rate.*:\s+(.+)$") { $info.Speed = $matches[1].Trim() }
    }

    # Determine band from channel
    if ($info.Channel -gt 0) {
        if ($info.Channel -le 14) {
            $info.Band = "2.4 GHz"
        } else {
            $info.Band = "5 GHz"
        }
    }

    return [PSCustomObject]$info
}

# Scan for networks
$script:ScanNetworks = {
    $output = netsh wlan show networks mode=bssid 2>&1
    $networks = @()
    $current = $null

    foreach ($line in $output) {
        if ($line -match "^SSID \d+ : (.*)$") {
            if ($current) { $networks += [PSCustomObject]$current }
            $current = @{ SSID = $matches[1].Trim(); Signal = 0; Channel = 0; Security = "Unknown" }
        }
        if ($current) {
            if ($line -match "^\s+Signal\s+:\s+(\d+)%") { $current.Signal = [int]$matches[1] }
            if ($line -match "^\s+Channel\s+:\s+(\d+)") { $current.Channel = [int]$matches[1] }
            if ($line -match "^\s+Authentication\s+:\s+(.+)$") { $current.Security = $matches[1].Trim() }
        }
    }
    if ($current) { $networks += [PSCustomObject]$current }

    return $networks | Where-Object { $_.SSID -ne "" } | Sort-Object Signal -Descending
}

# Reconnect WiFi
$script:ReconnectWifi = {
    param([System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Reconnecting Wi-Fi...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $interfaceOutput = netsh wlan show interfaces
        $interface = ($interfaceOutput | Select-String "^\s+Name\s+:" | Select-Object -First 1) -replace ".*:\s+", ""
        $profile = ($interfaceOutput | Select-String "^\s+Profile\s+:" | Select-Object -First 1) -replace ".*:\s+", ""

        if ($interface -and $profile) {
            netsh wlan disconnect interface="$interface" | Out-Null
            $LogBox.AppendText("[$timestamp] Disconnected. Waiting 2 seconds...`r`n")
            $LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Seconds 2

            netsh wlan connect name="$profile" interface="$interface" | Out-Null
            $LogBox.AppendText("[$timestamp] Reconnect command sent to $profile`r`n")
        } else {
            $LogBox.AppendText("[$timestamp] No active Wi-Fi connection found.`r`n")
        }
    }
    catch {
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
    }
    $LogBox.ScrollToCaret()
}

#endregion

#region Initialize Module

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Store references for script blocks
    $getAdaptersRef = $script:GetAdapters
    $runPingRef = $script:RunPing
    $runTracerouteRef = $script:RunTraceroute
    $flushDnsRef = $script:FlushDns
    $releaseRenewRef = $script:ReleaseRenewIP
    $setupLldpRef = $script:SetupLldp
    $getLldpRef = $script:GetLldpInfo
    $getWirelessRef = $script:GetWirelessInfo
    $scanNetworksRef = $script:ScanNetworks
    $reconnectWifiRef = $script:ReconnectWifi

    # Main layout - split into sections
    $mainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.RowCount = 3
    $mainPanel.ColumnCount = 1
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 30))) | Out-Null
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 35))) | Out-Null
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 35))) | Out-Null

    #region Top Section - Adapters
    $adapterGroup = New-Object System.Windows.Forms.GroupBox
    $adapterGroup.Text = "Network Adapters"
    $adapterGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $adapterGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $adapterPanel = New-Object System.Windows.Forms.Panel
    $adapterPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:adapterListView = New-Object System.Windows.Forms.ListView
    $script:adapterListView.View = [System.Windows.Forms.View]::Details
    $script:adapterListView.FullRowSelect = $true
    $script:adapterListView.GridLines = $true
    $script:adapterListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:adapterListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:adapterListView.Columns.Add("Adapter", 120) | Out-Null
    $script:adapterListView.Columns.Add("Status", 80) | Out-Null
    $script:adapterListView.Columns.Add("IP Address", 120) | Out-Null
    $script:adapterListView.Columns.Add("MAC Address", 140) | Out-Null
    $script:adapterListView.Columns.Add("Gateway", 120) | Out-Null

    # Adapter buttons
    $adapterBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $adapterBtnPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $adapterBtnPanel.Height = 35
    $adapterBtnPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)

    $adapterListViewRef = $script:adapterListView

    $refreshAdaptersBtn = New-Object System.Windows.Forms.Button
    $refreshAdaptersBtn.Text = "Refresh"
    $refreshAdaptersBtn.Width = 70
    $refreshAdaptersBtn.Add_Click({
        $adapterListViewRef.Items.Clear()
        $adapters = & $getAdaptersRef
        foreach ($adapter in $adapters) {
            $item = New-Object System.Windows.Forms.ListViewItem($adapter.Name)
            $item.SubItems.Add($adapter.Status) | Out-Null
            $item.SubItems.Add($adapter.IP) | Out-Null
            $item.SubItems.Add($adapter.MAC) | Out-Null
            $item.SubItems.Add($adapter.Gateway) | Out-Null
            $item.Tag = $adapter
            $adapterListViewRef.Items.Add($item) | Out-Null
        }
    }.GetNewClosure())
    $adapterBtnPanel.Controls.Add($refreshAdaptersBtn)

    $releaseBtn = New-Object System.Windows.Forms.Button
    $releaseBtn.Text = "IP Release"
    $releaseBtn.Width = 75
    $releaseBtn.Add_Click({
        if ($adapterListViewRef.SelectedItems.Count -gt 0) {
            $adapter = $adapterListViewRef.SelectedItems[0].Tag
            & $releaseRenewRef -AdapterName $adapter.Name -Action "Release" -LogBox $script:diagLogBox
        }
    }.GetNewClosure())
    $adapterBtnPanel.Controls.Add($releaseBtn)

    $renewBtn = New-Object System.Windows.Forms.Button
    $renewBtn.Text = "IP Renew"
    $renewBtn.Width = 75
    $renewBtn.Add_Click({
        if ($adapterListViewRef.SelectedItems.Count -gt 0) {
            $adapter = $adapterListViewRef.SelectedItems[0].Tag
            & $releaseRenewRef -AdapterName $adapter.Name -Action "Renew" -LogBox $script:diagLogBox
        }
    }.GetNewClosure())
    $adapterBtnPanel.Controls.Add($renewBtn)

    $dnsFlushBtn = New-Object System.Windows.Forms.Button
    $dnsFlushBtn.Text = "DNS Flush"
    $dnsFlushBtn.Width = 75
    $dnsFlushBtn.Add_Click({
        & $flushDnsRef -LogBox $script:diagLogBox
    }.GetNewClosure())
    $adapterBtnPanel.Controls.Add($dnsFlushBtn)

    $copyAdaptersBtn = New-Object System.Windows.Forms.Button
    $copyAdaptersBtn.Text = "Copy All"
    $copyAdaptersBtn.Width = 70
    $copyAdaptersBtn.Add_Click({
        $text = [System.Text.StringBuilder]::new()
        [void]$text.AppendLine("Network Adapters - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        [void]$text.AppendLine("=" * 60)
        foreach ($item in $adapterListViewRef.Items) {
            $adapter = $item.Tag
            [void]$text.AppendLine("")
            [void]$text.AppendLine("Adapter: $($adapter.Name)")
            [void]$text.AppendLine("  Status:  $($adapter.Status)")
            [void]$text.AppendLine("  IP:      $($adapter.IP)")
            [void]$text.AppendLine("  MAC:     $($adapter.MAC)")
            [void]$text.AppendLine("  Gateway: $($adapter.Gateway)")
            [void]$text.AppendLine("  DNS:     $($adapter.DNS)")
        }
        [System.Windows.Forms.Clipboard]::SetText($text.ToString())
        [System.Windows.Forms.MessageBox]::Show("Copied to clipboard!", "Info", [System.Windows.Forms.MessageBoxButtons]::OK)
    }.GetNewClosure())
    $adapterBtnPanel.Controls.Add($copyAdaptersBtn)

    $adapterPanel.Controls.Add($script:adapterListView)
    $adapterPanel.Controls.Add($adapterBtnPanel)
    $adapterGroup.Controls.Add($adapterPanel)
    #endregion

    #region Middle Section - Diagnostics + Link Discovery
    $middlePanel = New-Object System.Windows.Forms.TableLayoutPanel
    $middlePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $middlePanel.ColumnCount = 2
    $middlePanel.RowCount = 1
    $middlePanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null
    $middlePanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null

    # Diagnostics group
    $diagGroup = New-Object System.Windows.Forms.GroupBox
    $diagGroup.Text = "Diagnostics"
    $diagGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $diagPanel = New-Object System.Windows.Forms.Panel
    $diagPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $diagPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    # Target input row
    $targetPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $targetPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $targetPanel.Height = 35

    $targetLabel = New-Object System.Windows.Forms.Label
    $targetLabel.Text = "Target:"
    $targetLabel.AutoSize = $true
    $targetLabel.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $targetPanel.Controls.Add($targetLabel)

    $script:targetTextBox = New-Object System.Windows.Forms.TextBox
    $script:targetTextBox.Width = 150
    $script:targetTextBox.Text = "8.8.8.8"
    $targetPanel.Controls.Add($script:targetTextBox)

    $targetTextBoxRef = $script:targetTextBox

    $pingBtn = New-Object System.Windows.Forms.Button
    $pingBtn.Text = "Ping"
    $pingBtn.Width = 50
    $pingBtn.Add_Click({
        $target = $targetTextBoxRef.Text.Trim()
        if ($target) {
            & $runPingRef -Target $target -Count 4 -LogBox $script:diagLogBox
        }
    }.GetNewClosure())
    $targetPanel.Controls.Add($pingBtn)

    $traceBtn = New-Object System.Windows.Forms.Button
    $traceBtn.Text = "Trace"
    $traceBtn.Width = 50
    $traceBtn.Add_Click({
        $target = $targetTextBoxRef.Text.Trim()
        if ($target) {
            & $runTracerouteRef -Target $target -LogBox $script:diagLogBox
        }
    }.GetNewClosure())
    $targetPanel.Controls.Add($traceBtn)

    # Diag log
    $script:diagLogBox = New-Object System.Windows.Forms.TextBox
    $script:diagLogBox.Multiline = $true
    $script:diagLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:diagLogBox.ReadOnly = $true
    $script:diagLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:diagLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $diagLogBoxRef = $script:diagLogBox

    # Copy results button
    $diagBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $diagBtnPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $diagBtnPanel.Height = 35

    $copyResultsBtn = New-Object System.Windows.Forms.Button
    $copyResultsBtn.Text = "Copy Results"
    $copyResultsBtn.Width = 90
    $copyResultsBtn.Add_Click({
        if ($diagLogBoxRef.Text) {
            [System.Windows.Forms.Clipboard]::SetText($diagLogBoxRef.Text)
            [System.Windows.Forms.MessageBox]::Show("Copied to clipboard!", "Info", [System.Windows.Forms.MessageBoxButtons]::OK)
        }
    }.GetNewClosure())
    $diagBtnPanel.Controls.Add($copyResultsBtn)

    $clearLogBtn = New-Object System.Windows.Forms.Button
    $clearLogBtn.Text = "Clear"
    $clearLogBtn.Width = 50
    $clearLogBtn.Add_Click({
        $diagLogBoxRef.Clear()
    }.GetNewClosure())
    $diagBtnPanel.Controls.Add($clearLogBtn)

    $diagPanel.Controls.Add($script:diagLogBox)
    $diagPanel.Controls.Add($targetPanel)
    $diagPanel.Controls.Add($diagBtnPanel)
    $diagGroup.Controls.Add($diagPanel)

    # Link Discovery group
    $lldpGroup = New-Object System.Windows.Forms.GroupBox
    $lldpGroup.Text = "Link Discovery (LLDP)"
    $lldpGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $lldpPanel = New-Object System.Windows.Forms.Panel
    $lldpPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lldpPanel.Padding = New-Object System.Windows.Forms.Padding(10)

    $script:lldpInfoLabel = New-Object System.Windows.Forms.Label
    $script:lldpInfoLabel.Text = "Switch Port: N/A`nVLAN: N/A`nSwitch IP: N/A`nSwitch Name: N/A"
    $script:lldpInfoLabel.AutoSize = $true
    $script:lldpInfoLabel.Font = New-Object System.Drawing.Font("Consolas", 10)
    $script:lldpInfoLabel.Location = New-Object System.Drawing.Point(10, 50)

    $lldpInfoLabelRef = $script:lldpInfoLabel

    $getLldpBtn = New-Object System.Windows.Forms.Button
    $getLldpBtn.Text = "Get Switch Info"
    $getLldpBtn.Width = 120
    $getLldpBtn.Location = New-Object System.Drawing.Point(10, 15)
    $getLldpBtn.Add_Click({
        if ($adapterListViewRef.SelectedItems.Count -gt 0) {
            $adapter = $adapterListViewRef.SelectedItems[0].Tag
            $lldpInfoLabelRef.Text = "Querying LLDP..."
            [System.Windows.Forms.Application]::DoEvents()

            $info = & $getLldpRef -AdapterName $adapter.Name

            if ($info.Available) {
                $lldpInfoLabelRef.Text = "Switch Port: $($info.Port)`nPort Desc: $($info.PortDesc)`nVLAN: $($info.VLAN)`nSwitch IP: $($info.SwitchIP)`nSwitch Name: $($info.SwitchName)"
            } else {
                $lldpInfoLabelRef.Text = "LLDP Info:`n`n$($info.Error)"
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show("Select an adapter first", "Info", [System.Windows.Forms.MessageBoxButtons]::OK)
        }
    }.GetNewClosure())
    $lldpPanel.Controls.Add($getLldpBtn)

    $copyLldpBtn = New-Object System.Windows.Forms.Button
    $copyLldpBtn.Text = "Copy"
    $copyLldpBtn.Width = 50
    $copyLldpBtn.Location = New-Object System.Drawing.Point(135, 15)
    $copyLldpBtn.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($lldpInfoLabelRef.Text)
        [System.Windows.Forms.MessageBox]::Show("Copied!", "Info", [System.Windows.Forms.MessageBoxButtons]::OK)
    }.GetNewClosure())
    $lldpPanel.Controls.Add($copyLldpBtn)

    # Setup LLDP button (one-time on tech laptop)
    $setupLldpBtn = New-Object System.Windows.Forms.Button
    $setupLldpBtn.Text = "Setup LLDP"
    $setupLldpBtn.Width = 90
    $setupLldpBtn.Location = New-Object System.Drawing.Point(10, 140)
    $setupLldpBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 240, 255)
    $setupLldpBtn.Add_Click({
        & $setupLldpRef -LogBox $script:diagLogBox
    }.GetNewClosure())
    $lldpPanel.Controls.Add($setupLldpBtn)

    # Help label
    $lldpHelpLabel = New-Object System.Windows.Forms.Label
    $lldpHelpLabel.Text = "(One-time setup for tech laptop)"
    $lldpHelpLabel.AutoSize = $true
    $lldpHelpLabel.ForeColor = [System.Drawing.Color]::Gray
    $lldpHelpLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7)
    $lldpHelpLabel.Location = New-Object System.Drawing.Point(105, 145)
    $lldpPanel.Controls.Add($lldpHelpLabel)

    $lldpPanel.Controls.Add($script:lldpInfoLabel)
    $lldpGroup.Controls.Add($lldpPanel)

    $middlePanel.Controls.Add($diagGroup, 0, 0)
    $middlePanel.Controls.Add($lldpGroup, 1, 0)
    #endregion

    #region Bottom Section - Wireless
    $wirelessGroup = New-Object System.Windows.Forms.GroupBox
    $wirelessGroup.Text = "Wireless"
    $wirelessGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $wirelessPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $wirelessPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $wirelessPanel.ColumnCount = 2
    $wirelessPanel.RowCount = 1
    $wirelessPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null
    $wirelessPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null

    # Left - Current connection info
    $wifiInfoPanel = New-Object System.Windows.Forms.Panel
    $wifiInfoPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $wifiInfoPanel.Padding = New-Object System.Windows.Forms.Padding(10)

    $script:wifiInfoLabel = New-Object System.Windows.Forms.Label
    $script:wifiInfoLabel.Text = "Loading..."
    $script:wifiInfoLabel.AutoSize = $true
    $script:wifiInfoLabel.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:wifiInfoLabel.Location = New-Object System.Drawing.Point(10, 10)
    $wifiInfoPanel.Controls.Add($script:wifiInfoLabel)

    $wifiInfoLabelRef = $script:wifiInfoLabel

    # Signal bar
    $script:signalBar = New-Object System.Windows.Forms.ProgressBar
    $script:signalBar.Location = New-Object System.Drawing.Point(10, 100)
    $script:signalBar.Size = New-Object System.Drawing.Size(150, 20)
    $script:signalBar.Minimum = 0
    $script:signalBar.Maximum = 100
    $wifiInfoPanel.Controls.Add($script:signalBar)

    $signalBarRef = $script:signalBar

    # WiFi buttons
    $wifiBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $wifiBtnPanel.Location = New-Object System.Drawing.Point(10, 130)
    $wifiBtnPanel.Size = New-Object System.Drawing.Size(200, 70)
    $wifiBtnPanel.WrapContents = $true

    $refreshWifiBtn = New-Object System.Windows.Forms.Button
    $refreshWifiBtn.Text = "Refresh"
    $refreshWifiBtn.Width = 65
    $refreshWifiBtn.Add_Click({
        $info = & $getWirelessRef
        $signalBarRef.Value = $info.Signal

        $text = "SSID: $($info.SSID)`n"
        $text += "Signal: $($info.Signal)%`n"
        $text += "Channel: $($info.Channel) ($($info.Band))`n"
        $text += "BSSID: $($info.BSSID)`n"
        $text += "Auth: $($info.Auth)"
        $wifiInfoLabelRef.Text = $text
    }.GetNewClosure())
    $wifiBtnPanel.Controls.Add($refreshWifiBtn)

    $reconnectBtn = New-Object System.Windows.Forms.Button
    $reconnectBtn.Text = "Reconnect"
    $reconnectBtn.Width = 75
    $reconnectBtn.Add_Click({
        & $reconnectWifiRef -LogBox $diagLogBoxRef
    }.GetNewClosure())
    $wifiBtnPanel.Controls.Add($reconnectBtn)

    $copyWifiBtn = New-Object System.Windows.Forms.Button
    $copyWifiBtn.Text = "Copy"
    $copyWifiBtn.Width = 50
    $copyWifiBtn.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($wifiInfoLabelRef.Text)
        [System.Windows.Forms.MessageBox]::Show("Copied!", "Info", [System.Windows.Forms.MessageBoxButtons]::OK)
    }.GetNewClosure())
    $wifiBtnPanel.Controls.Add($copyWifiBtn)

    $wifiInfoPanel.Controls.Add($wifiBtnPanel)

    # Right - Available networks
    $networksPanel = New-Object System.Windows.Forms.Panel
    $networksPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $networksPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:networksListView = New-Object System.Windows.Forms.ListView
    $script:networksListView.View = [System.Windows.Forms.View]::Details
    $script:networksListView.FullRowSelect = $true
    $script:networksListView.GridLines = $true
    $script:networksListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:networksListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:networksListView.Columns.Add("SSID", 150) | Out-Null
    $script:networksListView.Columns.Add("Signal", 60) | Out-Null
    $script:networksListView.Columns.Add("Ch", 40) | Out-Null
    $script:networksListView.Columns.Add("Security", 100) | Out-Null

    $networksListViewRef = $script:networksListView

    $networksBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $networksBtnPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $networksBtnPanel.Height = 35

    $scanBtn = New-Object System.Windows.Forms.Button
    $scanBtn.Text = "Scan Networks"
    $scanBtn.Width = 100
    $scanBtn.Add_Click({
        $networksListViewRef.Items.Clear()
        $networks = & $scanNetworksRef
        foreach ($net in $networks) {
            $item = New-Object System.Windows.Forms.ListViewItem($net.SSID)
            $item.SubItems.Add("$($net.Signal)%") | Out-Null
            $item.SubItems.Add($net.Channel.ToString()) | Out-Null
            $item.SubItems.Add($net.Security) | Out-Null
            $networksListViewRef.Items.Add($item) | Out-Null
        }
    }.GetNewClosure())
    $networksBtnPanel.Controls.Add($scanBtn)

    $networksPanel.Controls.Add($script:networksListView)
    $networksPanel.Controls.Add($networksBtnPanel)

    $wirelessPanel.Controls.Add($wifiInfoPanel, 0, 0)
    $wirelessPanel.Controls.Add($networksPanel, 1, 0)
    $wirelessGroup.Controls.Add($wirelessPanel)
    #endregion

    # Add sections to main panel
    $mainPanel.Controls.Add($adapterGroup, 0, 0)
    $mainPanel.Controls.Add($middlePanel, 0, 1)
    $mainPanel.Controls.Add($wirelessGroup, 0, 2)

    $tab.Controls.Add($mainPanel)

    # Initial load
    $refreshAdaptersBtn.PerformClick()
    $refreshWifiBtn.PerformClick()
}

#endregion
