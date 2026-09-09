<#
.SYNOPSIS
    Network Escalation Module for Rush Resolve
.DESCRIPTION
    One-click collection of everything the Networking team needs to work a
    Field Services escalation, so the tech does not have to know which
    commands to run or which details will be asked for.

    Collects: device identity, physical link state, switch name / port /
    VLAN (LLDP), IP / DHCP / DNS configuration, wireless AP details
    including BSSID, reachability test results, domain and proxy state,
    the local ARP neighbor table, and the Field Services checklist of what
    was already verified before escalating.

    Also provides "Look Up Device by IP", which resolves an IP address to a
    MAC address, vendor hint and hostname - and tells the tech when the
    target is off-subnet, where the local ARP table cannot answer.
.NOTES
    Requires RushResolve.ps1 core helpers: Invoke-Elevated,
    Get-ElevatedCredential, Test-IsElevated, Write-SessionLog.

    LLDP collection needs local admin plus the Data Center Bridging feature.
    Use Network Tools -> Setup LLDP once per tech laptop to enable it.

    All logic lives in $script: script blocks. Modules are dot-sourced inside
    the loader function, so plain function definitions would fall out of
    scope as soon as the module finishes loading.
#>

$script:ModuleName = "Network Escalation"
$script:ModuleDescription = "Collect a complete escalation packet for the Networking team"

#region Constants

$script:NE_Rule       = "========================================================================="
$script:NE_SubRule    = "-------------------------------------------------------------------------"
$script:NE_PingTimeout = 1200
$script:NE_LastReport = ""
$script:NE_OuiCsv     = $null

# Best-effort vendor hints. Deliberately limited to assignments that are
# unambiguous - a wrong vendor is worse than no vendor. For real coverage,
# use "Import OUI File" to drop the IEEE MA-L export at Config\oui.csv;
# that file is preferred over this table whenever it is present.
$script:NE_OuiHints = @{
    '00:50:56' = 'VMware (virtual NIC)'
    '00:0C:29' = 'VMware (virtual NIC)'
    '00:05:69' = 'VMware (virtual NIC)'
    '00:1C:14' = 'VMware (virtual NIC)'
    '00:15:5D' = 'Microsoft Hyper-V (virtual NIC)'
    '00:03:FF' = 'Microsoft (virtual NIC)'
    '08:00:27' = 'Oracle VirtualBox (virtual NIC)'
    '52:54:00' = 'QEMU / KVM (virtual NIC)'
    '00:16:3E' = 'Xen (virtual NIC)'
    '00:1C:42' = 'Parallels (virtual NIC)'
    '00:00:0C' = 'Cisco Systems'
}

# Symptom picklist - phrased the way the Networking team triages.
$script:NE_Symptoms = @(
    'No link / no lights on the port',
    'Link is up but no IP (APIPA 169.254.x.x)',
    'Has an IP but cannot reach the gateway',
    'Reaches gateway but cannot reach internal servers',
    'Intermittent drops / flapping',
    'Slow throughput',
    'Cannot reach one specific server or application',
    'Wrong VLAN / wrong subnet for this location',
    'Wireless will not connect',
    'Wireless connects but drops or roams badly',
    'Other (see notes)'
)

$script:NE_ScopeOptions = @(
    'Single device',
    'Multiple devices, same room',
    'Multiple devices, same floor',
    'Multiple devices, whole building',
    'Unknown'
)

$script:NE_OnsetOptions = @(
    'Started just now / today',
    'Started yesterday',
    'Started this week',
    'Started after a move, add or change',
    'Has never worked (new drop or new device)',
    'Unknown'
)

$script:NE_LinkLightOptions = @(
    'Not checked',
    'No lights at all',
    'Solid green / amber, no activity blink',
    'Green with activity blink',
    'Amber only',
    'Port not accessible / cannot see it'
)

$script:NE_ChecklistItems = @(
    'Cable reseated at both ends',
    'Known-good cable tested',
    'Known-good wall jack tested',
    'NIC disabled and re-enabled',
    'Device rebooted',
    'Another device works on this jack',
    'This device works on another jack',
    'Dock / USB adapter bypassed',
    'Wireless works, wired does not'
)

#endregion

#region Helper Script Blocks

# Pad a label to a fixed column so the report lines up in a ticket window.
$script:NE_Line = {
    param([string]$Label, $Value, [int]$Width = 22)

    $text = if ($null -eq $Value -or "$Value".Trim() -eq '') { 'N/A' } else { "$Value".Trim() }

    # Error messages and some cmdlet output wrap across lines. Collapse them
    # so one field stays on one line and the report columns stay readable.
    $text = ($text -replace '\s*\r?\n\s*', ' ')

    return ("  {0} {1}" -f "$($Label):".PadRight($Width), $text)
}

# Ping using .NET so we control the timeout - Test-Connection has no usable
# timeout on Windows PowerShell 5.1 and hangs for seconds on a dead target.
$script:NE_Ping = {
    param([string]$Target, [int]$Count = 2, [int]$TimeoutMs = 1200)

    $result = [PSCustomObject]@{
        Target   = $Target
        Success  = $false
        Sent     = $Count
        Received = 0
        AvgMs    = $null
        Address  = $null
        Status   = 'Unknown'
    }

    if ([string]::IsNullOrWhiteSpace($Target) -or $Target -eq 'N/A') {
        $result.Sent = 0
        $result.Status = 'Not tested (no target available)'
        return $result
    }

    $times = @()
    $ping = $null
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        for ($i = 0; $i -lt $Count; $i++) {
            try {
                $reply = $ping.Send($Target, $TimeoutMs)
                if ($reply.Status -eq 'Success') {
                    $result.Received++
                    $times += $reply.RoundtripTime
                    if (-not $result.Address) { $result.Address = $reply.Address.ToString() }
                }
                elseif ($result.Status -eq 'Unknown') {
                    $result.Status = $reply.Status.ToString()
                }
            }
            catch {
                if ($result.Status -eq 'Unknown') { $result.Status = 'Send failed (name may not resolve)' }
            }
        }
    }
    catch {
        $result.Status = "Error: $($_.Exception.Message)"
        return $result
    }
    finally {
        if ($ping) { $ping.Dispose() }
    }

    if ($result.Received -gt 0) {
        $result.Success = $true
        $result.Status = 'Success'
        $result.AvgMs = [math]::Round((($times | Measure-Object -Average).Average), 0)
    }
    elseif ($result.Status -eq 'Unknown') {
        $result.Status = 'No reply'
    }

    return $result
}

# One-line summary of a ping result for the report.
$script:NE_PingText = {
    param($PingResult)

    if (-not $PingResult) { return 'Not tested' }
    if ($PingResult.Success) {
        return "PASS  ($($PingResult.Received)/$($PingResult.Sent) replies, avg $($PingResult.AvgMs) ms)"
    }
    if ($PingResult.Sent -eq 0) { return $PingResult.Status }
    return "FAIL  (0/$($PingResult.Sent) replies - $($PingResult.Status))"
}

# CIDR prefix length to dotted subnet mask.
$script:NE_PrefixToMask = {
    param([int]$PrefixLength)

    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) { return 'N/A' }
    $bits = ('1' * $PrefixLength).PadRight(32, '0')
    $octets = @()
    for ($i = 0; $i -lt 4; $i++) {
        $octets += [Convert]::ToInt32($bits.Substring($i * 8, 8), 2)
    }
    return ($octets -join '.')
}

# Are two IPv4 addresses inside the same prefix?
$script:NE_SameSubnet = {
    param([string]$IpA, [string]$IpB, [int]$PrefixLength)

    try {
        $a = ([System.Net.IPAddress]::Parse($IpA)).GetAddressBytes()
        $b = ([System.Net.IPAddress]::Parse($IpB)).GetAddressBytes()
        if ($a.Length -ne 4 -or $b.Length -ne 4) { return $false }

        $remaining = $PrefixLength
        for ($i = 0; $i -lt 4; $i++) {
            if ($remaining -le 0) { break }
            $take = [Math]::Min(8, $remaining)
            $mask = [byte](256 - [Math]::Pow(2, 8 - $take))
            if (($a[$i] -band $mask) -ne ($b[$i] -band $mask)) { return $false }
            $remaining -= $take
        }
        return $true
    }
    catch {
        return $false
    }
}

# Accepts 00-11-22-33-44-55, 001122334455, 0011.2233.4455 -> 00:11:22:33:44:55
$script:NE_NormalizeMac = {
    param([string]$Mac)

    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    $clean = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($clean.Length -ne 12) { return $null }
    return (($clean -split '(.{2})' | Where-Object { $_ }) -join ':')
}

# Load the optional IEEE MA-L export once per session.
$script:NE_LoadOuiCsv = {
    $script:NE_OuiCsv = @{}
    try {
        $path = Join-Path $script:ConfigPath 'oui.csv'
        if (-not (Test-Path $path)) { return }

        foreach ($row in (Import-Csv -Path $path -ErrorAction Stop)) {
            $assignment = $row.Assignment
            $org = $row.'Organization Name'
            if (-not $assignment -or -not $org) { continue }

            $key = ($assignment -replace '[^0-9A-Fa-f]', '').ToUpper()
            if ($key.Length -ge 6) {
                $prefix = $key.Substring(0, 6)
                if (-not $script:NE_OuiCsv.ContainsKey($prefix)) {
                    $script:NE_OuiCsv[$prefix] = $org.Trim()
                }
            }
        }
    }
    catch {
        $script:NE_OuiCsv = @{}
    }
}

