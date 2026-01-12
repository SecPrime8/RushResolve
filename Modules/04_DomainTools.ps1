<#
.SYNOPSIS
    Domain Tools Module for Rush Resolve
.DESCRIPTION
    Domain troubleshooting tools: trust repair, domain rejoin, gpupdate, and DC connectivity testing.
#>

$script:ModuleName = "Domain Tools"
$script:ModuleDescription = "Repair domain trust, rejoin domain, and verify DC connectivity"

#region Script Blocks

# Get current domain status
$script:GetDomainStatus = {
    $status = @{
        ComputerName = $env:COMPUTERNAME
        Domain = $null
        IsDomainJoined = $false
        TrustStatus = "Unknown"
        LastDC = $null
    }

    try {
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PartOfDomain) {
            $status.IsDomainJoined = $true
            $status.Domain = $cs.Domain

            # Get logon server (last DC used)
            $status.LastDC = $env:LOGONSERVER -replace '\\\\', ''
        } else {
            $status.Domain = "WORKGROUP"
        }
    }
    catch {
        $status.Domain = "Error: $_"
    }

    return [PSCustomObject]$status
}

# Test secure channel (trust relationship)
$script:TestSecureChannel = {
    param([System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Testing domain trust relationship...`r`n")
    $LogBox.AppendText("[$timestamp] Running diagnostics...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # Gather diagnostic info first
        $dc = $env:LOGONSERVER -replace '\\\\', ''
        $domain = (Get-WmiObject Win32_ComputerSystem).Domain
        $LogBox.AppendText("[$timestamp]   Domain: $domain`r`n")
        $LogBox.AppendText("[$timestamp]   Logon Server (DC): $dc`r`n")

        # Check time sync (Kerberos fails if >5 min drift)
        try {
            $w32tm = w32tm /query /status 2>&1 | Out-String
            if ($w32tm -match "Source:\s*(.+)") {
                $timeSource = $matches[1].Trim()
                $LogBox.AppendText("[$timestamp]   Time Source: $timeSource`r`n")
            }
            # Check for time skew warning
            $ntpQuery = w32tm /stripchart /computer:$dc /samples:1 /dataonly 2>&1 | Out-String
            if ($ntpQuery -match "([+-]?\d+\.\d+)s") {
                $skewSeconds = [math]::Abs([double]$matches[1])
                if ($skewSeconds -gt 300) {
                    $LogBox.AppendText("[$timestamp]   TIME SKEW WARNING: ${skewSeconds}s drift (Kerberos limit: 300s)`r`n")
                    Write-SessionLog -Message "Time skew detected: ${skewSeconds}s" -Category "Domain Tools"
                } else {
                    $LogBox.AppendText("[$timestamp]   Time Skew: ${skewSeconds}s (OK)`r`n")
                }
            }
        }
        catch {
            $LogBox.AppendText("[$timestamp]   Time check: Could not query ($($_.Exception.Message))`r`n")
        }

        [System.Windows.Forms.Application]::DoEvents()

        # Test the secure channel
        $LogBox.AppendText("[$timestamp] Running Test-ComputerSecureChannel...`r`n")
        $trustOK = Test-ComputerSecureChannel

        if ($trustOK) {
            $LogBox.AppendText("[$timestamp] Trust Status: OK - Secure channel is valid`r`n")
            Write-SessionLog -Message "Trust test: PASSED (DC: $dc)" -Category "Domain Tools"
            return @{ Success = $true; TrustOK = $true; Message = "Trust relationship is healthy" }
        } else {
            $LogBox.AppendText("[$timestamp] Trust Status: BROKEN - Secure channel failed`r`n")
            $LogBox.AppendText("[$timestamp] Possible causes:`r`n")
            $LogBox.AppendText("[$timestamp]   - Computer account password mismatch with AD`r`n")
            $LogBox.AppendText("[$timestamp]   - Computer account deleted/disabled in AD`r`n")
            $LogBox.AppendText("[$timestamp]   - Machine restored from old backup`r`n")
            $LogBox.AppendText("[$timestamp]   - Network issues during last password rotation`r`n")
            Write-SessionLog -Message "Trust test: BROKEN (DC: $dc)" -Category "Domain Tools"
            return @{ Success = $true; TrustOK = $false; Message = "Trust relationship is broken" }
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        $LogBox.AppendText("[$timestamp] ERROR: $errorMsg`r`n")

        # Provide specific guidance based on error
        if ($errorMsg -match "access.*denied" -or $errorMsg -match "0x5") {
            $LogBox.AppendText("[$timestamp] Hint: Access denied - may need to run as admin or trust already broken`r`n")
        }
        elseif ($errorMsg -match "network|RPC|unavailable") {
            $LogBox.AppendText("[$timestamp] Hint: Network issue - check DC connectivity`r`n")
        }
        elseif ($errorMsg -match "not found|no such") {
            $LogBox.AppendText("[$timestamp] Hint: Computer account may not exist in AD`r`n")
        }

        Write-SessionLog -Message "Trust test: ERROR - $errorMsg" -Category "Domain Tools"
        return @{ Success = $false; TrustOK = $false; Message = $errorMsg }
    }
    finally {
        $LogBox.ScrollToCaret()
    }
}

# Repair trust relationship (requires elevation)
$script:RepairTrust = {
    param([System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Attempting to repair domain trust...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # Get credentials for domain admin
        $cred = Get-ElevatedCredential -Message "Enter domain admin credentials to repair trust"
        if (-not $cred) {
            $LogBox.AppendText("[$timestamp] Cancelled - no credentials provided`r`n")
            return @{ Success = $false; Message = "Cancelled by user" }
        }

        $LogBox.AppendText("[$timestamp] Running repair with provided credentials...`r`n")
        $LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()

        $repairResult = Test-ComputerSecureChannel -Repair -Credential $cred -ErrorAction Stop

        if ($repairResult) {
            $LogBox.AppendText("[$timestamp] SUCCESS: Domain trust repaired`r`n")
            Write-SessionLog -Message "Trust repair: SUCCESS" -Category "Domain Tools"
            return @{ Success = $true; Message = "Trust relationship repaired successfully" }
        } else {
            $LogBox.AppendText("[$timestamp] FAILED: Could not repair trust`r`n")
            Write-SessionLog -Message "Trust repair: FAILED" -Category "Domain Tools"
            return @{ Success = $false; Message = "Repair command completed but trust still broken" }
        }
    }
    catch {
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
        return @{ Success = $false; Message = $_.Exception.Message }
    }
    finally {
        $LogBox.ScrollToCaret()
    }
}

# Test DC connectivity
$script:TestDCConnectivity = {
    param([System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Testing domain controller connectivity...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    $result = @{
        Success = $false
        DCName = "N/A"
        DCIP = "N/A"
        PingOK = $false
        LDAPOK = $false
        DNSOK = $false
        Error = $null
    }

    try {
        # Get domain name
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        if (-not $cs.PartOfDomain) {
            $LogBox.AppendText("[$timestamp] Computer is not domain-joined`r`n")
            $result.Error = "Not domain-joined"
            return [PSCustomObject]$result
        }

        $domain = $cs.Domain
        $LogBox.AppendText("[$timestamp] Domain: $domain`r`n")

        # Discover DC - try LOGONSERVER first (most reliable)
        $LogBox.AppendText("[$timestamp] Discovering domain controller...`r`n")
        [System.Windows.Forms.Application]::DoEvents()

        $dcShortName = $env:LOGONSERVER -replace '\\\\', ''
        if ($dcShortName) {
            $result.DCName = $dcShortName
            $LogBox.AppendText("[$timestamp] DC Found: $($result.DCName)`r`n")
        } else {
            # Fallback to nltest
            $nltestOutput = nltest /dsgetdc:$domain 2>&1
            if ($nltestOutput -match "DC: \\\\([^\s\.]+)") {
                $result.DCName = $matches[1]
                $LogBox.AppendText("[$timestamp] DC Found (nltest): $($result.DCName)`r`n")
            }
        }

        # Try DNS resolution - use FQDN for better resolution
        $LogBox.AppendText("[$timestamp] Testing DNS resolution...`r`n")
        [System.Windows.Forms.Application]::DoEvents()

        $dcFQDN = "$($result.DCName).$domain"
        try {
            $dnsResult = Resolve-DnsName -Name $dcFQDN -ErrorAction Stop
            $result.DCIP = ($dnsResult | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1).IPAddress
            $result.DNSOK = $true
            $LogBox.AppendText("[$timestamp] DNS: OK - $dcFQDN resolved to $($result.DCIP)`r`n")
        }
        catch {
            # Try short name as fallback
            try {
                $dnsResult = Resolve-DnsName -Name $result.DCName -ErrorAction Stop
                $result.DCIP = ($dnsResult | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1).IPAddress
                $result.DNSOK = $true
                $LogBox.AppendText("[$timestamp] DNS: OK - $($result.DCName) resolved to $($result.DCIP)`r`n")
            }
            catch {
                $LogBox.AppendText("[$timestamp] DNS: FAILED - Could not resolve $dcFQDN or $($result.DCName)`r`n")
            }
        }

        # Ping test
        if ($result.DCName -ne "N/A") {
            $LogBox.AppendText("[$timestamp] Testing ping to DC...`r`n")
            [System.Windows.Forms.Application]::DoEvents()

            try {
                $ping = Test-Connection -ComputerName $result.DCName -Count 2 -ErrorAction Stop
                $result.PingOK = $true
                $avgTime = ($ping | Measure-Object -Property ResponseTime -Average).Average
                $LogBox.AppendText("[$timestamp] Ping: OK - Average $([math]::Round($avgTime, 1))ms`r`n")
            }
            catch {
                $LogBox.AppendText("[$timestamp] Ping: FAILED - DC not responding`r`n")
            }
        }

        # LDAP port test (389)
        if ($result.DCIP -ne "N/A") {
            $LogBox.AppendText("[$timestamp] Testing LDAP port 389...`r`n")
            [System.Windows.Forms.Application]::DoEvents()

            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $connect = $tcp.BeginConnect($result.DCIP, 389, $null, $null)
                $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
                if ($wait -and $tcp.Connected) {
                    $result.LDAPOK = $true
                    $LogBox.AppendText("[$timestamp] LDAP: OK - Port 389 open`r`n")
                } else {
                    $LogBox.AppendText("[$timestamp] LDAP: FAILED - Port 389 not reachable`r`n")
                }
                $tcp.Close()
            }
            catch {
                $LogBox.AppendText("[$timestamp] LDAP: FAILED - $_`r`n")
            }
        }

        $result.Success = $result.PingOK -or $result.LDAPOK
        $LogBox.AppendText("`r`n[$timestamp] Connectivity test complete`r`n")
    }
    catch {
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
        $result.Error = $_.Exception.Message
    }
    finally {
        $LogBox.ScrollToCaret()
    }

    return [PSCustomObject]$result
}

# Run gpupdate
$script:RunGPUpdate = {
    param([bool]$Sync, [System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $args = "/force"
    if ($Sync) { $args += " /sync" }

    $LogBox.AppendText("[$timestamp] Running gpupdate $args...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $output = gpupdate $args.Split(' ') 2>&1
        foreach ($line in $output) {
            if ($line -and $line.ToString().Trim()) {
                $LogBox.AppendText("[$timestamp]   $line`r`n")
                $LogBox.ScrollToCaret()
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        $LogBox.AppendText("[$timestamp] GPUpdate complete`r`n")
        return @{ Success = $true; Message = "Group policy updated" }
    }
    catch {
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
        return @{ Success = $false; Message = $_.Exception.Message }
    }
    finally {
        $LogBox.ScrollToCaret()
    }
}

# Leave domain
$script:LeaveDomain = {
    param([System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Preparing to leave domain...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $cred = Get-ElevatedCredential -Message "Enter domain admin credentials to unjoin domain"
        if (-not $cred) {
            $LogBox.AppendText("[$timestamp] Cancelled - no credentials provided`r`n")
            return @{ Success = $false; Message = "Cancelled by user" }
        }

        $LogBox.AppendText("[$timestamp] Removing computer from domain...`r`n")
        $LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()

        Remove-Computer -UnjoinDomainCredential $cred -PassThru -Force -ErrorAction Stop

        $LogBox.AppendText("[$timestamp] SUCCESS: Computer removed from domain`r`n")
        $LogBox.AppendText("[$timestamp] RESTART REQUIRED to complete the operation`r`n")
        Write-SessionLog -Message "LEAVE DOMAIN: SUCCESS - restart required" -Category "Domain Tools"
        return @{ Success = $true; Message = "Domain leave successful - restart required" }
    }
    catch {
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
        return @{ Success = $false; Message = $_.Exception.Message }
    }
    finally {
        $LogBox.ScrollToCaret()
    }
}

# Join domain
$script:JoinDomain = {
    param([string]$DomainName, [System.Windows.Forms.TextBox]$LogBox)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Preparing to join domain: $DomainName...`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $cred = Get-ElevatedCredential -Message "Enter domain admin credentials to join $DomainName"
        if (-not $cred) {
            $LogBox.AppendText("[$timestamp] Cancelled - no credentials provided`r`n")
            return @{ Success = $false; Message = "Cancelled by user" }
        }

        $LogBox.AppendText("[$timestamp] Joining computer to $DomainName...`r`n")
        $LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()

        Add-Computer -DomainName $DomainName -Credential $cred -PassThru -Force -ErrorAction Stop

        $LogBox.AppendText("[$timestamp] SUCCESS: Computer joined to $DomainName`r`n")
        $LogBox.AppendText("[$timestamp] RESTART REQUIRED to complete the operation`r`n")
        Write-SessionLog -Message "JOIN DOMAIN: SUCCESS ($DomainName) - restart required" -Category "Domain Tools"
        return @{ Success = $true; Message = "Domain join successful - restart required" }
    }
    catch {
        $LogBox.AppendText("[$timestamp] ERROR: $_`r`n")
        return @{ Success = $false; Message = $_.Exception.Message }
    }
    finally {
        $LogBox.ScrollToCaret()
    }
}

#endregion

#region Initialize Module

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Store references for closures
    $getDomainStatusRef = $script:GetDomainStatus
    $testSecureChannelRef = $script:TestSecureChannel
    $repairTrustRef = $script:RepairTrust
    $testDCConnectivityRef = $script:TestDCConnectivity
    $runGPUpdateRef = $script:RunGPUpdate
    $leaveDomainRef = $script:LeaveDomain
    $joinDomainRef = $script:JoinDomain

    # Main layout - 5 rows
    $mainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.RowCount = 5
    $mainPanel.ColumnCount = 1
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 80))) | Out-Null   # Status
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 55))) | Out-Null   # Trust & Policy
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 90))) | Out-Null   # DC Connectivity
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 55))) | Out-Null   # Domain Rejoin
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null   # Log

    #region Row 0 - Domain Status
    $statusGroup = New-Object System.Windows.Forms.GroupBox
    $statusGroup.Text = "Domain Status"
    $statusGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusGroup.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 5)

    $statusPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $statusPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusPanel.WrapContents = $true

    # Computer name
    $compLabel = New-Object System.Windows.Forms.Label
    $compLabel.Text = "Computer:"
    $compLabel.AutoSize = $true
    $compLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $statusPanel.Controls.Add($compLabel)

    $script:compValueLabel = New-Object System.Windows.Forms.Label
    $script:compValueLabel.Text = "Loading..."
    $script:compValueLabel.AutoSize = $true
    $script:compValueLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $script:compValueLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 20, 0)
    $statusPanel.Controls.Add($script:compValueLabel)

    # Domain
    $domainLabel = New-Object System.Windows.Forms.Label
    $domainLabel.Text = "Domain:"
    $domainLabel.AutoSize = $true
    $domainLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $statusPanel.Controls.Add($domainLabel)

    $script:domainValueLabel = New-Object System.Windows.Forms.Label
    $script:domainValueLabel.Text = "Loading..."
    $script:domainValueLabel.AutoSize = $true
    $script:domainValueLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $script:domainValueLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 20, 0)
    $statusPanel.Controls.Add($script:domainValueLabel)

    # Trust status
    $trustLabel = New-Object System.Windows.Forms.Label
    $trustLabel.Text = "Trust:"
    $trustLabel.AutoSize = $true
    $trustLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $statusPanel.Controls.Add($trustLabel)

    $script:trustValueLabel = New-Object System.Windows.Forms.Label
    $script:trustValueLabel.Text = "[Not Tested]"
    $script:trustValueLabel.AutoSize = $true
    $script:trustValueLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $script:trustValueLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 20, 0)
    $statusPanel.Controls.Add($script:trustValueLabel)

    # DC
    $dcLabel = New-Object System.Windows.Forms.Label
    $dcLabel.Text = "DC:"
    $dcLabel.AutoSize = $true
    $dcLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $statusPanel.Controls.Add($dcLabel)

    $script:dcValueLabel = New-Object System.Windows.Forms.Label
    $script:dcValueLabel.Text = "N/A"
    $script:dcValueLabel.AutoSize = $true
    $script:dcValueLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $script:dcValueLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 20, 0)
    $statusPanel.Controls.Add($script:dcValueLabel)

    # Refresh button
    $refreshStatusBtn = New-Object System.Windows.Forms.Button
    $refreshStatusBtn.Text = "Refresh"
    $refreshStatusBtn.Width = 80
    $refreshStatusBtn.Height = 25
    $statusPanel.Controls.Add($refreshStatusBtn)

    $statusGroup.Controls.Add($statusPanel)
    $mainPanel.Controls.Add($statusGroup, 0, 0)
    #endregion

    #region Row 1 - Trust & Policy
    $trustGroup = New-Object System.Windows.Forms.GroupBox
    $trustGroup.Text = "Trust and Policy"
    $trustGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $trustGroup.Padding = New-Object System.Windows.Forms.Padding(10, 3, 10, 3)

    $trustPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $trustPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $testTrustBtn = New-Object System.Windows.Forms.Button
    $testTrustBtn.Text = "Test Trust"
    $testTrustBtn.Width = 85
    $testTrustBtn.Height = 28
    $trustPanel.Controls.Add($testTrustBtn)

    $repairTrustBtn = New-Object System.Windows.Forms.Button
    $repairTrustBtn.Text = "Repair Trust *"
    $repairTrustBtn.Width = 100
    $repairTrustBtn.Height = 28
    $repairTrustBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    $trustPanel.Controls.Add($repairTrustBtn)

    $gpupdateBtn = New-Object System.Windows.Forms.Button
    $gpupdateBtn.Text = "GPUpdate"
    $gpupdateBtn.Width = 85
    $gpupdateBtn.Height = 28
    $trustPanel.Controls.Add($gpupdateBtn)

    $script:syncCheckbox = New-Object System.Windows.Forms.CheckBox
    $script:syncCheckbox.Text = "Sync"
    $script:syncCheckbox.AutoSize = $true
    $script:syncCheckbox.Padding = New-Object System.Windows.Forms.Padding(5, 5, 0, 0)
    $trustPanel.Controls.Add($script:syncCheckbox)

    $trustGroup.Controls.Add($trustPanel)
    $mainPanel.Controls.Add($trustGroup, 0, 1)
    #endregion

    #region Row 2 - DC Connectivity
    $dcGroup = New-Object System.Windows.Forms.GroupBox
    $dcGroup.Text = "DC Connectivity"
    $dcGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $dcGroup.Padding = New-Object System.Windows.Forms.Padding(10, 3, 10, 3)

    $dcPanel = New-Object System.Windows.Forms.Panel
    $dcPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    # DC info labels
    $script:dcInfoLabel = New-Object System.Windows.Forms.Label
    $script:dcInfoLabel.Text = "DC: N/A    IP: N/A`r`nPing: N/A    LDAP: N/A    DNS: N/A"
    $script:dcInfoLabel.AutoSize = $true
    $script:dcInfoLabel.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:dcInfoLabel.Location = New-Object System.Drawing.Point(10, 5)
    $dcPanel.Controls.Add($script:dcInfoLabel)

    $testConnBtn = New-Object System.Windows.Forms.Button
    $testConnBtn.Text = "Test Connectivity"
    $testConnBtn.Width = 140
    $testConnBtn.Height = 28
    $testConnBtn.Location = New-Object System.Drawing.Point(10, 40)
    $dcPanel.Controls.Add($testConnBtn)

    $dcGroup.Controls.Add($dcPanel)
    $mainPanel.Controls.Add($dcGroup, 0, 2)
    #endregion

    #region Row 3 - Domain Rejoin
    $rejoinGroup = New-Object System.Windows.Forms.GroupBox
    $rejoinGroup.Text = "Domain Rejoin"
    $rejoinGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rejoinGroup.Padding = New-Object System.Windows.Forms.Padding(10, 3, 10, 3)

    $rejoinPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $rejoinPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $leaveBtn = New-Object System.Windows.Forms.Button
    $leaveBtn.Text = "Leave Domain *"
    $leaveBtn.Width = 115
    $leaveBtn.Height = 28
    $leaveBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 230)
    $rejoinPanel.Controls.Add($leaveBtn)

    $rejoinBtn = New-Object System.Windows.Forms.Button
    $rejoinBtn.Text = "Rejoin Domain *"
    $rejoinBtn.Width = 115
    $rejoinBtn.Height = 28
    $rejoinBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    $rejoinPanel.Controls.Add($rejoinBtn)

    $script:restartCheckbox = New-Object System.Windows.Forms.CheckBox
    $script:restartCheckbox.Text = "Restart after operation"
    $script:restartCheckbox.AutoSize = $true
    $script:restartCheckbox.Checked = $true
    $script:restartCheckbox.Padding = New-Object System.Windows.Forms.Padding(15, 5, 0, 0)
    $rejoinPanel.Controls.Add($script:restartCheckbox)

    $rejoinGroup.Controls.Add($rejoinPanel)
    $mainPanel.Controls.Add($rejoinGroup, 0, 3)
    #endregion

    #region Row 4 - Activity Log
    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = "Activity Log"
    $logGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $logPanel = New-Object System.Windows.Forms.Panel
    $logPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:logBox = New-Object System.Windows.Forms.TextBox
    $script:logBox.Multiline = $true
    $script:logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:logBox.ReadOnly = $true
    $script:logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:logBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:logBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:logBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $logBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $logBtnPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $logBtnPanel.Height = 30

    $copyLogBtn = New-Object System.Windows.Forms.Button
    $copyLogBtn.Text = "Copy Log"
    $copyLogBtn.Width = 85
    $logBtnPanel.Controls.Add($copyLogBtn)

    $clearLogBtn = New-Object System.Windows.Forms.Button
    $clearLogBtn.Text = "Clear"
    $clearLogBtn.Width = 55
    $logBtnPanel.Controls.Add($clearLogBtn)

    $logPanel.Controls.Add($script:logBox)
    $logPanel.Controls.Add($logBtnPanel)
    $logGroup.Controls.Add($logPanel)
    $mainPanel.Controls.Add($logGroup, 0, 4)
    #endregion

    #region Event Handlers

    # Store references for closures
    $compValueLabelRef = $script:compValueLabel
    $domainValueLabelRef = $script:domainValueLabel
    $trustValueLabelRef = $script:trustValueLabel
    $dcValueLabelRef = $script:dcValueLabel
    $dcInfoLabelRef = $script:dcInfoLabel
    $logBoxRef = $script:logBox
    $syncCheckboxRef = $script:syncCheckbox
    $restartCheckboxRef = $script:restartCheckbox

    # Refresh status
    $refreshStatusBtn.Add_Click({
        $status = & $getDomainStatusRef
        $compValueLabelRef.Text = $status.ComputerName
        $domainValueLabelRef.Text = if ($status.IsDomainJoined) { $status.Domain } else { "WORKGROUP (not joined)" }
        $dcValueLabelRef.Text = if ($status.LastDC) { $status.LastDC } else { "N/A" }

        $timestamp = Get-Date -Format "HH:mm:ss"
        $logBoxRef.AppendText("[$timestamp] Status refreshed - Computer: $($status.ComputerName), Domain: $($status.Domain)`r`n")
        $logBoxRef.ScrollToCaret()
    }.GetNewClosure())

    # Test trust
    $testTrustBtn.Add_Click({
        $result = & $testSecureChannelRef -LogBox $logBoxRef
        if ($result.TrustOK) {
            $trustValueLabelRef.Text = "[OK]"
            $trustValueLabelRef.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $trustValueLabelRef.Text = "[BROKEN]"
            $trustValueLabelRef.ForeColor = [System.Drawing.Color]::Red
        }
    }.GetNewClosure())

    # Repair trust
    $repairTrustBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "This will attempt to repair the domain trust relationship.`n`nYou will need domain admin credentials.`n`nContinue?",
            "Repair Trust",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $result = & $repairTrustRef -LogBox $logBoxRef
            if ($result.Success) {
                $trustValueLabelRef.Text = "[OK]"
                $trustValueLabelRef.ForeColor = [System.Drawing.Color]::DarkGreen
                [System.Windows.Forms.MessageBox]::Show(
                    $result.Message,
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed: $($result.Message)",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        }
    }.GetNewClosure())

    # GPUpdate
    $gpupdateBtn.Add_Click({
        $sync = $syncCheckboxRef.Checked
        & $runGPUpdateRef -Sync $sync -LogBox $logBoxRef
    }.GetNewClosure())

    # Test DC connectivity
    $testConnBtn.Add_Click({
        $result = & $testDCConnectivityRef -LogBox $logBoxRef

        $pingStatus = if ($result.PingOK) { "OK" } else { "FAILED" }
        $ldapStatus = if ($result.LDAPOK) { "OK" } else { "FAILED" }
        $dnsStatus = if ($result.DNSOK) { "OK" } else { "FAILED" }

        $dcInfoLabelRef.Text = "DC: $($result.DCName)    IP: $($result.DCIP)`r`nPing: $pingStatus    LDAP: $ldapStatus    DNS: $dnsStatus"

        if ($result.DCName -ne "N/A") {
            $dcValueLabelRef.Text = $result.DCName
        }
    }.GetNewClosure())

    # Leave domain
    $leaveBtn.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "WARNING: This will remove the computer from the domain!`n`nThe computer will join a workgroup and require domain rejoin.`n`nA restart will be required.`n`nAre you sure?",
            "Leave Domain",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $result = & $leaveDomainRef -LogBox $logBoxRef
            if ($result.Success) {
                [System.Windows.Forms.MessageBox]::Show(
                    "$($result.Message)`n`nRestart now?",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                if ($restartCheckboxRef.Checked) {
                    $restartConfirm = [System.Windows.Forms.MessageBox]::Show(
                        "Restart the computer now?",
                        "Restart Required",
                        [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Question
                    )
                    if ($restartConfirm -eq [System.Windows.Forms.DialogResult]::Yes) {
                        Restart-Computer -Force
                    }
                }
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed: $($result.Message)",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        }
    }.GetNewClosure())

    # Rejoin domain
    $rejoinBtn.Add_Click({
        # Get current or default domain
        $status = & $getDomainStatusRef
        $defaultDomain = if ($status.Domain -and $status.Domain -ne "WORKGROUP") { $status.Domain } else { "rush.edu" }

        # Prompt for domain name
        $inputForm = New-Object System.Windows.Forms.Form
        $inputForm.Text = "Rejoin Domain"
        $inputForm.Size = New-Object System.Drawing.Size(350, 150)
        $inputForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $inputForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $inputForm.MaximizeBox = $false
        $inputForm.MinimizeBox = $false

        $domainInputLabel = New-Object System.Windows.Forms.Label
        $domainInputLabel.Text = "Domain name:"
        $domainInputLabel.Location = New-Object System.Drawing.Point(10, 20)
        $domainInputLabel.AutoSize = $true
        $inputForm.Controls.Add($domainInputLabel)

        $domainTextBox = New-Object System.Windows.Forms.TextBox
        $domainTextBox.Text = $defaultDomain
        $domainTextBox.Location = New-Object System.Drawing.Point(100, 17)
        $domainTextBox.Width = 220
        $inputForm.Controls.Add($domainTextBox)

        $okBtn = New-Object System.Windows.Forms.Button
        $okBtn.Text = "Join"
        $okBtn.Location = New-Object System.Drawing.Point(165, 70)
        $okBtn.Width = 75
        $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $inputForm.Controls.Add($okBtn)

        $cancelBtn = New-Object System.Windows.Forms.Button
        $cancelBtn.Text = "Cancel"
        $cancelBtn.Location = New-Object System.Drawing.Point(245, 70)
        $cancelBtn.Width = 75
        $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $inputForm.Controls.Add($cancelBtn)

        $inputForm.AcceptButton = $okBtn
        $inputForm.CancelButton = $cancelBtn

        if ($inputForm.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $domainName = $domainTextBox.Text.Trim()
            if ($domainName) {
                $result = & $joinDomainRef -DomainName $domainName -LogBox $logBoxRef
                if ($result.Success) {
                    [System.Windows.Forms.MessageBox]::Show(
                        $result.Message,
                        "Success",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    )
                    if ($restartCheckboxRef.Checked) {
                        $restartConfirm = [System.Windows.Forms.MessageBox]::Show(
                            "Restart the computer now?",
                            "Restart Required",
                            [System.Windows.Forms.MessageBoxButtons]::YesNo,
                            [System.Windows.Forms.MessageBoxIcon]::Question
                        )
                        if ($restartConfirm -eq [System.Windows.Forms.DialogResult]::Yes) {
                            Restart-Computer -Force
                        }
                    }
                } else {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Failed: $($result.Message)",
                        "Error",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    )
                }
            }
        }
        $inputForm.Dispose()
    }.GetNewClosure())

    # Copy log
    $copyLogBtn.Add_Click({
        if ($logBoxRef.Text) {
            [System.Windows.Forms.Clipboard]::SetText($logBoxRef.Text)
            [System.Windows.Forms.MessageBox]::Show("Copied to clipboard!", "Info", [System.Windows.Forms.MessageBoxButtons]::OK)
        }
    }.GetNewClosure())

    # Clear log
    $clearLogBtn.Add_Click({
        $logBoxRef.Clear()
    }.GetNewClosure())

    #endregion

    # Add to tab
    $tab.Controls.Add($mainPanel)

    # Initial status load
    $refreshStatusBtn.PerformClick()

    # Log module load
    $timestamp = Get-Date -Format "HH:mm:ss"
    $script:logBox.AppendText("[$timestamp] Domain Tools module loaded`r`n")
}

#endregion