# Vendor hint from the OUI, plus the two facts we can state with certainty:
# multicast addresses and locally administered (randomized) MACs.
$script:NE_LookupVendor = {
    param([string]$Mac)

    $norm = & $script:NE_NormalizeMac -Mac $Mac
    if (-not $norm) { return 'N/A' }

    $hex = $norm -replace ':', ''
    $firstOctet = [Convert]::ToInt32($hex.Substring(0, 2), 16)

    if (($firstOctet -band 1) -eq 1) {
        return 'Multicast / broadcast address - not a single device NIC'
    }

    if ($null -eq $script:NE_OuiCsv) { & $script:NE_LoadOuiCsv }

    $prefix = $hex.Substring(0, 6)
    if ($script:NE_OuiCsv -and $script:NE_OuiCsv.ContainsKey($prefix)) {
        return $script:NE_OuiCsv[$prefix]
    }

    $formatted = "{0}:{1}:{2}" -f $hex.Substring(0, 2), $hex.Substring(2, 2), $hex.Substring(4, 2)
    if ($script:NE_OuiHints.ContainsKey($formatted)) {
        return $script:NE_OuiHints[$formatted]
    }

    if (($firstOctet -band 2) -eq 2) {
        return 'Locally administered / randomized MAC - no registered vendor'
    }

    return 'Unknown OUI (use Import OUI File for full vendor lookup)'
}

# Resolve an IP to a MAC via the neighbor cache, falling back to arp.exe.
$script:NE_GetMacForIp = {
    param([string]$IpAddress)

    $out = [PSCustomObject]@{
        IPAddress      = $IpAddress
        Mac            = $null
        State          = 'N/A'
        Source         = 'None'
        InterfaceAlias = 'N/A'
    }

    try {
        $neighbor = Get-NetNeighbor -IPAddress $IpAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LinkLayerAddress -and
                $_.LinkLayerAddress -notmatch '^(00-){5}00$' -and
                $_.State -ne 'Unreachable'
            } |
            Sort-Object -Property @{ Expression = {
                switch ($_.State) {
                    'Reachable' { 0 }
                    'Permanent' { 1 }
                    'Stale'     { 2 }
                    'Delay'     { 3 }
                    'Probe'     { 4 }
                    default     { 5 }
                }
            } } |
            Select-Object -First 1

        if ($neighbor) {
            $out.Mac = & $script:NE_NormalizeMac -Mac $neighbor.LinkLayerAddress
            $out.State = [string]$neighbor.State
            $out.Source = 'Get-NetNeighbor'
            $adapter = Get-NetAdapter -InterfaceIndex $neighbor.InterfaceIndex -ErrorAction SilentlyContinue
            if ($adapter) { $out.InterfaceAlias = $adapter.Name }
        }
    }
    catch { }

    if (-not $out.Mac) {
        try {
            $arp = arp -a $IpAddress 2>&1
            foreach ($line in $arp) {
                if ("$line" -match '(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5})\s+(\w+)') {
                    if ($matches[1] -eq $IpAddress) {
                        $out.Mac = & $script:NE_NormalizeMac -Mac $matches[2]
                        $out.State = $matches[3]
                        $out.Source = 'arp.exe'
                        break
                    }
                }
            }
        }
        catch { }
    }

    return $out
}

# Reverse DNS, best effort.
$script:NE_ReverseDns = {
    param([string]$IpAddress)

    try {
        $entry = [System.Net.Dns]::GetHostEntry($IpAddress)
        if ($entry -and $entry.HostName) { return $entry.HostName }
    }
    catch { }
    return $null
}

# netsh wlan output is key: value pairs - turn the connected interface into
# a hashtable so we can pull BSSID, channel, signal and auth.
$script:NE_GetWirelessDetail = {
    $info = @{
        Present = $false
        Fields  = @{}
        Raw     = ''
    }

    try {
        $raw = (netsh wlan show interfaces 2>&1 | Out-String)
        $info.Raw = $raw

        if ($raw -match 'There is no wireless interface' -or $raw -match 'is not running') {
            return $info
        }

        foreach ($line in ($raw -split "`r?`n")) {
            if ($line -match '^\s{2,}([A-Za-z][A-Za-z0-9 \.\-/()]+?)\s*:\s*(.+?)\s*$') {
                $key = $matches[1].Trim()
                if (-not $info.Fields.ContainsKey($key)) {
                    $info.Fields[$key] = $matches[2].Trim()
                }
            }
        }

        if ($info.Fields.Count -gt 0) { $info.Present = $true }
    }
    catch { }

    return $info
}

# LLDP neighbor for one adapter. Self-contained on purpose: this module must
# not depend on Network Tools having loaded first.
$script:NE_GetLldp = {
    param([string]$AdapterName, [PSCredential]$Credential)

    $info = @{
        Available   = $false
        SwitchName  = 'N/A'
        SwitchIP    = 'N/A'
        Port        = 'N/A'
        PortDesc    = 'N/A'
        SystemName  = 'N/A'
        SystemDesc  = 'N/A'
        VLAN        = 'N/A'
        Error       = $null
    }

    $query = {
        param($AdapterName)

        $r = @{
            Available   = $false
            SwitchName  = 'N/A'
            SwitchIP    = 'N/A'
            Port        = 'N/A'
            PortDesc    = 'N/A'
            SystemName  = 'N/A'
            SystemDesc  = 'N/A'
            VLAN        = 'N/A'
            Error       = $null
        }

        try {
            $neighbor = Get-NetLldpAgent -NetAdapterName $AdapterName -ErrorAction Stop |
                Get-NetLldpNeighborInformation -ErrorAction Stop |
                Select-Object -First 1

            if ($neighbor) {
                $r.Available  = $true
                $r.SwitchName = if ($neighbor.ChassisId) { "$($neighbor.ChassisId)" } else { 'N/A' }
                $r.SwitchIP   = if ($neighbor.ManagementAddress) { "$($neighbor.ManagementAddress)" } else { 'N/A' }
                $r.Port       = if ($neighbor.PortId) { "$($neighbor.PortId)" } else { 'N/A' }
                $r.PortDesc   = if ($neighbor.PortDescription) { "$($neighbor.PortDescription)" } else { 'N/A' }
                $r.SystemName = if ($neighbor.SystemName) { "$($neighbor.SystemName)" } else { 'N/A' }
                $r.SystemDesc = if ($neighbor.SystemDescription) { "$($neighbor.SystemDescription)" } else { 'N/A' }

                foreach ($candidate in @($r.PortDesc, $r.SystemDesc)) {
                    if ($candidate -match 'VLAN[:\s#]*(\d{1,4})') {
                        $r.VLAN = $matches[1]
                        break
                    }
                }
            }
            else {
                $r.Error = 'No LLDP data received yet. Leave the cable connected for 30-60 seconds and retry.'
            }
        }
        catch {
            # Work out which of the two setup steps is missing. This probe can
            # itself fail (Server Core, constrained language, older builds), so
            # it gets its own guard - the tech still needs a usable next step.
            $dcbState = $null
            try {
                $dcb = Get-WindowsOptionalFeature -Online -FeatureName 'DataCenterBridging' -ErrorAction Stop
                if ($dcb) { $dcbState = "$($dcb.State)" }
            }
            catch {
                $dcbState = $null
            }

            if ($null -eq $dcbState) {
                $r.Error = 'Could not read LLDP data or confirm the Data Center Bridging feature. Run Network Tools -> Setup LLDP once on this laptop.'
            }
            elseif ($dcbState -ne 'Enabled') {
                $r.Error = 'LLDP not configured on this laptop. Run Network Tools -> Setup LLDP once.'
            }
            else {
                $r.Error = "LLDP agent not enabled on '$AdapterName'. Run Network Tools -> Setup LLDP."
            }
        }

        $r
    }

    try {
        # Already elevated - no need to prompt for anything.
        if ((Get-Command -Name Test-IsElevated -ErrorAction SilentlyContinue) -and (Test-IsElevated)) {
            return [PSCustomObject](& $query -AdapterName $AdapterName)
        }

        if (-not $Credential) {
            $info.Error = 'Skipped - admin credentials not supplied.'
            return [PSCustomObject]$info
        }

        $result = Invoke-Elevated -ScriptBlock $query -ArgumentList $AdapterName `
            -Credential $Credential -OperationName 'query LLDP switch info'

        if ($result.Success -and $result.Output) {
            return [PSCustomObject]$result.Output
        }

        $info.Error = if ($result.Error) { "$($result.Error)" } else { 'Failed to query LLDP data.' }
        return [PSCustomObject]$info
    }
    catch {
        $info.Error = "LLDP query error: $($_.Exception.Message)"
        return [PSCustomObject]$info
    }
}

#endregion

#region Collection

<#
    Builds the full escalation packet.

    Context is a hashtable of everything the tech typed or ticked in the UI.
    Progress is a script block called with a status string so the caller can
    keep the UI responsive without this block knowing about WinForms.
#>
$script:NE_BuildPacket = {
    param(
        [hashtable]$Context,
        [scriptblock]$Progress
    )

    $report = [System.Text.StringBuilder]::new()
    $note = {
        param($Message)
        if ($Progress) { & $Progress $Message }
    }

    $w = 22
    $rule = $script:NE_Rule
    $sub = $script:NE_SubRule

    #-- Header ------------------------------------------------------------
    & $note 'Starting collection...'

    [void]$report.AppendLine($rule)
    [void]$report.AppendLine("  NETWORK ESCALATION PACKET")
    [void]$report.AppendLine($rule)
    [void]$report.AppendLine((& $script:NE_Line 'Generated' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $w))
    [void]$report.AppendLine((& $script:NE_Line 'Collected by' "$env:USERDOMAIN\$env:USERNAME" $w))
    [void]$report.AppendLine((& $script:NE_Line 'Collected from' $env:COMPUTERNAME $w))
    [void]$report.AppendLine((& $script:NE_Line 'Tool' "Rush Resolve $($script:AppVersion) - Network Escalation" $w))
    [void]$report.AppendLine('')

    #-- 1. Ticket and location -------------------------------------------
    [void]$report.AppendLine("  1. TICKET AND LOCATION")
    [void]$report.AppendLine($sub)
    [void]$report.AppendLine((& $script:NE_Line 'Ticket number' $Context.Ticket $w))
    [void]$report.AppendLine((& $script:NE_Line 'Site / building' $Context.Site $w))
    [void]$report.AppendLine((& $script:NE_Line 'Floor / room' $Context.Room $w))
    [void]$report.AppendLine((& $script:NE_Line 'Wall jack / faceplate' $Context.Jack $w))
    [void]$report.AppendLine((& $script:NE_Line 'Device / asset tag' $Context.Asset $w))
    [void]$report.AppendLine((& $script:NE_Line 'Reported by' $Context.ReportedBy $w))
    [void]$report.AppendLine('')

    #-- 2. Symptom --------------------------------------------------------
    [void]$report.AppendLine("  2. SYMPTOM")
    [void]$report.AppendLine($sub)
    [void]$report.AppendLine((& $script:NE_Line 'Symptom' $Context.Symptom $w))
    [void]$report.AppendLine((& $script:NE_Line 'How many affected' $Context.Scope $w))
    [void]$report.AppendLine((& $script:NE_Line 'When it started' $Context.Onset $w))
    [void]$report.AppendLine((& $script:NE_Line 'Switch port light' $Context.LinkLight $w))
    [void]$report.AppendLine('')
    if ($Context.Notes -and "$($Context.Notes)".Trim()) {
        [void]$report.AppendLine("  Tech notes:")
        foreach ($line in ("$($Context.Notes)" -split "`r?`n")) {
            [void]$report.AppendLine("    $line")
        }
        [void]$report.AppendLine('')
    }

    #-- 3. Already verified by Field Services -----------------------------
    [void]$report.AppendLine("  3. ALREADY VERIFIED BY FIELD SERVICES")
    [void]$report.AppendLine($sub)
    $checked = @($Context.Checked)
    foreach ($item in $script:NE_ChecklistItems) {
        $mark = if ($checked -contains $item) { '[x]' } else { '[ ]' }
        [void]$report.AppendLine("  $mark $item")
    }
    [void]$report.AppendLine('')

    #-- 4. Device identity ------------------------------------------------
    & $note 'Collecting device identity...'
    [void]$report.AppendLine("  4. DEVICE IDENTITY")
    [void]$report.AppendLine($sub)

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue

    $fqdn = $env:COMPUTERNAME
    try {
        $hostEntry = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)
        if ($hostEntry -and $hostEntry.HostName) { $fqdn = $hostEntry.HostName }
    }
    catch { }

    [void]$report.AppendLine((& $script:NE_Line 'Hostname' $env:COMPUTERNAME $w))
    [void]$report.AppendLine((& $script:NE_Line 'FQDN' $fqdn $w))
    if ($cs) {
        [void]$report.AppendLine((& $script:NE_Line 'Manufacturer' $cs.Manufacturer $w))
        [void]$report.AppendLine((& $script:NE_Line 'Model' $cs.Model $w))
    }
    if ($bios) {
        [void]$report.AppendLine((& $script:NE_Line 'Serial number' $bios.SerialNumber $w))
    }
    if ($os) {
        [void]$report.AppendLine((& $script:NE_Line 'Operating system' "$($os.Caption) (build $($os.BuildNumber))" $w))
        try {
            $uptime = (Get-Date) - $os.LastBootUpTime
            [void]$report.AppendLine((& $script:NE_Line 'Last boot' ("{0} ({1}d {2}h {3}m ago)" -f $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'), $uptime.Days, $uptime.Hours, $uptime.Minutes) $w))
        }
        catch { }
    }
    [void]$report.AppendLine((& $script:NE_Line 'Logged-on user' "$env:USERDOMAIN\$env:USERNAME" $w))
    [void]$report.AppendLine('')

    #-- 5. Adapters, link state and IP configuration ----------------------
    & $note 'Collecting adapters and IP configuration...'
    [void]$report.AppendLine("  5. NETWORK ADAPTERS - LINK AND IP")
    [void]$report.AppendLine($sub)

    $defaultRoutes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric)
    $primaryIfIndex = if ($defaultRoutes.Count -gt 0) { $defaultRoutes[0].ifIndex } else { $null }

    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Disconnected' } |
        Sort-Object -Property @{ Expression = { if ($_.ifIndex -eq $primaryIfIndex) { 0 } else { 1 } } }, Name)

    if ($adapters.Count -eq 0) {
        [void]$report.AppendLine('  No connected or connectable adapters found.')
        [void]$report.AppendLine('')
    }

    $primaryAdapter = $null
    $primaryIp = $null
    $primaryPrefix = 24
    $primaryGateway = $null

    foreach ($adapter in $adapters) {
        $isPrimary = ($adapter.ifIndex -eq $primaryIfIndex)
        $marker = if ($isPrimary) { '  [PRIMARY - carries the default route]' } else { '' }

        [void]$report.AppendLine("  Adapter: $($adapter.Name)$marker")
        [void]$report.AppendLine((& $script:NE_Line 'Description' $adapter.InterfaceDescription $w))
        [void]$report.AppendLine((& $script:NE_Line 'Status' $adapter.Status $w))
        [void]$report.AppendLine((& $script:NE_Line 'MAC address' (& $script:NE_NormalizeMac -Mac $adapter.MacAddress) $w))
        [void]$report.AppendLine((& $script:NE_Line 'Link speed' $adapter.LinkSpeed $w))
        [void]$report.AppendLine((& $script:NE_Line 'Media type' $adapter.MediaType $w))
        [void]$report.AppendLine((& $script:NE_Line 'Media state' $adapter.MediaConnectionState $w))
        [void]$report.AppendLine((& $script:NE_Line 'Full duplex' $adapter.FullDuplex $w))
        [void]$report.AppendLine((& $script:NE_Line 'Interface index' $adapter.ifIndex $w))
        [void]$report.AppendLine((& $script:NE_Line 'Driver' "$($adapter.DriverVersion) ($($adapter.DriverDate))" $w))

        # Speed/duplex is a classic mismatch cause - report the configured value.
        try {
            $sd = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'Speed.*Duplex' } | Select-Object -First 1
            if ($sd) {
                [void]$report.AppendLine((& $script:NE_Line 'Speed/duplex setting' $sd.DisplayValue $w))
            }
            $vlanProp = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match '^VLAN' } | Select-Object -First 1
            if ($vlanProp) {
                [void]$report.AppendLine((& $script:NE_Line 'NIC VLAN tag' $vlanProp.DisplayValue $w))
            }
        }
        catch { }

        $ipConfigs = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        if ($ipConfigs.Count -eq 0) {
            [void]$report.AppendLine((& $script:NE_Line 'IPv4 address' 'NONE - adapter has no IPv4 address' $w))
        }

        foreach ($ipConfig in $ipConfigs) {
            $mask = & $script:NE_PrefixToMask -PrefixLength $ipConfig.PrefixLength
            [void]$report.AppendLine((& $script:NE_Line 'IPv4 address' "$($ipConfig.IPAddress)/$($ipConfig.PrefixLength)  (mask $mask)" $w))
            [void]$report.AppendLine((& $script:NE_Line 'Address origin' "$($ipConfig.PrefixOrigin) / $($ipConfig.SuffixOrigin)" $w))
            [void]$report.AppendLine((& $script:NE_Line 'Address state' $ipConfig.AddressState $w))

            if ($ipConfig.IPAddress -like '169.254.*') {
                [void]$report.AppendLine('  >> FLAG: APIPA address. The device did not get a DHCP lease.')
                [void]$report.AppendLine('           Link is up at layer 1 but DHCP did not answer on this VLAN.')
            }
            if ($ipConfig.AddressState -eq 'Duplicate') {
                [void]$report.AppendLine('  >> FLAG: Duplicate address detected on this subnet.')
            }

            if ($isPrimary -and -not $primaryIp) {
                $primaryIp = $ipConfig.IPAddress
                $primaryPrefix = $ipConfig.PrefixLength
            }
        }

        $gw = ($defaultRoutes | Where-Object { $_.ifIndex -eq $adapter.ifIndex } | Select-Object -First 1).NextHop
        [void]$report.AppendLine((& $script:NE_Line 'Default gateway' $gw $w))

        $dns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        [void]$report.AppendLine((& $script:NE_Line 'DNS servers' ($dns -join ', ') $w))

        try {
            $dnsClient = Get-DnsClient -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
            if ($dnsClient) {
                [void]$report.AppendLine((& $script:NE_Line 'DNS suffix' $dnsClient.ConnectionSpecificSuffix $w))
            }
        }
        catch { }

        # DHCP lease details come from the legacy WMI class - Get-NetIPInterface
        # tells us DHCP is on but not who answered or when the lease expires.
        try {
            $nicCfg = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex } | Select-Object -First 1
            if ($nicCfg) {
                [void]$report.AppendLine((& $script:NE_Line 'DHCP enabled' $nicCfg.DHCPEnabled $w))
                if ($nicCfg.DHCPEnabled) {
                    [void]$report.AppendLine((& $script:NE_Line 'DHCP server' $nicCfg.DHCPServer $w))
                    if ($nicCfg.DHCPLeaseObtained) {
                        [void]$report.AppendLine((& $script:NE_Line 'Lease obtained' $nicCfg.DHCPLeaseObtained.ToString('yyyy-MM-dd HH:mm:ss') $w))
                    }
                    if ($nicCfg.DHCPLeaseExpires) {
                        [void]$report.AppendLine((& $script:NE_Line 'Lease expires' $nicCfg.DHCPLeaseExpires.ToString('yyyy-MM-dd HH:mm:ss') $w))
                    }
                }
            }
        }
        catch { }

        if ($isPrimary) {
            $primaryAdapter = $adapter
            $primaryGateway = $gw
        }

        [void]$report.AppendLine('')
    }

    #-- 6. Switch and port (LLDP) -----------------------------------------
    [void]$report.AppendLine("  6. SWITCH AND PORT (LLDP)")
    [void]$report.AppendLine($sub)

    if (-not $Context.IncludeLldp) {
        [void]$report.AppendLine('  Skipped - "Include switch/port info" was not selected.')
    }
    elseif (-not $primaryAdapter) {
        [void]$report.AppendLine('  Skipped - no primary adapter to query.')
    }
    elseif ($primaryAdapter.MediaType -match '802.11' -or $primaryAdapter.InterfaceDescription -match 'Wireless|Wi-Fi|WLAN') {
        [void]$report.AppendLine('  Skipped - primary adapter is wireless. See section 7 for AP details.')
    }
    else {
        & $note 'Querying LLDP for switch and port...'
        $lldp = & $script:NE_GetLldp -AdapterName $primaryAdapter.Name -Credential $Context.Credential

        [void]$report.AppendLine((& $script:NE_Line 'Queried adapter' $primaryAdapter.Name $w))
        if ($lldp.Available) {
            [void]$report.AppendLine((& $script:NE_Line 'Switch chassis ID' $lldp.SwitchName $w))
            [void]$report.AppendLine((& $script:NE_Line 'Switch name' $lldp.SystemName $w))
            [void]$report.AppendLine((& $script:NE_Line 'Switch mgmt IP' $lldp.SwitchIP $w))
            [void]$report.AppendLine((& $script:NE_Line 'Switch port ID' $lldp.Port $w))
            [void]$report.AppendLine((& $script:NE_Line 'Port description' $lldp.PortDesc $w))
            [void]$report.AppendLine((& $script:NE_Line 'VLAN (from LLDP)' $lldp.VLAN $w))
            [void]$report.AppendLine((& $script:NE_Line 'Switch description' $lldp.SystemDesc $w))
        }
        else {
            [void]$report.AppendLine((& $script:NE_Line 'LLDP result' 'Not available' $w))
            [void]$report.AppendLine((& $script:NE_Line 'Reason' $lldp.Error $w))
            [void]$report.AppendLine('  Networking: please identify the switch and port from the MAC address')
            [void]$report.AppendLine('  in section 5 and the wall jack ID in section 1.')
        }
    }
    [void]$report.AppendLine('')

    #-- 7. Wireless -------------------------------------------------------
    & $note 'Collecting wireless details...'
    [void]$report.AppendLine("  7. WIRELESS")
    [void]$report.AppendLine($sub)

    $wireless = & $script:NE_GetWirelessDetail
    if (-not $wireless.Present) {
        [void]$report.AppendLine('  No wireless interface present or the WLAN service is not running.')
    }
    else {
        $f = $wireless.Fields
        $wirelessKeys = @(
            @('Name',                'Interface'),
            @('Description',         'Adapter'),
            @('State',               'State'),
            @('SSID',                'SSID'),
            @('BSSID',               'BSSID (AP radio MAC)'),
            @('Network type',        'Network type'),
            @('Radio type',          'Radio type'),
            @('Band',                'Band'),
            @('Channel',             'Channel'),
            @('Authentication',      'Authentication'),
            @('Cipher',              'Cipher'),
            @('Connection mode',     'Connection mode'),
            @('Receive rate (Mbps)', 'Receive rate Mbps'),
            @('Transmit rate (Mbps)','Transmit rate Mbps'),
            @('Signal',              'Signal'),
            @('Profile',             'Profile')
        )

        foreach ($pair in $wirelessKeys) {
            if ($f.ContainsKey($pair[0])) {
                [void]$report.AppendLine((& $script:NE_Line $pair[1] $f[$pair[0]] $w))
            }
        }

        if ($f.ContainsKey('BSSID')) {
            $apVendor = & $script:NE_LookupVendor -Mac $f['BSSID']
            [void]$report.AppendLine((& $script:NE_Line 'AP vendor (OUI hint)' $apVendor $w))
        }

        if ($f.ContainsKey('Signal')) {
            $signalValue = 0
            if ([int]::TryParse(($f['Signal'] -replace '[^0-9]', ''), [ref]$signalValue)) {
                if ($signalValue -lt 40) {
                    [void]$report.AppendLine('  >> FLAG: Signal below 40 percent. Likely a coverage problem, not a config problem.')
                }
            }
        }
    }
    [void]$report.AppendLine('')

    #-- 8. Reachability ---------------------------------------------------
    & $note 'Running reachability tests...'
    [void]$report.AppendLine("  8. REACHABILITY TESTS")
    [void]$report.AppendLine($sub)
    [void]$report.AppendLine('  Each test is 2 echo requests with a 1.2 second timeout.')
    [void]$report.AppendLine('')

    $loopback = & $script:NE_Ping -Target '127.0.0.1'
    [void]$report.AppendLine((& $script:NE_Line 'Loopback 127.0.0.1' (& $script:NE_PingText $loopback) 26))

    if ($primaryIp) {
        $selfPing = & $script:NE_Ping -Target $primaryIp
        [void]$report.AppendLine((& $script:NE_Line "Own IP $primaryIp" (& $script:NE_PingText $selfPing) 26))
    }

    $gatewayPing = $null
    if ($primaryGateway) {
        & $note "Pinging gateway $primaryGateway..."
        $gatewayPing = & $script:NE_Ping -Target $primaryGateway
        [void]$report.AppendLine((& $script:NE_Line "Gateway $primaryGateway" (& $script:NE_PingText $gatewayPing) 26))
    }
    else {
        [void]$report.AppendLine((& $script:NE_Line 'Gateway' 'N/A - no default gateway is configured' 26))
    }

    $dnsServers = @()
    if ($primaryAdapter) {
        $dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $primaryAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    }
    foreach ($dnsServer in ($dnsServers | Select-Object -First 3)) {
        & $note "Pinging DNS server $dnsServer..."
        $dnsPing = & $script:NE_Ping -Target $dnsServer
        [void]$report.AppendLine((& $script:NE_Line "DNS server $dnsServer" (& $script:NE_PingText $dnsPing) 26))
    }

    # Name resolution is a separate failure mode from reachability.
    & $note 'Testing DNS resolution...'
    $resolveTarget = if ($Context.TestTarget) { "$($Context.TestTarget)".Trim() } else { '' }
    $domainName = if ($cs -and $cs.PartOfDomain) { $cs.Domain } else { $null }
    if ($domainName) {
        try {
            $resolved = [System.Net.Dns]::GetHostEntry($domainName)
            $addresses = ($resolved.AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) -join ', '
            [void]$report.AppendLine((& $script:NE_Line "Resolve $domainName" "PASS  ($addresses)" 26))
        }
        catch {
            [void]$report.AppendLine((& $script:NE_Line "Resolve $domainName" 'FAIL  (DNS did not resolve the domain)' 26))
        }
    }

    if ($resolveTarget) {
        & $note "Testing target $resolveTarget..."
        $targetIsIp = $resolveTarget -match '^\d{1,3}(\.\d{1,3}){3}$'
        if (-not $targetIsIp) {
            try {
                $resolvedTarget = [System.Net.Dns]::GetHostEntry($resolveTarget)
                $targetAddresses = ($resolvedTarget.AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) -join ', '
                [void]$report.AppendLine((& $script:NE_Line "Resolve $resolveTarget" "PASS  ($targetAddresses)" 26))
            }
            catch {
                [void]$report.AppendLine((& $script:NE_Line "Resolve $resolveTarget" 'FAIL  (name did not resolve)' 26))
            }
        }
        $targetPing = & $script:NE_Ping -Target $resolveTarget
        [void]$report.AppendLine((& $script:NE_Line "Ping $resolveTarget" (& $script:NE_PingText $targetPing) 26))
    }
    else {
        [void]$report.AppendLine((& $script:NE_Line 'Affected target' 'Not supplied by the tech' 26))
    }
    [void]$report.AppendLine('')

    # A gateway that answers but nothing beyond it is the single most useful
    # signal we can hand the Networking team, so call it out explicitly.
    if ($gatewayPing -and -not $gatewayPing.Success) {
        [void]$report.AppendLine('  >> FLAG: Default gateway does not answer. Traffic is not leaving the')
        [void]$report.AppendLine('           access port, or the port is in the wrong VLAN.')
        [void]$report.AppendLine('')
    }
    elseif ($gatewayPing -and $gatewayPing.Success -and $resolveTarget) {
        $targetFailed = $targetPing -and -not $targetPing.Success
        if ($targetFailed) {
            [void]$report.AppendLine('  >> FLAG: Gateway answers but the affected target does not. Points to')
            [void]$report.AppendLine('           routing, an ACL, or a firewall rule rather than the access port.')
            [void]$report.AppendLine('')
        }
    }

    #-- 9. Traceroute -----------------------------------------------------
    # Always emit the header so the section numbers the Networking team
    # refers to on the ticket stay stable whether or not this ran.
    [void]$report.AppendLine("  9. TRACEROUTE")
    [void]$report.AppendLine($sub)
    if (-not $Context.IncludeTrace) {
        [void]$report.AppendLine('  Skipped - "Traceroute to target" was not selected.')
    }
    elseif (-not $resolveTarget) {
        [void]$report.AppendLine('  Skipped - no affected target was supplied.')
    }
    else {
        & $note "Tracing route to $resolveTarget (up to 15 hops)..."
        [void]$report.AppendLine("  Target: $resolveTarget (max 15 hops, no DNS lookup)")
        [void]$report.AppendLine('')
        try {
            $traceOutput = tracert.exe -d -h 15 -w 800 $resolveTarget 2>&1
            foreach ($line in $traceOutput) {
                if ("$line".Trim()) { [void]$report.AppendLine("  $line") }
            }
        }
        catch {
            [void]$report.AppendLine("  Traceroute failed: $($_.Exception.Message)")
        }
    }
    [void]$report.AppendLine('')

    #-- 10. Domain and authentication -------------------------------------
    & $note 'Collecting domain state...'
    [void]$report.AppendLine("  10. DOMAIN AND AUTHENTICATION")
    [void]$report.AppendLine($sub)

    if ($cs -and $cs.PartOfDomain) {
        [void]$report.AppendLine((& $script:NE_Line 'Domain' $cs.Domain $w))
        try {
            $trust = Test-ComputerSecureChannel -ErrorAction Stop
            [void]$report.AppendLine((& $script:NE_Line 'Secure channel' $(if ($trust) { 'HEALTHY' } else { 'BROKEN - rejoin required' }) $w))
        }
        catch {
            [void]$report.AppendLine((& $script:NE_Line 'Secure channel' "Could not verify: $($_.Exception.Message)" $w))
        }
        [void]$report.AppendLine((& $script:NE_Line 'Logon server' $env:LOGONSERVER $w))
        try {
            $siteOutput = (nltest /dsgetsite 2>&1 | Select-Object -First 1)
            [void]$report.AppendLine((& $script:NE_Line 'AD site' $siteOutput $w))
        }
        catch { }
    }
    elseif ($cs) {
        [void]$report.AppendLine((& $script:NE_Line 'Workgroup' $cs.Workgroup $w))
        [void]$report.AppendLine('  Device is not domain joined.')
    }
    [void]$report.AppendLine('')

    #-- 11. Proxy and VPN -------------------------------------------------
    [void]$report.AppendLine("  11. PROXY AND VPN")
    [void]$report.AppendLine($sub)
    try {
        $winhttp = (netsh winhttp show proxy 2>&1 | Out-String).Trim()
        foreach ($line in ($winhttp -split "`r?`n")) {
            if ("$line".Trim()) { [void]$report.AppendLine("  $line") }
        }
    }
    catch { }
    try {
        $ieSettings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($ieSettings) {
            [void]$report.AppendLine((& $script:NE_Line 'User proxy enabled' $ieSettings.ProxyEnable $w))
            if ($ieSettings.ProxyServer) {
                [void]$report.AppendLine((& $script:NE_Line 'User proxy server' $ieSettings.ProxyServer $w))
            }
            if ($ieSettings.AutoConfigURL) {
                [void]$report.AppendLine((& $script:NE_Line 'PAC file URL' $ieSettings.AutoConfigURL $w))
            }
        }
    }
    catch { }

    $vpnAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'VPN|AnyConnect|GlobalProtect|Pulse|Juniper|WireGuard|OpenVPN|TAP-' })
    if ($vpnAdapters.Count -gt 0) {
        [void]$report.AppendLine('')
        [void]$report.AppendLine('  VPN-style adapters present:')
        foreach ($vpnAdapter in $vpnAdapters) {
            [void]$report.AppendLine("    $($vpnAdapter.Name) - $($vpnAdapter.InterfaceDescription) [$($vpnAdapter.Status)]")
        }
    }
    [void]$report.AppendLine('')

    #-- 12. ARP neighbors -------------------------------------------------
    & $note 'Reading ARP neighbor table...'
    [void]$report.AppendLine("  12. ARP NEIGHBOR TABLE (LOCAL SUBNET)")
    [void]$report.AppendLine($sub)
    [void]$report.AppendLine('  Devices this machine has recently talked to at layer 2. Useful for')
    [void]$report.AppendLine('  confirming the device is on the VLAN the Networking team expects.')
    [void]$report.AppendLine('')
    [void]$report.AppendLine('  IP Address        MAC Address         State      Interface')
    [void]$report.AppendLine('  ----------------  ------------------  ---------  ------------------')

    try {
        $neighbors = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.State -in @('Reachable', 'Stale', 'Permanent', 'Delay', 'Probe') -and
                $_.LinkLayerAddress -and
                $_.IPAddress -notlike '224.*' -and
                $_.IPAddress -notlike '239.*' -and
                $_.IPAddress -ne '255.255.255.255'
            } |
            Sort-Object -Property @{ Expression = { [System.Version](($_.IPAddress -split '\.') -join '.') } } |
            Select-Object -First 40)

        if ($neighbors.Count -eq 0) {
            [void]$report.AppendLine('  (empty)')
        }
        foreach ($neighbor in $neighbors) {
            $mac = & $script:NE_NormalizeMac -Mac $neighbor.LinkLayerAddress
            $alias = (Get-NetAdapter -InterfaceIndex $neighbor.InterfaceIndex -ErrorAction SilentlyContinue).Name
            [void]$report.AppendLine(("  {0}  {1}  {2}  {3}" -f `
                "$($neighbor.IPAddress)".PadRight(16),
                "$mac".PadRight(18),
                "$($neighbor.State)".PadRight(9),
                "$alias"))
        }
    }
    catch {
        [void]$report.AppendLine("  Could not read neighbor table: $($_.Exception.Message)")
    }
    [void]$report.AppendLine('')

    #-- 13. Appendix ------------------------------------------------------
    if ($Context.IncludeRaw) {
        & $note 'Appending raw ipconfig and routing table...'
        [void]$report.AppendLine("  13. APPENDIX - RAW OUTPUT")
        [void]$report.AppendLine($sub)
        [void]$report.AppendLine('')
        [void]$report.AppendLine('  --- ipconfig /all ---')
        try {
            foreach ($line in (ipconfig /all 2>&1)) {
                [void]$report.AppendLine("  $line")
            }
        }
        catch { }
        [void]$report.AppendLine('')
        [void]$report.AppendLine('  --- route print -4 ---')
        try {
            foreach ($line in (route print -4 2>&1)) {
                [void]$report.AppendLine("  $line")
            }
        }
        catch { }
        [void]$report.AppendLine('')
    }

    #-- Handoff -----------------------------------------------------------
    [void]$report.AppendLine($rule)
    [void]$report.AppendLine('  HANDOFF')
    [void]$report.AppendLine($rule)
    [void]$report.AppendLine('  Field Services has completed initial triage. Per the line of')
    [void]$report.AppendLine('  demarcation, switch configuration, VLAN assignment, DHCP scope and')
    [void]$report.AppendLine('  infrastructure routing are owned by Networking.')
    [void]$report.AppendLine('')
    [void]$report.AppendLine('  Everything above was collected automatically from the affected')
    [void]$report.AppendLine('  device. If anything else is needed, reply on the ticket and Field')
    [void]$report.AppendLine('  Services can re-run this collection on site.')
    [void]$report.AppendLine($rule)

    & $note 'Collection complete.'
    return $report.ToString()
}

<#
    Short version for pasting into chat or a ticket subject line.
#>
$script:NE_BuildSummary = {
    param([hashtable]$Context)

    $sb = [System.Text.StringBuilder]::new()
    $w = 18

    $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric | Select-Object -First 1
    $adapter = $null
    $ip = 'N/A'
    $mask = 'N/A'
    $gateway = 'N/A'

    if ($defaultRoute) {
        $adapter = Get-NetAdapter -InterfaceIndex $defaultRoute.ifIndex -ErrorAction SilentlyContinue
        $gateway = $defaultRoute.NextHop
        $ipConfig = Get-NetIPAddress -InterfaceIndex $defaultRoute.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($ipConfig) {
            $ip = $ipConfig.IPAddress
            $mask = & $script:NE_PrefixToMask -PrefixLength $ipConfig.PrefixLength
        }
    }

    [void]$sb.AppendLine("NETWORK ESCALATION - $env:COMPUTERNAME")
    [void]$sb.AppendLine((& $script:NE_Line 'Ticket' $Context.Ticket $w))
    [void]$sb.AppendLine((& $script:NE_Line 'Location' "$($Context.Site) $($Context.Room)" $w))
    [void]$sb.AppendLine((& $script:NE_Line 'Wall jack' $Context.Jack $w))
    [void]$sb.AppendLine((& $script:NE_Line 'Symptom' $Context.Symptom $w))
    [void]$sb.AppendLine((& $script:NE_Line 'Adapter' $(if ($adapter) { $adapter.Name } else { 'None' }) $w))
    [void]$sb.AppendLine((& $script:NE_Line 'MAC' $(if ($adapter) { & $script:NE_NormalizeMac -Mac $adapter.MacAddress } else { 'N/A' }) $w))
    [void]$sb.AppendLine((& $script:NE_Line 'IP / mask' "$ip / $mask" $w))
    [void]$sb.AppendLine((& $script:NE_Line 'Gateway' $gateway $w))

    $gatewayPing = & $script:NE_Ping -Target $gateway
    [void]$sb.AppendLine((& $script:NE_Line 'Gateway ping' (& $script:NE_PingText $gatewayPing) $w))
    [void]$sb.AppendLine((& $script:NE_Line 'Collected' (Get-Date -Format 'yyyy-MM-dd HH:mm') $w))
    [void]$sb.AppendLine('Full packet attached to the ticket.')

    return $sb.ToString()
}

<#
    "Look Up Device by IP" - the answer to "I have an IP, what is the MAC?"

    The important part is not the arp lookup, it is telling the tech when the
    target is off-subnet, because that is when the local table silently
    returns the gateway's MAC instead and the tech reports the wrong address.
#>
$script:NE_LookupDevice = {
    param([string]$IpAddress)

    $sb = [System.Text.StringBuilder]::new()
    $w = 22
    $target = "$IpAddress".Trim()

    [void]$sb.AppendLine($script:NE_Rule)
    [void]$sb.AppendLine("  DEVICE LOOKUP: $target")
    [void]$sb.AppendLine($script:NE_Rule)
    [void]$sb.AppendLine((& $script:NE_Line 'Looked up' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $w))
    [void]$sb.AppendLine((& $script:NE_Line 'Looked up from' "$env:COMPUTERNAME ($env:USERDOMAIN\$env:USERNAME)" $w))
    [void]$sb.AppendLine('')

    if ($target -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        [void]$sb.AppendLine('  Not a valid IPv4 address. Enter something like 10.20.5.44')
        return $sb.ToString()
    }

    # Which of our interfaces, if any, shares a subnet with the target?
    $localMatch = $null
    foreach ($ipConfig in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' })) {
        if (& $script:NE_SameSubnet -IpA $ipConfig.IPAddress -IpB $target -PrefixLength $ipConfig.PrefixLength) {
            $localMatch = $ipConfig
            break
        }
    }

    [void]$sb.AppendLine('  SUBNET CHECK')
    [void]$sb.AppendLine($script:NE_SubRule)
    if ($localMatch) {
        $adapter = Get-NetAdapter -InterfaceIndex $localMatch.InterfaceIndex -ErrorAction SilentlyContinue
        [void]$sb.AppendLine((& $script:NE_Line 'Result' 'ON THIS SUBNET - MAC will be the real device MAC' $w))
        [void]$sb.AppendLine((& $script:NE_Line 'Via adapter' $(if ($adapter) { $adapter.Name } else { "index $($localMatch.InterfaceIndex)" }) $w))
        [void]$sb.AppendLine((& $script:NE_Line 'Local IP / prefix' "$($localMatch.IPAddress)/$($localMatch.PrefixLength)" $w))
    }
    else {
        [void]$sb.AppendLine((& $script:NE_Line 'Result' 'OFF-SUBNET - this PC cannot learn its MAC' $w))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('  MAC addresses do not cross a router. Any MAC returned below is the')
        [void]$sb.AppendLine('  next-hop router, not the device. To get the real MAC, ask Networking')
        [void]$sb.AppendLine('  to check the ARP table on that VLAN gateway, or look the address up')
        [void]$sb.AppendLine('  in the DHCP lease for that scope.')
    }
    [void]$sb.AppendLine('')

    # Reachability first - it also populates the neighbor cache for us.
    [void]$sb.AppendLine('  REACHABILITY')
    [void]$sb.AppendLine($script:NE_SubRule)
    $ping = & $script:NE_Ping -Target $target -Count 2
    [void]$sb.AppendLine((& $script:NE_Line 'ICMP ping' (& $script:NE_PingText $ping) $w))

    # Many devices drop ICMP but still answer ARP, so touch a TCP port to
    # force the exchange before reading the cache.
    if (-not $ping.Success -and $localMatch) {
        [void]$sb.AppendLine('  ICMP failed - trying a TCP touch to force an ARP exchange...')
        foreach ($port in @(445, 80, 443, 9100, 22)) {
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $async = $client.BeginConnect($target, $port, $null, $null)
                [void]$async.AsyncWaitHandle.WaitOne(400)
                $client.Close()
            }
            catch { }
        }
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('  LAYER 2')
    [void]$sb.AppendLine($script:NE_SubRule)
    $macInfo = & $script:NE_GetMacForIp -IpAddress $target

    if ($macInfo.Mac) {
        [void]$sb.AppendLine((& $script:NE_Line 'MAC address' $macInfo.Mac $w))
        [void]$sb.AppendLine((& $script:NE_Line 'Vendor (OUI hint)' (& $script:NE_LookupVendor -Mac $macInfo.Mac) $w))
        [void]$sb.AppendLine((& $script:NE_Line 'Cache state' $macInfo.State $w))
        [void]$sb.AppendLine((& $script:NE_Line 'Learned via' "$($macInfo.Source) on $($macInfo.InterfaceAlias)" $w))

        if ($macInfo.State -eq 'Stale') {
            [void]$sb.AppendLine('  Note: entry is Stale (cached, possibly out of date). Re-run to refresh.')
        }
        if (-not $localMatch) {
            [void]$sb.AppendLine('  Note: target is off-subnet, so this is a router MAC. Do not report it')
            [void]$sb.AppendLine('        as the device MAC.')
        }
    }
    else {
        [void]$sb.AppendLine((& $script:NE_Line 'MAC address' 'Not found' $w))
        if ($localMatch) {
            [void]$sb.AppendLine('  The device did not answer ARP. It is powered off, unplugged, or')
            [void]$sb.AppendLine('  not actually on this VLAN.')
        }
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('  IDENTITY')
    [void]$sb.AppendLine($script:NE_SubRule)
    $hostname = & $script:NE_ReverseDns -IpAddress $target
    [void]$sb.AppendLine((& $script:NE_Line 'Reverse DNS' $(if ($hostname) { $hostname } else { 'No PTR record' }) $w))

    # A quick service fingerprint often identifies what the device is when
    # DNS has nothing, e.g. 9100 open means it is almost certainly a printer.
    $openPorts = @()
    $probes = @{
        22   = 'SSH'
        80   = 'HTTP'
        443  = 'HTTPS'
        445  = 'SMB (Windows)'
        515  = 'LPD (printer)'
        3389 = 'RDP (Windows)'
        9100 = 'JetDirect (printer)'
    }
    foreach ($port in ($probes.Keys | Sort-Object)) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect($target, $port, $null, $null)
            $connected = $async.AsyncWaitHandle.WaitOne(500)
            if ($connected -and $client.Connected) {
                $openPorts += "$port ($($probes[$port]))"
            }
            $client.Close()
        }
        catch { }
    }
    [void]$sb.AppendLine((& $script:NE_Line 'Open service ports' $(if ($openPorts.Count -gt 0) { $openPorts -join ', ' } else { 'None of the common ports answered' }) $w))
    [void]$sb.AppendLine($script:NE_Rule)

    return $sb.ToString()
}

#endregion

#region UI

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    $labelFont = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $fieldFont = New-Object System.Drawing.Font("Segoe UI", 9)

    #-- Output box is created first so every handler can write to it --------
    $outputBox = New-Object System.Windows.Forms.TextBox
    $outputBox.Multiline = $true
    $outputBox.ReadOnly = $true
    $outputBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $outputBox.WordWrap = $false
    $outputBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $outputBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $outputBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $outputBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $outputBox.Text = @"
  Rush Resolve - Network Escalation

  This tab collects everything the Networking team asks for, so you do not
  have to remember the commands or the follow-up questions.

  How to use it:

    1. Fill in the ticket and location boxes above. Wall jack ID matters
       most - it is how Networking finds the switch port.
    2. Pick the symptom, tick what you already verified, and put the
       affected server or app in "Affected target" if there is one.
    3. Click "Collect Escalation Packet". It takes about 20-30 seconds.
    4. Click "Copy for Ticket" and paste it into the ticket.

  Need a MAC address for some other device on the network? Use "Look Up
  Device by IP" on the right.
"@

    #-- Main layout --------------------------------------------------------
    $mainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.ColumnCount = 1
    $mainPanel.RowCount = 3
    [void]$mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 318)))
    [void]$mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 124)))
    [void]$mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    #-- Row 0: context -----------------------------------------------------
    $contextPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $contextPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $contextPanel.ColumnCount = 2
    $contextPanel.RowCount = 1
    [void]$contextPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 40)))
    [void]$contextPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 60)))

    # Ticket and location
    $ticketGroup = New-Object System.Windows.Forms.GroupBox
    $ticketGroup.Text = "1. Ticket and Location"
    $ticketGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $ticketGroup.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $ticketGroup.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)

    $ticketTable = New-Object System.Windows.Forms.TableLayoutPanel
    $ticketTable.Dock = [System.Windows.Forms.DockStyle]::Fill
    $ticketTable.ColumnCount = 2
    $ticketTable.RowCount = 7
    [void]$ticketTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 118)))
    [void]$ticketTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $ticketFields = @{}
    $ticketFieldDefs = @(
        @('Ticket',     'Ticket number'),
        @('Site',       'Site / building'),
        @('Room',       'Floor / room'),
        @('Jack',       'Wall jack ID'),
        @('Asset',      'Device / asset tag'),
        @('ReportedBy', 'Reported by')
    )

    $rowIndex = 0
    foreach ($def in $ticketFieldDefs) {
        [void]$ticketTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))

        $label = New-Object System.Windows.Forms.Label
        $label.Text = $def[1]
        $label.Font = $labelFont
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $label.Dock = [System.Windows.Forms.DockStyle]::Fill
        $ticketTable.Controls.Add($label, 0, $rowIndex)

        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Font = $fieldFont
        $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
        $textBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 3)
        $ticketTable.Controls.Add($textBox, 1, $rowIndex)

        $ticketFields[$def[0]] = $textBox
        $rowIndex++
    }

    # Jack ID is what Networking actually uses to find the port - highlight it.
    $ticketFields['Jack'].BackColor = [System.Drawing.Color]::FromArgb(255, 250, 225)

    $ticketGroup.Controls.Add($ticketTable)
    $contextPanel.Controls.Add($ticketGroup, 0, 0)

    # Symptom and checklist
    $symptomGroup = New-Object System.Windows.Forms.GroupBox
    $symptomGroup.Text = "2. Symptom and What You Already Verified"
    $symptomGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $symptomGroup.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $symptomGroup.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)

    $symptomLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $symptomLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $symptomLayout.ColumnCount = 1
    $symptomLayout.RowCount = 3
    [void]$symptomLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 116)))
    [void]$symptomLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 114)))
    [void]$symptomLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $comboTable = New-Object System.Windows.Forms.TableLayoutPanel
    $comboTable.Dock = [System.Windows.Forms.DockStyle]::Fill
    $comboTable.ColumnCount = 2
    $comboTable.RowCount = 4
    [void]$comboTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 110)))
    [void]$comboTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $comboDefs = @(
        @('Symptom',   'Symptom',          $script:NE_Symptoms),
        @('Scope',     'How many',         $script:NE_ScopeOptions),
        @('Onset',     'When it started',  $script:NE_OnsetOptions),
        @('LinkLight', 'Port light',       $script:NE_LinkLightOptions)
    )

    $comboFields = @{}
    $rowIndex = 0
    foreach ($def in $comboDefs) {
        [void]$comboTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))

        $label = New-Object System.Windows.Forms.Label
        $label.Text = $def[1]
        $label.Font = $labelFont
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $label.Dock = [System.Windows.Forms.DockStyle]::Fill
        $comboTable.Controls.Add($label, 0, $rowIndex)

        $combo = New-Object System.Windows.Forms.ComboBox
        $combo.Font = $fieldFont
        $combo.Dock = [System.Windows.Forms.DockStyle]::Fill
        $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
        $combo.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 3)
        foreach ($item in $def[2]) { [void]$combo.Items.Add($item) }
        $comboTable.Controls.Add($combo, 1, $rowIndex)

        $comboFields[$def[0]] = $combo
        $rowIndex++
    }
    $comboFields['LinkLight'].SelectedIndex = 0

    $symptomLayout.Controls.Add($comboTable, 0, 0)

    # Checklist
    $checkPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $checkPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $checkPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $checkPanel.WrapContents = $true
    $checkPanel.AutoScroll = $true
    $checkPanel.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)

    $checkBoxes = @()
    foreach ($item in $script:NE_ChecklistItems) {
        $checkBox = New-Object System.Windows.Forms.CheckBox
        $checkBox.Text = $item
        $checkBox.Font = $labelFont
        $checkBox.Width = 218
        $checkBox.Height = 20
        $checkBox.Margin = New-Object System.Windows.Forms.Padding(2, 1, 2, 1)
        $checkPanel.Controls.Add($checkBox)
        $checkBoxes += $checkBox
    }
    $symptomLayout.Controls.Add($checkPanel, 0, 1)

    # Affected target + notes
    $extraTable = New-Object System.Windows.Forms.TableLayoutPanel
    $extraTable.Dock = [System.Windows.Forms.DockStyle]::Fill
    $extraTable.ColumnCount = 2
    $extraTable.RowCount = 2
    [void]$extraTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 110)))
    [void]$extraTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$extraTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
    [void]$extraTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $targetLabel = New-Object System.Windows.Forms.Label
    $targetLabel.Text = "Affected target"
    $targetLabel.Font = $labelFont
    $targetLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $targetLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $extraTable.Controls.Add($targetLabel, 0, 0)

    $targetBox = New-Object System.Windows.Forms.TextBox
    $targetBox.Font = $fieldFont
    $targetBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $targetBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 3)
    $extraTable.Controls.Add($targetBox, 1, 0)

    # Held at script scope on purpose: a ToolTip that only a local variable
    # references gets collected and the tip silently stops appearing.
    $script:NE_ToolTip = New-Object System.Windows.Forms.ToolTip
    $script:NE_ToolTip.SetToolTip($targetBox, "Server, app hostname or IP the user cannot reach. Leave blank if the device has no network at all.")
    $script:NE_ToolTip.SetToolTip($ticketFields['Jack'], "The label on the wall faceplate. This is how Networking finds the switch port - it saves them a trip.")

    $notesLabel = New-Object System.Windows.Forms.Label
    $notesLabel.Text = "Tech notes"
    $notesLabel.Font = $labelFont
    $notesLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $notesLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $extraTable.Controls.Add($notesLabel, 0, 1)

    $notesBox = New-Object System.Windows.Forms.TextBox
    $notesBox.Font = $fieldFont
    $notesBox.Multiline = $true
    $notesBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $notesBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $notesBox.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 3)
    $extraTable.Controls.Add($notesBox, 1, 1)

    $symptomLayout.Controls.Add($extraTable, 0, 2)
    $symptomGroup.Controls.Add($symptomLayout)
    $contextPanel.Controls.Add($symptomGroup, 1, 0)

    $mainPanel.Controls.Add($contextPanel, 0, 0)

    #-- Row 1: actions -----------------------------------------------------
    $actionPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $actionPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionPanel.ColumnCount = 2
    $actionPanel.RowCount = 1
    [void]$actionPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 62)))
    [void]$actionPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 38)))

    $collectGroup = New-Object System.Windows.Forms.GroupBox
    $collectGroup.Text = "3. Build the Escalation Packet"
    $collectGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $collectGroup.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $collectGroup.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)

    $collectFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $collectFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $collectFlow.WrapContents = $true
    $collectFlow.AutoScroll = $true

    $collectBtn = New-Object System.Windows.Forms.Button
    $collectBtn.Text = "Collect Escalation Packet"
    $collectBtn.Width = 178
    $collectBtn.Height = 32
    $collectBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $collectBtn.BackColor = [System.Drawing.Color]::FromArgb(225, 240, 255)
    $collectBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $collectFlow.Controls.Add($collectBtn)

    $copyBtn = New-Object System.Windows.Forms.Button
    $copyBtn.Text = "Copy for Ticket"
    $copyBtn.Width = 118
    $copyBtn.Height = 32
    $copyBtn.Enabled = $false
    $collectFlow.Controls.Add($copyBtn)

    $summaryBtn = New-Object System.Windows.Forms.Button
    $summaryBtn.Text = "Copy Short Summary"
    $summaryBtn.Width = 145
    $summaryBtn.Height = 32
    $collectFlow.Controls.Add($summaryBtn)

    $saveBtn = New-Object System.Windows.Forms.Button
    $saveBtn.Text = "Save Report"
    $saveBtn.Width = 100
    $saveBtn.Height = 32
    $saveBtn.Enabled = $false
    $collectFlow.Controls.Add($saveBtn)

    $openLogsBtn = New-Object System.Windows.Forms.Button
    $openLogsBtn.Text = "Open Reports Folder"
    $openLogsBtn.Width = 145
    $openLogsBtn.Height = 32
    $collectFlow.Controls.Add($openLogsBtn)

    $optionsFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $optionsFlow.Width = 560
    $optionsFlow.Height = 26
    $optionsFlow.Margin = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
    $optionsFlow.WrapContents = $false

    $lldpCheck = New-Object System.Windows.Forms.CheckBox
    $lldpCheck.Text = "Switch/port info (LLDP, needs admin)"
    $lldpCheck.Font = $labelFont
    $lldpCheck.Checked = $true
    $lldpCheck.Width = 235
    $lldpCheck.Height = 22
    $optionsFlow.Controls.Add($lldpCheck)

    $traceCheck = New-Object System.Windows.Forms.CheckBox
    $traceCheck.Text = "Traceroute to target"
    $traceCheck.Font = $labelFont
    $traceCheck.Checked = $true
    $traceCheck.Width = 145
    $traceCheck.Height = 22
    $optionsFlow.Controls.Add($traceCheck)

    $rawCheck = New-Object System.Windows.Forms.CheckBox
    $rawCheck.Text = "Append raw ipconfig"
    $rawCheck.Font = $labelFont
    $rawCheck.Checked = $true
    $rawCheck.Width = 150
    $rawCheck.Height = 22
    $optionsFlow.Controls.Add($rawCheck)

    $collectFlow.Controls.Add($optionsFlow)
    $collectGroup.Controls.Add($collectFlow)
    $actionPanel.Controls.Add($collectGroup, 0, 0)

    # Look up device by IP
    $lookupGroup = New-Object System.Windows.Forms.GroupBox
    $lookupGroup.Text = "Look Up Device by IP (MAC / vendor / hostname)"
    $lookupGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lookupGroup.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lookupGroup.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)

    $lookupFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $lookupFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lookupFlow.WrapContents = $true

    $lookupLabel = New-Object System.Windows.Forms.Label
    $lookupLabel.Text = "IP address"
    $lookupLabel.Font = $labelFont
    $lookupLabel.Width = 68
    $lookupLabel.Height = 26
    $lookupLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lookupFlow.Controls.Add($lookupLabel)

    $lookupBox = New-Object System.Windows.Forms.TextBox
    $lookupBox.Font = $fieldFont
    $lookupBox.Width = 132
    $lookupFlow.Controls.Add($lookupBox)

    $lookupBtn = New-Object System.Windows.Forms.Button
    $lookupBtn.Text = "Look Up"
    $lookupBtn.Width = 88
    $lookupBtn.Height = 26
    $lookupFlow.Controls.Add($lookupBtn)

    $importOuiBtn = New-Object System.Windows.Forms.Button
    $importOuiBtn.Text = "Import OUI File"
    $importOuiBtn.Width = 118
    $importOuiBtn.Height = 26
    $lookupFlow.Controls.Add($importOuiBtn)

    $lookupHint = New-Object System.Windows.Forms.Label
    $lookupHint.Text = "Works for devices on the same subnet. Off-subnet IPs are flagged with what to do instead."
    $lookupHint.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lookupHint.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $lookupHint.Width = 360
    $lookupHint.Height = 34
    $lookupFlow.Controls.Add($lookupHint)

    $lookupGroup.Controls.Add($lookupFlow)
    $actionPanel.Controls.Add($lookupGroup, 1, 0)

    $mainPanel.Controls.Add($actionPanel, 0, 1)

    #-- Row 2: output ------------------------------------------------------
    $outputGroup = New-Object System.Windows.Forms.GroupBox
    $outputGroup.Text = "Escalation Packet"
    $outputGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $outputGroup.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $outputGroup.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 6)
    $outputGroup.Controls.Add($outputBox)
    $mainPanel.Controls.Add($outputGroup, 0, 2)

    $tab.Controls.Add($mainPanel)

    #-- Handlers -----------------------------------------------------------
    # Captured by GetNewClosure() below; modules are dot-sourced into the
    # loader's scope so these locals are the only reliable references.
    $outputBoxRef    = $outputBox
    $outputGroupRef  = $outputGroup
    $ticketFieldsRef = $ticketFields
    $comboFieldsRef  = $comboFields
    $checkBoxesRef   = $checkBoxes
    $targetBoxRef    = $targetBox
    $notesBoxRef     = $notesBox
    $lldpCheckRef    = $lldpCheck
    $traceCheckRef   = $traceCheck
    $rawCheckRef     = $rawCheck
    $lookupBoxRef    = $lookupBox
    $copyBtnRef      = $copyBtn
    $saveBtnRef      = $saveBtn
    $collectBtnRef   = $collectBtn
    $lookupBtnRef    = $lookupBtn

    # Reads the whole form into the hashtable the collector expects.
    $buildContext = {
        $checked = @()
        foreach ($checkBox in $checkBoxesRef) {
            if ($checkBox.Checked) { $checked += $checkBox.Text }
        }

        return @{
            Ticket       = $ticketFieldsRef['Ticket'].Text
            Site         = $ticketFieldsRef['Site'].Text
            Room         = $ticketFieldsRef['Room'].Text
            Jack         = $ticketFieldsRef['Jack'].Text
            Asset        = $ticketFieldsRef['Asset'].Text
            ReportedBy   = $ticketFieldsRef['ReportedBy'].Text
            Symptom      = $comboFieldsRef['Symptom'].Text
            Scope        = $comboFieldsRef['Scope'].Text
            Onset        = $comboFieldsRef['Onset'].Text
            LinkLight    = $comboFieldsRef['LinkLight'].Text
            Notes        = $notesBoxRef.Text
            TestTarget   = $targetBoxRef.Text
            Checked      = $checked
            IncludeLldp  = $lldpCheckRef.Checked
            IncludeTrace = $traceCheckRef.Checked
            IncludeRaw   = $rawCheckRef.Checked
            Credential   = $null
        }
    }.GetNewClosure()

    $collectBtn.Add_Click({
        param($sender, $e)

        $context = & $buildContext

        if (-not "$($context.Ticket)".Trim()) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "No ticket number entered.`n`nCollect anyway?",
                "Network Escalation",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        if (-not "$($context.Jack)".Trim()) {
            [System.Windows.Forms.MessageBox]::Show(
                "No wall jack ID entered.`n`nNetworking uses the jack ID to find the switch port. If the faceplate has a label, add it before sending the ticket.",
                "Network Escalation",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }

        # LLDP needs admin. Ask once, up front, rather than mid-collection.
        if ($context.IncludeLldp) {
            $alreadyElevated = $false
            if (Get-Command -Name Test-IsElevated -ErrorAction SilentlyContinue) {
                $alreadyElevated = Test-IsElevated
            }
            if (-not $alreadyElevated) {
                $context.Credential = Get-ElevatedCredential -Message "Enter admin credentials to read switch and port info (LLDP)"
            }
        }

        $collectBtnRef.Enabled = $false
        $collectBtnRef.Text = "Collecting..."
        $outputBoxRef.Text = ""
        [System.Windows.Forms.Application]::DoEvents()

        $progress = {
            param($Message)
            $outputGroupRef.Text = "Escalation Packet - $Message"
            if (Get-Command -Name Start-AppActivity -ErrorAction SilentlyContinue) {
                Start-AppActivity -Message $Message
            }
            [System.Windows.Forms.Application]::DoEvents()
        }.GetNewClosure()

        try {
            $report = & $script:NE_BuildPacket -Context $context -Progress $progress
            $script:NE_LastReport = $report
            $outputBoxRef.Text = $report
            $outputBoxRef.SelectionStart = 0
            $outputBoxRef.ScrollToCaret()
            $copyBtnRef.Enabled = $true
            $saveBtnRef.Enabled = $true
            $outputGroupRef.Text = "Escalation Packet - ready to paste into the ticket"

            if (Get-Command -Name Write-SessionLog -ErrorAction SilentlyContinue) {
                Write-SessionLog "Network Escalation packet collected (ticket: $(if ("$($context.Ticket)".Trim()) { $context.Ticket } else { 'none' }))"
            }
            if (Get-Command -Name Clear-AppStatus -ErrorAction SilentlyContinue) {
                Clear-AppStatus
            }
        }
        catch {
            $outputBoxRef.Text = "Collection failed: $($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)"
            $outputGroupRef.Text = "Escalation Packet - collection failed"
            if (Get-Command -Name Set-AppError -ErrorAction SilentlyContinue) {
                Set-AppError -Message "Network escalation collection failed"
            }
        }
        finally {
            $collectBtnRef.Enabled = $true
            $collectBtnRef.Text = "Collect Escalation Packet"
        }
    }.GetNewClosure())

    $copyBtn.Add_Click({
        param($sender, $e)
        if ($outputBoxRef.Text) {
            [System.Windows.Forms.Clipboard]::SetText($outputBoxRef.Text)
            [System.Windows.Forms.MessageBox]::Show(
                "Escalation packet copied. Paste it into the ticket before assigning to Networking.",
                "Copied",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
    }.GetNewClosure())

    $summaryBtn.Add_Click({
        param($sender, $e)
        try {
            $context = & $buildContext
            $summary = & $script:NE_BuildSummary -Context $context
            [System.Windows.Forms.Clipboard]::SetText($summary)
            [System.Windows.Forms.MessageBox]::Show(
                "Short summary copied:`n`n$summary",
                "Copied",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not build summary: $($_.Exception.Message)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }.GetNewClosure())

    $saveBtn.Add_Click({
        param($sender, $e)
        if (-not $outputBoxRef.Text) { return }

        try {
            if (-not (Test-Path $script:LogsPath)) {
                New-Item -Path $script:LogsPath -ItemType Directory -Force | Out-Null
            }

            $ticketPart = ($ticketFieldsRef['Ticket'].Text -replace '[^A-Za-z0-9\-_]', '')
            if (-not $ticketPart) { $ticketPart = 'NOTICKET' }
            $fileName = "NETESC-$ticketPart-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
            $fullPath = Join-Path $script:LogsPath $fileName

            Set-Content -Path $fullPath -Value $outputBoxRef.Text -Encoding ASCII -Force

            if (Get-Command -Name Write-SessionLog -ErrorAction SilentlyContinue) {
                Write-SessionLog "Network escalation report saved: $fileName"
            }

            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Saved to:`n$fullPath`n`nOpen the folder now?",
                "Report Saved",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Information)
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                Start-Process explorer.exe -ArgumentList "/select,`"$fullPath`""
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not save the report: $($_.Exception.Message)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }.GetNewClosure())

    $openLogsBtn.Add_Click({
        param($sender, $e)
        if (-not (Test-Path $script:LogsPath)) {
            New-Item -Path $script:LogsPath -ItemType Directory -Force | Out-Null
        }
        Start-Process explorer.exe -ArgumentList $script:LogsPath
    }.GetNewClosure())

    $lookupAction = {
        $target = "$($lookupBoxRef.Text)".Trim()
        if (-not $target) {
            [System.Windows.Forms.MessageBox]::Show(
                "Enter the IP address of the device you are looking for.",
                "Look Up Device",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        $lookupBtnRef.Enabled = $false
        $lookupBtnRef.Text = "Working..."
        $outputGroupRef.Text = "Escalation Packet - looking up $target"
        [System.Windows.Forms.Application]::DoEvents()

        try {
            $outputBoxRef.Text = & $script:NE_LookupDevice -IpAddress $target
            $outputBoxRef.SelectionStart = 0
            $outputBoxRef.ScrollToCaret()
            $outputGroupRef.Text = "Escalation Packet - device lookup result"
            $copyBtnRef.Enabled = $true
            $saveBtnRef.Enabled = $true

            if (Get-Command -Name Write-SessionLog -ErrorAction SilentlyContinue) {
                Write-SessionLog "Network Escalation device lookup: $target"
            }
        }
        catch {
            $outputBoxRef.Text = "Lookup failed: $($_.Exception.Message)"
        }
        finally {
            $lookupBtnRef.Enabled = $true
            $lookupBtnRef.Text = "Look Up"
        }
    }.GetNewClosure()

    $lookupBtn.Add_Click({
        param($sender, $e)
        & $lookupAction
    }.GetNewClosure())

    # Enter in the IP box should just run the lookup.
    $lookupBox.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            & $lookupAction
        }
    }.GetNewClosure())

    $importOuiBtn.Add_Click({
        param($sender, $e)

        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = "Select the IEEE OUI export (oui.csv)"
        $dialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"

        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

        try {
            $sample = Import-Csv -Path $dialog.FileName -ErrorAction Stop | Select-Object -First 1
            if (-not $sample -or -not ($sample.PSObject.Properties.Name -contains 'Assignment')) {
                [System.Windows.Forms.MessageBox]::Show(
                    "That file does not look like the IEEE OUI export.`n`nExpected columns including 'Assignment' and 'Organization Name'. Download the MA-L CSV from standards-oui.ieee.org.",
                    "Import OUI File",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }

            if (-not (Test-Path $script:ConfigPath)) {
                New-Item -Path $script:ConfigPath -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $dialog.FileName -Destination (Join-Path $script:ConfigPath 'oui.csv') -Force

            $script:NE_OuiCsv = $null
            & $script:NE_LoadOuiCsv

            [System.Windows.Forms.MessageBox]::Show(
                "Imported $($script:NE_OuiCsv.Count) vendor prefixes.`n`nVendor lookup is now available for every registered OUI.",
                "Import OUI File",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not import that file: $($_.Exception.Message)",
                "Import OUI File",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }.GetNewClosure())
}

#endregion
