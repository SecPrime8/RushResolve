<#
.SYNOPSIS
    Diagnostic Collection Module for Rush Resolve
.DESCRIPTION
    Systematically collects system health data to diagnose intermittent issues
    (freezing, hangs, crashes) and provides actionable recommendations.
    Includes HP-specific driver management via HPIA.
.NOTES
    Root causes detected (in order of frequency):
    1. Storage issues - Low disk space, failing drives (SMART errors)
    2. Memory problems - Bad RAM, memory leaks (high uptime)
    3. Driver conflicts - Especially GPU, storage controllers, chipset
    4. Thermal throttling - Overheating CPU/GPU
    5. Hardware errors - WHEA events indicating component failure
    6. Software conflicts - Resource-hogging processes
#>

$script:ModuleName = "Diagnostics"
$script:ModuleDescription = "Collect system health data and diagnose issues"

#region Constants and Severity Definitions

$script:Severity = @{
    Critical = "Critical"
    Warning = "Warning"
    Info = "Info"
    OK = "OK"
}

$script:SeverityColors = @{
    Critical = [System.Drawing.Color]::FromArgb(220, 53, 69)   # Red
    Warning  = [System.Drawing.Color]::FromArgb(255, 193, 7)  # Orange/Yellow
    Info     = [System.Drawing.Color]::FromArgb(0, 123, 255)  # Blue
    OK       = [System.Drawing.Color]::FromArgb(40, 167, 69)  # Green
}

# OS version detection
$script:OSVersion = [System.Environment]::OSVersion.Version
$script:IsWin11 = $script:OSVersion.Build -ge 22000

# HP detection
$script:IsHPMachine = $null
$script:HPIAPath = $null

#endregion

#region HP Detection Functions

$script:DetectHP = {
    if ($null -eq $script:IsHPMachine) {
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
            $script:IsHPMachine = $cs.Manufacturer -match "HP|Hewlett"
        }
        catch {
            $script:IsHPMachine = $false
        }
    }
    return $script:IsHPMachine
}

$script:GetHPIAPath = {
    if ($null -eq $script:HPIAPath) {
        # Check repo location first (Tools/HPIA/ relative to module's parent directory)
        $repoHPIA = Join-Path (Split-Path $PSScriptRoot -Parent) "Tools\HPIA\HPImageAssistant.exe"

        $possiblePaths = @(
            $repoHPIA,
            "${env:ProgramFiles(x86)}\HP\HPIA\HPImageAssistant.exe",
            "${env:ProgramFiles}\HP\HPIA\HPImageAssistant.exe",
            "C:\HPIA\HPImageAssistant.exe"
        )
        foreach ($path in $possiblePaths) {
            if (Test-Path $path) {
                $script:HPIAPath = $path
                break
            }
        }
    }
    return $script:HPIAPath
}

#endregion

#region Finding Object Helper

$script:NewFinding = {
    param(
        [string]$Category,
        [string]$Issue,
        [string]$Severity,
        [string]$Recommendation,
        [string]$Details = ""
    )
    return [PSCustomObject]@{
        Category = $Category
        Issue = $Issue
        Severity = $Severity
        Recommendation = $Recommendation
        Details = $Details
    }
}

#endregion

#region UI Helper Functions

$script:UpdateFindingsListView = {
    $script:diagListView.BeginUpdate()
    $script:diagListView.Items.Clear()

    # Sort by severity (Critical first, then Warning, Info, OK)
    $severityOrder = @{ "Critical" = 0; "Warning" = 1; "Info" = 2; "OK" = 3 }
    $sorted = $script:diagFindings | Sort-Object { $severityOrder[$_.Severity] }

    foreach ($finding in $sorted) {
        # Status icon character
        $icon = switch ($finding.Severity) {
            "Critical" { [char]0x25CF }  # Filled circle
            "Warning"  { [char]0x25CF }
            "Info"     { [char]0x25CF }
            "OK"       { [char]0x25CB }  # Empty circle
            default    { "" }
        }

        $item = New-Object System.Windows.Forms.ListViewItem($icon.ToString())
        $item.SubItems.Add($finding.Category) | Out-Null
        $item.SubItems.Add($finding.Issue) | Out-Null
        $item.SubItems.Add($finding.Severity) | Out-Null
        $item.SubItems.Add($finding.Recommendation) | Out-Null
        $item.Tag = $finding

        # Color based on severity
        $item.ForeColor = switch ($finding.Severity) {
            "Critical" { [System.Drawing.Color]::FromArgb(180, 40, 40) }
            "Warning"  { [System.Drawing.Color]::FromArgb(180, 120, 0) }
            "Info"     { [System.Drawing.Color]::FromArgb(0, 100, 180) }
            "OK"       { [System.Drawing.Color]::FromArgb(40, 140, 40) }
            default    { [System.Drawing.Color]::Black }
        }

        $script:diagListView.Items.Add($item) | Out-Null
    }

    $script:diagListView.EndUpdate()

    # Update group text with summary
    $critical = @($script:diagFindings | Where-Object { $_.Severity -eq "Critical" }).Count
    $warning = @($script:diagFindings | Where-Object { $_.Severity -eq "Warning" }).Count
    $findingsGroup = $script:diagListView.Parent
    if ($findingsGroup -is [System.Windows.Forms.GroupBox]) {
        $findingsGroup.Text = "Findings ($($script:diagFindings.Count) items - $critical critical, $warning warning)"
    }
}

#endregion

#region Data Collectors

$script:CollectEventErrors = {
    param([scriptblock]$Log)

    $findings = @()
    $daysBack = 7
    $startDate = (Get-Date).AddDays(-$daysBack)

    if ($Log) { & $Log "Checking event logs for last $daysBack days..." }

    try {
        # WHEA-Logger (hardware errors) - most critical
        $wheaEvents = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'Microsoft-Windows-WHEA-Logger'
            Level = 1,2,3  # Critical, Error, Warning
            StartTime = $startDate
        } -ErrorAction SilentlyContinue)

        if ($wheaEvents.Count -gt 0) {
            $severity = if ($wheaEvents.Count -gt 5) { "Critical" } else { "Warning" }
            $latestWhea = $wheaEvents[0]
            $findings += & $script:NewFinding -Category "Events" `
                -Issue "$($wheaEvents.Count) WHEA hardware errors" `
                -Severity $severity `
                -Recommendation "Run Windows Memory Diagnostic (mdsched.exe) - likely RAM issue" `
                -Details "Most recent: $($latestWhea.TimeCreated.ToString('yyyy-MM-dd HH:mm')) - $($latestWhea.Message.Substring(0, [Math]::Min(100, $latestWhea.Message.Length)))..."
        }
        if ($Log) { & $Log "  WHEA errors: $($wheaEvents.Count)" }
    }
    catch {
        if ($Log) { & $Log "  WHEA check failed: $($_.Exception.Message)" }
    }

    try {
        # Kernel-Power Event 41 (unexpected shutdowns)
        $kernelPowerEvents = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'Microsoft-Windows-Kernel-Power'
            Id = 41
            StartTime = $startDate
        } -ErrorAction SilentlyContinue)

        if ($kernelPowerEvents.Count -gt 0) {
            $findings += & $script:NewFinding -Category "Events" `
                -Issue "$($kernelPowerEvents.Count) unexpected shutdowns" `
                -Severity "Critical" `
                -Recommendation "Check power supply and thermals - unexpected shutdowns detected" `
                -Details "Event 41 (Kernel-Power) indicates system crashed or lost power unexpectedly"
        }
        if ($Log) { & $Log "  Kernel-Power 41 events: $($kernelPowerEvents.Count)" }
    }
    catch {
        if ($Log) { & $Log "  Kernel-Power check failed: $($_.Exception.Message)" }
    }

    try {
        # Disk errors (ntfs, disk)
        $diskEvents = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'disk', 'ntfs', 'Microsoft-Windows-Ntfs'
            Level = 1,2,3
            StartTime = $startDate
        } -ErrorAction SilentlyContinue)

        if ($diskEvents.Count -gt 0) {
            $severity = if ($diskEvents.Count -gt 10) { "Critical" } else { "Warning" }
            $findings += & $script:NewFinding -Category "Events" `
                -Issue "$($diskEvents.Count) disk/filesystem errors" `
                -Severity $severity `
                -Recommendation "Check drive health - run chkdsk /f /r" `
                -Details "Disk or filesystem errors detected in event log"
        }
        if ($Log) { & $Log "  Disk errors: $($diskEvents.Count)" }
    }
    catch {
        if ($Log) { & $Log "  Disk event check failed: $($_.Exception.Message)" }
    }

    # Win11 specific: LiveKernelEvent (GPU hangs/TDR)
    if ($script:IsWin11) {
        try {
            $liveKernelEvents = @(Get-WinEvent -FilterHashtable @{
                LogName = 'System'
                ProviderName = 'Microsoft-Windows-Kernel-LiveDump'
                StartTime = $startDate
            } -ErrorAction SilentlyContinue)

            # Also check for display driver TDR events (Event 117, 141)
            $tdrEvents = @(Get-WinEvent -FilterHashtable @{
                LogName = 'System'
                Id = 117, 141
                StartTime = $startDate
            } -ErrorAction SilentlyContinue)

            $totalGpuEvents = $liveKernelEvents.Count + $tdrEvents.Count
            if ($totalGpuEvents -gt 0) {
                $findings += & $script:NewFinding -Category "Events" `
                    -Issue "$totalGpuEvents GPU/display driver crashes" `
                    -Severity "Critical" `
                    -Recommendation "Update graphics driver (use DDU for clean install)" `
                    -Details "LiveKernelEvent/TDR timeout detected - GPU driver crashes and recovered"
            }
            if ($Log) { & $Log "  GPU/TDR events: $totalGpuEvents" }
        }
        catch {
            if ($Log) { & $Log "  LiveKernel check failed: $($_.Exception.Message)" }
        }
    }

    try {
        # BugCheck (BSOD) events
        $bugCheckEvents = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
            StartTime = $startDate
        } -ErrorAction SilentlyContinue)

        if ($bugCheckEvents.Count -gt 0) {
            $findings += & $script:NewFinding -Category "Events" `
                -Issue "$($bugCheckEvents.Count) BSOD crashes recorded" `
                -Severity "Critical" `
                -Recommendation "Check C:\Windows\Minidump for crash dumps - may indicate hardware failure" `
                -Details "Blue screen crashes logged in event viewer"
        }
        if ($Log) { & $Log "  BSOD events: $($bugCheckEvents.Count)" }
    }
    catch {
        if ($Log) { & $Log "  BugCheck event check failed: $($_.Exception.Message)" }
    }

    # If no issues found, add OK finding
    if ($findings.Count -eq 0) {
        $findings += & $script:NewFinding -Category "Events" `
            -Issue "No critical errors in last $daysBack days" `
            -Severity "OK" `
            -Recommendation "-"
    }

    return $findings
}

$script:CollectStorageHealth = {
    param([scriptblock]$Log)

    $findings = @()

    if ($Log) { & $Log "Checking storage health..." }

    # Check disk space
    try {
        $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue

        foreach ($drive in $drives) {
            $freePercent = [math]::Round(($drive.FreeSpace / $drive.Size) * 100, 0)
            $usedPercent = 100 - $freePercent
            $freeGB = [math]::Round($drive.FreeSpace / 1GB, 1)
            $totalGB = [math]::Round($drive.Size / 1GB, 1)

            if ($Log) { & $Log "  $($drive.DeviceID) $freeGB GB free ($usedPercent% used)" }

            if ($usedPercent -ge 95) {
                $findings += & $script:NewFinding -Category "Storage" `
                    -Issue "$($drive.DeviceID) drive $usedPercent% full" `
                    -Severity "Critical" `
                    -Recommendation "CRITICAL: Free up space immediately - system may freeze" `
                    -Details "$freeGB GB free of $totalGB GB"
            }
            elseif ($usedPercent -ge 90) {
                $findings += & $script:NewFinding -Category "Storage" `
                    -Issue "$($drive.DeviceID) drive $usedPercent% full" `
                    -Severity "Critical" `
                    -Recommendation "Run Disk Cleanup module to free space" `
                    -Details "$freeGB GB free of $totalGB GB"
            }
            elseif ($usedPercent -ge 80) {
                $findings += & $script:NewFinding -Category "Storage" `
                    -Issue "$($drive.DeviceID) drive $usedPercent% full" `
                    -Severity "Warning" `
                    -Recommendation "Consider cleanup - low space can cause issues" `
                    -Details "$freeGB GB free of $totalGB GB"
            }
        }
    }
    catch {
        if ($Log) { & $Log "  Disk space check failed: $($_.Exception.Message)" }
    }

    # Check SMART status
    try {
        $physicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue

        foreach ($disk in $physicalDisks) {
            if ($Log) { & $Log "  Checking SMART: $($disk.FriendlyName)" }

            if ($disk.HealthStatus -ne "Healthy") {
                $findings += & $script:NewFinding -Category "Storage" `
                    -Issue "Disk '$($disk.FriendlyName)' health: $($disk.HealthStatus)" `
                    -Severity "Critical" `
                    -Recommendation "BACK UP DATA IMMEDIATELY - drive failure predicted" `
                    -Details "Media type: $($disk.MediaType), Size: $([math]::Round($disk.Size / 1GB, 0)) GB"
            }

            # Try to get reliability counters
            try {
                $reliability = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction SilentlyContinue
                if ($reliability) {
                    $issues = @()
                    if ($reliability.ReadErrorsTotal -gt 0) { $issues += "Read errors: $($reliability.ReadErrorsTotal)" }
                    if ($reliability.WriteErrorsTotal -gt 0) { $issues += "Write errors: $($reliability.WriteErrorsTotal)" }

                    if ($issues.Count -gt 0) {
                        $findings += & $script:NewFinding -Category "Storage" `
                            -Issue "Disk '$($disk.FriendlyName)' has I/O errors" `
                            -Severity "Warning" `
                            -Recommendation "Monitor drive closely - may be failing" `
                            -Details ($issues -join ", ")
                    }

                    if ($Log) { & $Log "    Power-on hours: $($reliability.PowerOnHours), Temp: $($reliability.Temperature)C" }
                }
            }
            catch {
                if ($Log) { & $Log "    Could not get reliability counters" }
            }
        }
    }
    catch {
        if ($Log) { & $Log "  SMART check failed: $($_.Exception.Message)" }
    }

    # If no issues found, add OK finding
    $storageIssues = $findings | Where-Object { $_.Category -eq "Storage" }
    if ($storageIssues.Count -eq 0) {
        $findings += & $script:NewFinding -Category "Storage" `
            -Issue "All drives healthy" `
            -Severity "OK" `
            -Recommendation "-"
    }

    return $findings
}

$script:CollectMemoryInfo = {
    param([scriptblock]$Log)

    $findings = @()

    if ($Log) { & $Log "Checking memory status..." }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue

        $totalRAM = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB / 1024, 1)
        $usedPercent = [math]::Round((1 - ($os.FreePhysicalMemory * 1KB / $cs.TotalPhysicalMemory)) * 100, 0)

        if ($Log) { & $Log "  Total: $totalRAM GB, Available: $freeRAM GB ($usedPercent% used)" }

        # Check committed memory vs physical (memory pressure)
        $committedGB = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) * 1KB / 1GB, 1)
        $commitLimit = [math]::Round($os.TotalVirtualMemorySize * 1KB / 1GB, 1)

        if ($Log) { & $Log "  Committed: $committedGB GB of $commitLimit GB" }

        if ($usedPercent -ge 90) {
            $findings += & $script:NewFinding -Category "Memory" `
                -Issue "RAM $usedPercent% used" `
                -Severity "Warning" `
                -Recommendation "High memory usage - check for memory leaks or runaway processes" `
                -Details "$freeRAM GB free of $totalRAM GB total"
        }

        # Check if committed > physical (heavy paging)
        if ($committedGB -gt $totalRAM * 1.5) {
            $findings += & $script:NewFinding -Category "Memory" `
                -Issue "Memory pressure: Committed ${committedGB}GB exceeds RAM" `
                -Severity "Warning" `
                -Recommendation "System paging heavily - close unused applications or add RAM" `
                -Details "Committed: $committedGB GB, Physical RAM: $totalRAM GB"
        }
    }
    catch {
        if ($Log) { & $Log "  Memory check failed: $($_.Exception.Message)" }
    }

    # Check for memory errors in event log
    try {
        $memDiagEvents = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'
        } -MaxEvents 5 -ErrorAction SilentlyContinue)

        foreach ($event in $memDiagEvents) {
            if ($event.Message -match "hardware problems were detected|errors were found") {
                $findings += & $script:NewFinding -Category "Memory" `
                    -Issue "Memory diagnostic found hardware errors" `
                    -Severity "Critical" `
                    -Recommendation "Replace RAM - memory diagnostic detected bad memory" `
                    -Details $event.Message.Substring(0, [Math]::Min(200, $event.Message.Length))
                break
            }
        }
        if ($Log) { & $Log "  Memory diagnostic events checked" }
    }
    catch {
        if ($Log) { & $Log "  Memory diagnostic event check failed: $($_.Exception.Message)" }
    }

    # If no issues found, add OK finding
    $memIssues = $findings | Where-Object { $_.Category -eq "Memory" }
    if ($memIssues.Count -eq 0) {
        $findings += & $script:NewFinding -Category "Memory" `
            -Issue "$totalRAM GB total, $usedPercent% used" `
            -Severity "OK" `
            -Recommendation "-"
    }

    return $findings
}

$script:CollectDriverIssues = {
    param([scriptblock]$Log)

    $findings = @()

    if ($Log) { & $Log "Checking for driver issues..." }

    try {
        # Problem devices (error codes)
        $problemDevices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.ConfigManagerErrorCode -ne 0 }

        if ($problemDevices) {
            $deviceList = ($problemDevices | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ", "
            $findings += & $script:NewFinding -Category "Drivers" `
                -Issue "$($problemDevices.Count) problem devices found" `
                -Severity "Warning" `
                -Recommendation "Check Device Manager for yellow/red icons" `
                -Details "Devices: $deviceList"

            if ($Log) {
                & $Log "  Problem devices: $($problemDevices.Count)"
                foreach ($dev in ($problemDevices | Select-Object -First 3)) {
                    & $Log "    - $($dev.Name) (Error: $($dev.ConfigManagerErrorCode))"
                }
            }
        }
        else {
            if ($Log) { & $Log "  No problem devices found" }
        }
    }
    catch {
        if ($Log) { & $Log "  Problem device check failed: $($_.Exception.Message)" }
    }

    # Check for recently updated drivers (last 30 days)
    try {
        $recentDrivers = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { $_.DriverDate -and $_.DriverDate -gt (Get-Date).AddDays(-30) } |
            Select-Object DeviceName, DriverDate, DriverVersion -First 5

        if ($recentDrivers) {
            $driverList = ($recentDrivers | ForEach-Object { $_.DeviceName }) -join ", "
            $findings += & $script:NewFinding -Category "Drivers" `
                -Issue "$($recentDrivers.Count) drivers updated recently" `
                -Severity "Info" `
                -Recommendation "Recent driver updates may correlate with issues" `
                -Details $driverList

            if ($Log) { & $Log "  Recent driver updates: $($recentDrivers.Count)" }
        }
    }
    catch {
        if ($Log) { & $Log "  Recent driver check failed: $($_.Exception.Message)" }
    }

    # If no issues found, add OK finding
    $driverIssues = $findings | Where-Object { $_.Category -eq "Drivers" -and $_.Severity -ne "Info" }
    if ($driverIssues.Count -eq 0 -and -not ($findings | Where-Object { $_.Category -eq "Drivers" })) {
        $findings += & $script:NewFinding -Category "Drivers" `
            -Issue "No driver problems detected" `
            -Severity "OK" `
            -Recommendation "-"
    }

    return $findings
}

$script:CollectThermalData = {
    param([scriptblock]$Log)

    $findings = @()

    if ($Log) { & $Log "Checking thermal/CPU status..." }

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($cpu) {
            $currentSpeed = $cpu.CurrentClockSpeed
            $maxSpeed = $cpu.MaxClockSpeed
            $throttlePercent = [math]::Round(($currentSpeed / $maxSpeed) * 100, 0)

            if ($Log) { & $Log "  CPU: $currentSpeed MHz / $maxSpeed MHz ($throttlePercent%)" }

            # Significant throttling detection (running below 80% of max)
            if ($throttlePercent -lt 80) {
                $findings += & $script:NewFinding -Category "Thermal" `
                    -Issue "CPU throttling detected ($throttlePercent% of max speed)" `
                    -Severity "Warning" `
                    -Recommendation "Check cooling - CPU running slow due to heat or power limits" `
                    -Details "Current: $currentSpeed MHz, Max: $maxSpeed MHz"
            }
        }
    }
    catch {
        if ($Log) { & $Log "  CPU check failed: $($_.Exception.Message)" }
    }

    # Try to get temperature (may not be available on all systems)
    try {
        $temp = Get-CimInstance -Namespace "root\wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($temp) {
            $celsius = [math]::Round(($temp.CurrentTemperature / 10) - 273.15, 0)
            if ($Log) { & $Log "  Temperature: ${celsius}C" }

            if ($celsius -gt 85) {
                $findings += & $script:NewFinding -Category "Thermal" `
                    -Issue "High CPU temperature: ${celsius}C" `
                    -Severity "Critical" `
                    -Recommendation "Check cooling immediately - thermal throttling likely" `
                    -Details "Temperature exceeds safe operating range"
            }
            elseif ($celsius -gt 75) {
                $findings += & $script:NewFinding -Category "Thermal" `
                    -Issue "Elevated CPU temperature: ${celsius}C" `
                    -Severity "Warning" `
                    -Recommendation "Check fans and ventilation" `
                    -Details "Temperature elevated but not critical"
            }
            else {
                $findings += & $script:NewFinding -Category "Thermal" `
                    -Issue "CPU temperature: ${celsius}C" `
                    -Severity "OK" `
                    -Recommendation "-"
            }
        }
        else {
            if ($Log) { & $Log "  Temperature sensor not accessible" }
        }
    }
    catch {
        if ($Log) { & $Log "  Temperature check not available" }
    }

    # If no findings at all, add OK
    if (-not ($findings | Where-Object { $_.Category -eq "Thermal" })) {
        $findings += & $script:NewFinding -Category "Thermal" `
            -Issue "CPU speed normal, temp unavailable" `
            -Severity "OK" `
            -Recommendation "-"
    }

    return $findings
}

$script:CollectSystemStability = {
    param([scriptblock]$Log)

    $findings = @()

    if ($Log) { & $Log "Checking system stability..." }

    try {
        # Check uptime
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $uptime = (Get-Date) - $os.LastBootUpTime

        if ($Log) { & $Log "  Uptime: $($uptime.Days) days, $($uptime.Hours) hours" }

        if ($uptime.TotalDays -gt 14) {
            $findings += & $script:NewFinding -Category "Stability" `
                -Issue "System uptime: $($uptime.Days) days" `
                -Severity "Warning" `
                -Recommendation "Schedule reboot - long uptime can cause memory leaks" `
                -Details "Last boot: $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'))"
        }
        elseif ($uptime.TotalDays -gt 7) {
            $findings += & $script:NewFinding -Category "Stability" `
                -Issue "System uptime: $($uptime.Days) days" `
                -Severity "Info" `
                -Recommendation "Consider rebooting if experiencing issues" `
                -Details "Last boot: $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'))"
        }
    }
    catch {
        if ($Log) { & $Log "  Uptime check failed: $($_.Exception.Message)" }
    }

    # Check for pending reboot
    try {
        $pendingReboot = $false
        $rebootReasons = @()

        # Component Based Servicing
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
            $pendingReboot = $true
            $rebootReasons += "Component Servicing"
        }

        # Windows Update
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
            $pendingReboot = $true
            $rebootReasons += "Windows Update"
        }

        # Pending file rename operations
        $pfro = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($pfro.PendingFileRenameOperations) {
            $pendingReboot = $true
            $rebootReasons += "File operations"
        }

        if ($pendingReboot) {
            $findings += & $script:NewFinding -Category "Stability" `
                -Issue "Pending reboot required" `
                -Severity "Warning" `
                -Recommendation "Reboot to complete pending updates/changes" `
                -Details "Pending: $($rebootReasons -join ', ')"

            if ($Log) { & $Log "  Pending reboot: Yes ($($rebootReasons -join ', '))" }
        }
        else {
            if ($Log) { & $Log "  Pending reboot: No" }
        }
    }
    catch {
        if ($Log) { & $Log "  Pending reboot check failed: $($_.Exception.Message)" }
    }

    # Check for BSOD minidumps
    try {
        $minidumpPath = "C:\Windows\Minidump"
        if (Test-Path $minidumpPath) {
            $recentDumps = @(Get-ChildItem $minidumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-30) })

            if ($recentDumps.Count -gt 0) {
                $findings += & $script:NewFinding -Category "Stability" `
                    -Issue "$($recentDumps.Count) crash dumps in last 30 days" `
                    -Severity "Warning" `
                    -Recommendation "Review minidumps with WinDbg or BlueScreenView" `
                    -Details "Path: $minidumpPath"

                if ($Log) { & $Log "  Recent crash dumps: $($recentDumps.Count)" }
            }
        }
    }
    catch {
        if ($Log) { & $Log "  Minidump check failed: $($_.Exception.Message)" }
    }

    # Win11: Check LiveKernelReports folder
    if ($script:IsWin11) {
        try {
            $lkrPath = "C:\Windows\LiveKernelReports"
            if (Test-Path $lkrPath) {
                $recentReports = @(Get-ChildItem $lkrPath -Recurse -Filter "*.dmp" -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-30) })

                if ($recentReports.Count -gt 0) {
                    $findings += & $script:NewFinding -Category "Stability" `
                        -Issue "$($recentReports.Count) live kernel dumps (recovered crashes)" `
                        -Severity "Warning" `
                        -Recommendation "System recovered from hangs - check GPU/driver issues" `
                        -Details "Path: $lkrPath"

                    if ($Log) { & $Log "  Live kernel reports: $($recentReports.Count)" }
                }
            }
        }
        catch {
            if ($Log) { & $Log "  LiveKernelReports check failed: $($_.Exception.Message)" }
        }
    }

    # Check Fast Startup status (can cause issues)
    try {
        $fastStartup = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled -ErrorAction SilentlyContinue
        if ($fastStartup.HiberbootEnabled -eq 1) {
            $findings += & $script:NewFinding -Category "Stability" `
                -Issue "Fast Startup enabled" `
                -Severity "Info" `
                -Recommendation "Fast Startup can cause driver issues - disable if problems persist" `
                -Details "Control Panel > Power Options > Choose what power buttons do"
        }
        if ($Log) { & $Log "  Fast Startup: $(if ($fastStartup.HiberbootEnabled -eq 1) {'Enabled'} else {'Disabled'})" }
    }
    catch {
        if ($Log) { & $Log "  Fast Startup check failed: $($_.Exception.Message)" }
    }

    # If no issues, add OK
    $stabilityIssues = $findings | Where-Object { $_.Category -eq "Stability" -and $_.Severity -ne "Info" }
    if ($stabilityIssues.Count -eq 0 -and -not ($findings | Where-Object { $_.Category -eq "Stability" })) {
        $findings += & $script:NewFinding -Category "Stability" `
            -Issue "System stable, no pending reboots" `
            -Severity "OK" `
            -Recommendation "-"
    }

    return $findings
}

$script:CollectResourceUsage = {
    param([scriptblock]$Log)

    $findings = @()

    if ($Log) { & $Log "Checking resource usage..." }

    try {
        # Current CPU usage
        $cpuCounter = Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue
        $cpuUsage = [math]::Round($cpuCounter.CounterSamples[0].CookedValue, 0)

        if ($Log) { & $Log "  CPU usage: $cpuUsage%" }

        # Disk queue length (I/O bottleneck)
        $diskQueue = Get-Counter '\PhysicalDisk(_Total)\Current Disk Queue Length' -ErrorAction SilentlyContinue
        $queueLength = [math]::Round($diskQueue.CounterSamples[0].CookedValue, 1)

        if ($Log) { & $Log "  Disk queue: $queueLength" }

        if ($queueLength -gt 2) {
            $findings += & $script:NewFinding -Category "Resources" `
                -Issue "High disk queue: $queueLength" `
                -Severity "Warning" `
                -Recommendation "Disk I/O bottleneck - check for heavy disk activity" `
                -Details "Normal is <2, high queue causes slowness"
        }

        # Top CPU processes
        $topCPU = Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 Name, @{N='CPU';E={[math]::Round($_.CPU,1)}}
        if ($Log) {
            & $Log "  Top CPU processes:"
            foreach ($proc in $topCPU) {
                & $Log "    - $($proc.Name): $($proc.CPU)s"
            }
        }

        # Top memory processes
        $topMem = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 Name, @{N='MemMB';E={[math]::Round($_.WorkingSet64/1MB,0)}}
        if ($Log) {
            & $Log "  Top memory processes:"
            foreach ($proc in $topMem) {
                & $Log "    - $($proc.Name): $($proc.MemMB) MB"
            }
        }

        # Check for runaway process (single process > 80% CPU)
        $cpuHogs = Get-Process | Where-Object { $_.CPU -gt 1000 } | Sort-Object CPU -Descending | Select-Object -First 1
        if ($cpuHogs) {
            $findings += & $script:NewFinding -Category "Resources" `
                -Issue "Process '$($cpuHogs.Name)' using high CPU" `
                -Severity "Info" `
                -Recommendation "Check if process is stuck or legitimately busy" `
                -Details "CPU time: $([math]::Round($cpuHogs.CPU, 0)) seconds"
        }
    }
    catch {
        if ($Log) { & $Log "  Resource check failed: $($_.Exception.Message)" }
    }

    # If no issues, add OK
    if (-not ($findings | Where-Object { $_.Category -eq "Resources" })) {
        $findings += & $script:NewFinding -Category "Resources" `
            -Issue "Resource usage normal" `
            -Severity "OK" `
            -Recommendation "-"
    }

    return $findings
}

#endregion

#region HP HPIA Integration

$script:RunHPIAAnalysis = {
    param([scriptblock]$Log)

    $findings = @()

    # Check if HP machine
    if (-not (& $script:DetectHP)) {
        if ($Log) { & $Log "Not an HP machine - skipping HPIA" }
        return $findings
    }

    $hpiaPath = & $script:GetHPIAPath
    if (-not $hpiaPath) {
        $findings += & $script:NewFinding -Category "HP Drivers" `
            -Issue "HPIA not installed" `
            -Severity "Info" `
            -Recommendation "Download HP Image Assistant for driver management" `
            -Details "Download from: https://ftp.hp.com/pub/caps-softpaq/cmit/HPIA.html"
        return $findings
    }

    if ($Log) { & $Log "Running HP Image Assistant analysis..." }

    $reportPath = "$env:TEMP\HPIA_Report"
    if (Test-Path $reportPath) { Remove-Item $reportPath -Recurse -Force }
    New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

    try {
        # Run HPIA in analyze-only mode
        $args = "/Operation:Analyze /Action:List /Category:Drivers /Silent /ReportFolder:`"$reportPath`""

        if ($Log) { & $Log "  Command: HPImageAssistant.exe $args" }

        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $hpiaPath
        $pinfo.Arguments = $args
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $pinfo
        $proc.Start() | Out-Null
        $proc.WaitForExit(120000)  # 2 minute timeout

        # Parse results
        $jsonReport = Get-ChildItem $reportPath -Filter "*.json" -Recurse | Select-Object -First 1

        if ($jsonReport) {
            $report = Get-Content $jsonReport.FullName -Raw | ConvertFrom-Json

            $outdated = @()
            if ($report.HPIA.Recommendations) {
                foreach ($rec in $report.HPIA.Recommendations) {
                    if ($rec.RecommendationValue -eq "Install") {
                        $outdated += $rec
                    }
                }
            }

            if ($outdated.Count -gt 0) {
                # Create individual finding for each driver with proper severity
                foreach ($driver in $outdated) {
                    # Map HPIA priority to our severity (Critical, Recommended, Routine)
                    $priority = if ($driver.CvaPackageInformation.Priority) { $driver.CvaPackageInformation.Priority } else { "Recommended" }
                    $severity = switch ($priority) {
                        "Critical" { "Critical" }
                        "Recommended" { "Warning" }
                        default { "Info" }  # Routine
                    }

                    $softpaqId = if ($driver.Id) { $driver.Id } else { "N/A" }
                    $version = if ($driver.Version) { $driver.Version } else { "N/A" }

                    $findings += & $script:NewFinding -Category "HP Drivers" `
                        -Issue "[$priority] $($driver.Name)" `
                        -Severity $severity `
                        -Recommendation "Install via HP Drivers menu" `
                        -Details "SoftPaq: $softpaqId | Version: $version"

                    if ($Log) { & $Log "  [$priority] $($driver.Name) - $softpaqId" }
                }

                # Summary finding
                $critCount = @($outdated | Where-Object { $_.CvaPackageInformation.Priority -eq "Critical" }).Count
                $recCount = @($outdated | Where-Object { $_.CvaPackageInformation.Priority -eq "Recommended" }).Count
                $routineCount = $outdated.Count - $critCount - $recCount

                if ($Log) { & $Log "  Summary: $critCount critical, $recCount recommended, $routineCount routine" }
            }
            else {
                $findings += & $script:NewFinding -Category "HP Drivers" `
                    -Issue "All HP drivers current" `
                    -Severity "OK" `
                    -Recommendation "-"

                if ($Log) { & $Log "  All drivers up to date" }
            }
        }
        else {
            if ($Log) { & $Log "  No HPIA report generated" }
        }
    }
    catch {
        if ($Log) { & $Log "  HPIA analysis failed: $($_.Exception.Message)" }
        $findings += & $script:NewFinding -Category "HP Drivers" `
            -Issue "HPIA analysis failed" `
            -Severity "Info" `
            -Recommendation "Run HPIA manually to check drivers" `
            -Details $_.Exception.Message
    }
    finally {
        # Cleanup
        if (Test-Path $reportPath) { Remove-Item $reportPath -Recurse -Force -ErrorAction SilentlyContinue }
    }

    return $findings
}

$script:RunHPIAUpdate = {
    param(
        [scriptblock]$Log,
        [PSCredential]$Credential,
        [ValidateSet("All", "Critical", "Recommended")]
        [string]$Selection = "All"
    )

    if (-not (& $script:DetectHP)) {
        [System.Windows.Forms.MessageBox]::Show("This is not an HP machine.", "Not HP", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $hpiaPath = & $script:GetHPIAPath
    if (-not $hpiaPath) {
        [System.Windows.Forms.MessageBox]::Show("HP Image Assistant is not installed.`n`nDownload from:`nhttps://ftp.hp.com/pub/caps-softpaq/cmit/HPIA.html", "HPIA Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    # Build selection description for confirmation dialog
    $selectionDesc = switch ($Selection) {
        "Critical" { "CRITICAL drivers only" }
        "Recommended" { "CRITICAL and RECOMMENDED drivers" }
        default { "ALL available drivers" }
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This will download and install $selectionDesc.`n`nThe system may require a reboot after updates.`n`nContinue?",
        "Install HP Driver Updates",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    if ($Log) { & $Log "Starting HP driver update (Selection: $Selection)..." }

    $reportPath = "$env:TEMP\HPIA_Update"
    if (Test-Path $reportPath) { Remove-Item $reportPath -Recurse -Force }
    New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

    try {
        # Build selection string - for "Recommended" we want Critical+Recommended
        $selectionArg = if ($Selection -eq "Recommended") { "Critical,Recommended" } else { $Selection }

        # Note: Skipping BIOS updates for safety
        $args = "/Operation:Analyze /Action:Install /Category:Drivers /Selection:$selectionArg /Silent /ReportFolder:`"$reportPath`""

        if ($Log) { & $Log "  Running HPIA with /Action:Install..." }

        # This may need elevation
        if ($Credential) {
            $result = Invoke-Elevated -ScriptBlock {
                param($path, $arguments)
                $pinfo = New-Object System.Diagnostics.ProcessStartInfo
                $pinfo.FileName = $path
                $pinfo.Arguments = $arguments
                $pinfo.UseShellExecute = $false
                $pinfo.CreateNoWindow = $true

                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $pinfo
                $proc.Start() | Out-Null
                $proc.WaitForExit(600000)  # 10 minute timeout for updates
                return $proc.ExitCode
            } -ArgumentList $hpiaPath, $args -Credential $Credential -OperationName "install HP drivers"

            if ($result.Success) {
                if ($Log) { & $Log "  HPIA update completed" }
                [System.Windows.Forms.MessageBox]::Show("HP driver updates completed.`n`nA reboot may be required.", "Update Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
            else {
                if ($Log) { & $Log "  HPIA update failed: $($result.Error)" }
                [System.Windows.Forms.MessageBox]::Show("HP driver update failed.`n`n$($result.Error)", "Update Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            }
        }
        else {
            # Try without elevation
            Start-Process -FilePath $hpiaPath -ArgumentList $args -Wait -NoNewWindow
            if ($Log) { & $Log "  HPIA update completed (non-elevated)" }
        }
    }
    catch {
        if ($Log) { & $Log "  HPIA update error: $($_.Exception.Message)" }
        [System.Windows.Forms.MessageBox]::Show("Error running HPIA: $($_.Exception.Message)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        if (Test-Path $reportPath) { Remove-Item $reportPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

#endregion

#region Export Report

$script:GenerateReport = {
    param($Findings)

    $sb = [System.Text.StringBuilder]::new()

    # Header
    [void]$sb.AppendLine("================================================================================")
    [void]$sb.AppendLine("RUSH RESOLVE DIAGNOSTIC REPORT")
    [void]$sb.AppendLine("================================================================================")

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue

        [void]$sb.AppendLine("Computer:   $env:COMPUTERNAME")
        [void]$sb.AppendLine("Model:      $($cs.Manufacturer) $($cs.Model)")
        [void]$sb.AppendLine("Serial:     $($bios.SerialNumber)")
    }
    catch { }

    [void]$sb.AppendLine("Date:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("Technician: $env:USERDOMAIN\$env:USERNAME")
    [void]$sb.AppendLine("================================================================================")
    [void]$sb.AppendLine("")

    # Summary counts
    $critical = @($Findings | Where-Object { $_.Severity -eq "Critical" })
    $warning = @($Findings | Where-Object { $_.Severity -eq "Warning" })
    $ok = @($Findings | Where-Object { $_.Severity -eq "OK" })

    [void]$sb.AppendLine("SUMMARY")
    [void]$sb.AppendLine("-------")
    [void]$sb.AppendLine("Critical:  $($critical.Count)")
    [void]$sb.AppendLine("Warning:   $($warning.Count)")
    [void]$sb.AppendLine("OK:        $($ok.Count)")
    [void]$sb.AppendLine("")

    # Critical findings
    if ($critical.Count -gt 0) {
        [void]$sb.AppendLine("CRITICAL FINDINGS")
        [void]$sb.AppendLine("-----------------")
        foreach ($f in $critical) {
            [void]$sb.AppendLine("[$($f.Category)] $($f.Issue)")
            [void]$sb.AppendLine("  -> $($f.Recommendation)")
            if ($f.Details) { [void]$sb.AppendLine("  -> $($f.Details)") }
            [void]$sb.AppendLine("")
        }
    }

    # Warning findings
    if ($warning.Count -gt 0) {
        [void]$sb.AppendLine("WARNING FINDINGS")
        [void]$sb.AppendLine("----------------")
        foreach ($f in $warning) {
            [void]$sb.AppendLine("[$($f.Category)] $($f.Issue)")
            [void]$sb.AppendLine("  -> $($f.Recommendation)")
            if ($f.Details) { [void]$sb.AppendLine("  -> $($f.Details)") }
            [void]$sb.AppendLine("")
        }
    }

    # OK categories
    if ($ok.Count -gt 0) {
        [void]$sb.AppendLine("OK CATEGORIES")
        [void]$sb.AppendLine("-------------")
        foreach ($f in $ok) {
            [void]$sb.AppendLine("[$($f.Category)] $($f.Issue)")
        }
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("================================================================================")
    [void]$sb.AppendLine("Generated by Rush Resolve Diagnostics Module")
    [void]$sb.AppendLine("================================================================================")

    return $sb.ToString()
}

#endregion

#region Module UI

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Main layout
    $mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $mainLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainLayout.RowCount = 4
    $mainLayout.ColumnCount = 1
    $mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 45))) | Out-Null   # Diagnostic buttons
    $mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60))) | Out-Null   # Quick Tools
    $mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 55))) | Out-Null    # Findings
    $mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 45))) | Out-Null    # Log

    #region Button Panel
    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(5)
    $buttonPanel.WrapContents = $false

    # Store references for closures
    $script:diagFindings = @()

    # Quick Check button
    $quickCheckBtn = New-Object System.Windows.Forms.Button
    $quickCheckBtn.Text = "Quick Check"
    $quickCheckBtn.AutoSize = $true
    $quickCheckBtn.Height = 30
    $quickCheckBtn.Add_Click({
        Start-AppActivity "Running quick diagnostic..."
        $script:diagLogBox.Clear()
        $script:diagListView.Items.Clear()
        $script:diagFindings = @()

        $logCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:diagLogBox.AppendText("[$ts] $Message`r`n")
            $script:diagLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        # Quick check: Events, Storage, Memory only
        $collectors = @(
            @{ Name = "Event Logs"; Script = $script:CollectEventErrors },
            @{ Name = "Storage"; Script = $script:CollectStorageHealth },
            @{ Name = "Memory"; Script = $script:CollectMemoryInfo }
        )

        $index = 0
        foreach ($collector in $collectors) {
            $index++
            Set-AppProgress -Value $index -Maximum $collectors.Count -Message "Checking $($collector.Name)..."
            $script:diagFindings += & $collector.Script -Log $logCallback
        }

        # Update ListView
        & $script:UpdateFindingsListView

        Clear-AppStatus
        & $logCallback "Quick check complete. Found $($script:diagFindings.Count) findings."
        Write-SessionLog -Message "Quick diagnostic: $(@($script:diagFindings | Where-Object {$_.Severity -eq 'Critical'}).Count) critical, $(@($script:diagFindings | Where-Object {$_.Severity -eq 'Warning'}).Count) warning" -Category "Diagnostics"
    })
    $buttonPanel.Controls.Add($quickCheckBtn)

    # Full Diagnostic button
    $fullDiagBtn = New-Object System.Windows.Forms.Button
    $fullDiagBtn.Text = "Full Diagnostic"
    $fullDiagBtn.AutoSize = $true
    $fullDiagBtn.Height = 30
    $fullDiagBtn.Add_Click({
        Start-AppActivity "Running full diagnostic..."
        $script:diagLogBox.Clear()
        $script:diagListView.Items.Clear()
        $script:diagFindings = @()

        $logCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:diagLogBox.AppendText("[$ts] $Message`r`n")
            $script:diagLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        # All collectors
        $collectors = @(
            @{ Name = "Event Logs"; Script = $script:CollectEventErrors },
            @{ Name = "Storage"; Script = $script:CollectStorageHealth },
            @{ Name = "Memory"; Script = $script:CollectMemoryInfo },
            @{ Name = "Drivers"; Script = $script:CollectDriverIssues },
            @{ Name = "Thermal"; Script = $script:CollectThermalData },
            @{ Name = "Stability"; Script = $script:CollectSystemStability },
            @{ Name = "Resources"; Script = $script:CollectResourceUsage }
        )

        # Add HP check if HP machine
        if (& $script:DetectHP) {
            $collectors += @{ Name = "HP Drivers"; Script = $script:RunHPIAAnalysis }
        }

        $index = 0
        foreach ($collector in $collectors) {
            $index++
            Set-AppProgress -Value $index -Maximum $collectors.Count -Message "Checking $($collector.Name)..."
            $script:diagFindings += & $collector.Script -Log $logCallback
        }

        # Update ListView
        & $script:UpdateFindingsListView

        Clear-AppStatus
        & $logCallback "Full diagnostic complete. Found $($script:diagFindings.Count) findings."
        Write-SessionLog -Message "Full diagnostic: $(@($script:diagFindings | Where-Object {$_.Severity -eq 'Critical'}).Count) critical, $(@($script:diagFindings | Where-Object {$_.Severity -eq 'Warning'}).Count) warning" -Category "Diagnostics"
    })
    $buttonPanel.Controls.Add($fullDiagBtn)

    # HP Drivers dropdown menu
    $hpDropdown = New-Object System.Windows.Forms.ToolStripDropDownButton
    $hpDropdown.Text = "HP Drivers"
    $hpDropdown.DisplayStyle = [System.Windows.Forms.ToolStripItemDisplayStyle]::Text

    # We'll use a regular button with context menu instead for simpler implementation
    $hpBtn = New-Object System.Windows.Forms.Button
    $hpBtn.Text = "HP Drivers..."
    $hpBtn.AutoSize = $true
    $hpBtn.Height = 30

    $hpMenu = New-Object System.Windows.Forms.ContextMenuStrip

    $hpCheckItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $hpCheckItem.Text = "Check Drivers"
    $hpCheckItem.Add_Click({
        if (-not (& $script:DetectHP)) {
            [System.Windows.Forms.MessageBox]::Show("This is not an HP machine.", "Not HP", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        Start-AppActivity "Checking HP drivers..."
        $script:diagLogBox.Clear()

        $logCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:diagLogBox.AppendText("[$ts] $Message`r`n")
            $script:diagLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $hpFindings = & $script:RunHPIAAnalysis -Log $logCallback

        # Add to existing findings or replace HP category
        $script:diagFindings = @($script:diagFindings | Where-Object { $_.Category -ne "HP Drivers" })
        $script:diagFindings += $hpFindings

        & $script:UpdateFindingsListView
        Clear-AppStatus
        & $logCallback "HP driver check complete."
    })
    $hpMenu.Items.Add($hpCheckItem) | Out-Null

    # Separator
    $hpMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Install All
    $hpInstallAllItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $hpInstallAllItem.Text = "Install All Drivers"
    $hpInstallAllItem.Add_Click({
        $logCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:diagLogBox.AppendText("[$ts] $Message`r`n")
            $script:diagLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $cred = Get-ElevatedCredential -Message "Enter admin credentials for HP driver updates"
        if ($cred) {
            & $script:RunHPIAUpdate -Log $logCallback -Credential $cred -Selection "All"
        }
    })
    $hpMenu.Items.Add($hpInstallAllItem) | Out-Null

    # Install Critical Only
    $hpInstallCriticalItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $hpInstallCriticalItem.Text = "Install Critical Only"
    $hpInstallCriticalItem.Add_Click({
        $logCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:diagLogBox.AppendText("[$ts] $Message`r`n")
            $script:diagLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $cred = Get-ElevatedCredential -Message "Enter admin credentials for HP driver updates"
        if ($cred) {
            & $script:RunHPIAUpdate -Log $logCallback -Credential $cred -Selection "Critical"
        }
    })
    $hpMenu.Items.Add($hpInstallCriticalItem) | Out-Null

    # Install Critical + Recommended
    $hpInstallRecItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $hpInstallRecItem.Text = "Install Critical + Recommended"
    $hpInstallRecItem.Add_Click({
        $logCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:diagLogBox.AppendText("[$ts] $Message`r`n")
            $script:diagLogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $cred = Get-ElevatedCredential -Message "Enter admin credentials for HP driver updates"
        if ($cred) {
            & $script:RunHPIAUpdate -Log $logCallback -Credential $cred -Selection "Recommended"
        }
    })
    $hpMenu.Items.Add($hpInstallRecItem) | Out-Null

    $hpBtn.Add_Click({
        $hpMenu.Show($hpBtn, [System.Drawing.Point]::new(0, $hpBtn.Height))
    })
    $buttonPanel.Controls.Add($hpBtn)

    # Separator
    $sep1 = New-Object System.Windows.Forms.Label
    $sep1.Text = " | "
    $sep1.AutoSize = $true
    $sep1.Padding = New-Object System.Windows.Forms.Padding(5, 8, 5, 0)
    $buttonPanel.Controls.Add($sep1)

    # Export button
    $exportBtn = New-Object System.Windows.Forms.Button
    $exportBtn.Text = "Export"
    $exportBtn.AutoSize = $true
    $exportBtn.Height = 30
    $exportBtn.Add_Click({
        if ($script:diagFindings.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No findings to export. Run a diagnostic first.", "No Data", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $report = & $script:GenerateReport -Findings $script:diagFindings
        [System.Windows.Forms.Clipboard]::SetText($report)

        [System.Windows.Forms.MessageBox]::Show("Diagnostic report copied to clipboard!`n`nPaste into ServiceNow or email.", "Report Copied", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)

        Write-SessionLog -Message "Diagnostic report exported to clipboard" -Category "Diagnostics"
    })
    $buttonPanel.Controls.Add($exportBtn)

    # Clear button
    $clearBtn = New-Object System.Windows.Forms.Button
    $clearBtn.Text = "Clear"
    $clearBtn.AutoSize = $true
    $clearBtn.Height = 30
    $clearBtn.Add_Click({
        $script:diagFindings = @()
        $script:diagListView.Items.Clear()
        $script:diagLogBox.Clear()
    })
    $buttonPanel.Controls.Add($clearBtn)

    # Memory Test shortcut
    $sep2 = New-Object System.Windows.Forms.Label
    $sep2.Text = " | "
    $sep2.AutoSize = $true
    $sep2.Padding = New-Object System.Windows.Forms.Padding(5, 8, 5, 0)
    $buttonPanel.Controls.Add($sep2)

    $memTestBtn = New-Object System.Windows.Forms.Button
    $memTestBtn.Text = "Memory Test"
    $memTestBtn.AutoSize = $true
    $memTestBtn.Height = 30
    $memTestBtn.Add_Click({
        $msg = "Windows Memory Diagnostic will check your RAM for errors.`n`nThe computer must restart to run the test.`n`nSchedule memory test?"
        $confirm = [System.Windows.Forms.MessageBox]::Show($msg, "Memory Diagnostic", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-SessionLog -Message "Memory Diagnostic scheduled via Diagnostics module" -Category "Diagnostics"
            Start-ElevatedProcess -FilePath "mdsched.exe" -OperationName "schedule Memory Diagnostic"
        }
    })
    $buttonPanel.Controls.Add($memTestBtn)

    $mainLayout.Controls.Add($buttonPanel, 0, 0)
    #endregion

    #region Quick Tools Panel
    $quickToolsGroup = New-Object System.Windows.Forms.GroupBox
    $quickToolsGroup.Text = "Quick Tools"
    $quickToolsGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $quickToolsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $quickToolsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $quickToolsPanel.Padding = New-Object System.Windows.Forms.Padding(5, 2, 5, 2)
    $quickToolsPanel.WrapContents = $false

    # Check Disk button
    $chkdskBtn = New-Object System.Windows.Forms.Button
    $chkdskBtn.Text = "Check Disk"
    $chkdskBtn.AutoSize = $true
    $chkdskBtn.Height = 30
    $chkdskBtn.Add_Click({
        $msg = "Check Disk (chkdsk /f /r) requires a reboot for the system drive.`n`nSchedule disk check on next restart?"
        $confirm = [System.Windows.Forms.MessageBox]::Show($msg, "Schedule Check Disk", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $ts = Get-Date -Format "HH:mm:ss"
            $script:diagLogBox.AppendText("[$ts] Scheduling chkdsk /f /r for C: on next reboot...`r`n")
            Write-SessionLog -Message "Scheduled chkdsk /f /r via Diagnostics Quick Tools" -Category "Diagnostics"
            # Schedule chkdsk - requires elevation
            $cred = Get-ElevatedCredential -Message "Enter admin credentials to schedule Check Disk"
            if ($cred) {
                $result = Invoke-Elevated -ScriptBlock {
                    # Schedule chkdsk on next boot
                    $output = & cmd /c "echo Y | chkdsk C: /f /r" 2>&1
                    return $output
                } -Credential $cred -OperationName "schedule Check Disk"
                if ($result.Success) {
                    [System.Windows.Forms.MessageBox]::Show("Check Disk scheduled.`nReboot to run the disk check.", "Scheduled", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                }
            }
        }
    })
    $quickToolsPanel.Controls.Add($chkdskBtn)

    # SFC button
    $sfcBtn = New-Object System.Windows.Forms.Button
    $sfcBtn.Text = "SFC Scan"
    $sfcBtn.AutoSize = $true
    $sfcBtn.Height = 30
    $sfcBtn.Add_Click({
        $ts = Get-Date -Format "HH:mm:ss"
        $script:diagLogBox.AppendText("[$ts] Launching System File Checker (sfc /scannow)...`r`n")
        Write-SessionLog -Message "Launched SFC via Diagnostics Quick Tools" -Category "Diagnostics"
        $cred = Get-ElevatedCredential -Message "Enter admin credentials for System File Checker"
        if ($cred) {
            Invoke-Elevated -ScriptBlock {
                Start-Process "powershell.exe" -ArgumentList "-NoExit", "-Command", "Write-Host 'Running System File Checker...' -ForegroundColor Cyan; sfc /scannow; Write-Host '`nSFC Complete. Review results above.' -ForegroundColor Green; pause" -Wait
            } -Credential $cred -OperationName "run SFC scan"
        }
    })
    $quickToolsPanel.Controls.Add($sfcBtn)

    # DISM button
    $dismBtn = New-Object System.Windows.Forms.Button
    $dismBtn.Text = "DISM Repair"
    $dismBtn.AutoSize = $true
    $dismBtn.Height = 30
    $dismBtn.Add_Click({
        $ts = Get-Date -Format "HH:mm:ss"
        $script:diagLogBox.AppendText("[$ts] Launching DISM RestoreHealth (this may take 10-20 minutes)...`r`n")
        Write-SessionLog -Message "Launched DISM repair via Diagnostics Quick Tools" -Category "Diagnostics"
        $cred = Get-ElevatedCredential -Message "Enter admin credentials for DISM Repair"
        if ($cred) {
            Invoke-Elevated -ScriptBlock {
                Start-Process "powershell.exe" -ArgumentList "-NoExit", "-Command", "Write-Host 'Running DISM RestoreHealth (this may take 10-20 minutes)...' -ForegroundColor Cyan; DISM /Online /Cleanup-Image /RestoreHealth; Write-Host '`nDISM Complete. Review results above.' -ForegroundColor Green; pause" -Wait
            } -Credential $cred -OperationName "run DISM repair"
        }
    })
    $quickToolsPanel.Controls.Add($dismBtn)

    # Separator
    $toolSep1 = New-Object System.Windows.Forms.Label
    $toolSep1.Text = "|"
    $toolSep1.AutoSize = $true
    $toolSep1.Padding = New-Object System.Windows.Forms.Padding(3, 6, 3, 0)
    $quickToolsPanel.Controls.Add($toolSep1)

    # Disk Cleanup button (no elevation needed)
    $cleanupBtn = New-Object System.Windows.Forms.Button
    $cleanupBtn.Text = "Disk Cleanup"
    $cleanupBtn.AutoSize = $true
    $cleanupBtn.Height = 30
    $cleanupBtn.Add_Click({
        $ts = Get-Date -Format "HH:mm:ss"
        $script:diagLogBox.AppendText("[$ts] Launching Disk Cleanup...`r`n")
        Write-SessionLog -Message "Launched Disk Cleanup via Diagnostics Quick Tools" -Category "Diagnostics"
        Start-ElevatedProcess -FilePath "cleanmgr.exe" -ArgumentList "/d C:" -OperationName "open Disk Cleanup"
    })
    $quickToolsPanel.Controls.Add($cleanupBtn)

    # Event Viewer button
    $eventViewerBtn = New-Object System.Windows.Forms.Button
    $eventViewerBtn.Text = "Event Viewer"
    $eventViewerBtn.AutoSize = $true
    $eventViewerBtn.Height = 30
    $eventViewerBtn.Add_Click({
        $ts = Get-Date -Format "HH:mm:ss"
        $script:diagLogBox.AppendText("[$ts] Opening Event Viewer...`r`n")
        Write-SessionLog -Message "Opened Event Viewer via Diagnostics Quick Tools" -Category "Diagnostics"
        Start-ElevatedProcess -FilePath "mmc.exe" -ArgumentList "eventvwr.msc" -OperationName "open Event Viewer"
    })
    $quickToolsPanel.Controls.Add($eventViewerBtn)

    # Device Manager button
    $devMgrBtn = New-Object System.Windows.Forms.Button
    $devMgrBtn.Text = "Device Manager"
    $devMgrBtn.AutoSize = $true
    $devMgrBtn.Height = 30
    $devMgrBtn.Add_Click({
        $ts = Get-Date -Format "HH:mm:ss"
        $script:diagLogBox.AppendText("[$ts] Opening Device Manager...`r`n")
        Write-SessionLog -Message "Opened Device Manager via Diagnostics Quick Tools" -Category "Diagnostics"
        Start-ElevatedProcess -FilePath "mmc.exe" -ArgumentList "devmgmt.msc" -OperationName "open Device Manager"
    })
    $quickToolsPanel.Controls.Add($devMgrBtn)

    # Reliability Monitor button
    $reliabilityBtn = New-Object System.Windows.Forms.Button
    $reliabilityBtn.Text = "Reliability"
    $reliabilityBtn.AutoSize = $true
    $reliabilityBtn.Height = 30
    $reliabilityBtn.Add_Click({
        $ts = Get-Date -Format "HH:mm:ss"
        $script:diagLogBox.AppendText("[$ts] Opening Reliability Monitor...`r`n")
        Write-SessionLog -Message "Opened Reliability Monitor via Diagnostics Quick Tools" -Category "Diagnostics"
        Start-ElevatedProcess -FilePath "perfmon.exe" -ArgumentList "/rel" -OperationName "open Reliability Monitor"
    })
    $quickToolsPanel.Controls.Add($reliabilityBtn)

    $quickToolsGroup.Controls.Add($quickToolsPanel)
    $mainLayout.Controls.Add($quickToolsGroup, 0, 1)
    #endregion

    #region Findings ListView
    $findingsGroup = New-Object System.Windows.Forms.GroupBox
    $findingsGroup.Text = "Findings"
    $findingsGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:diagListView = New-Object System.Windows.Forms.ListView
    $script:diagListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:diagListView.View = [System.Windows.Forms.View]::Details
    $script:diagListView.FullRowSelect = $true
    $script:diagListView.GridLines = $true
    $script:diagListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:diagListView.Columns.Add("", 25) | Out-Null  # Status icon
    $script:diagListView.Columns.Add("Category", 90) | Out-Null
    $script:diagListView.Columns.Add("Issue", 280) | Out-Null
    $script:diagListView.Columns.Add("Severity", 70) | Out-Null
    $script:diagListView.Columns.Add("Recommendation", 300) | Out-Null

    # Double-click to show details
    $script:diagListView.Add_DoubleClick({
        $selected = $script:diagListView.SelectedItems
        if ($selected.Count -gt 0) {
            $finding = $selected[0].Tag
            if ($finding -and $finding.Details) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Category: $($finding.Category)`n`nIssue: $($finding.Issue)`n`nSeverity: $($finding.Severity)`n`nRecommendation: $($finding.Recommendation)`n`nDetails:`n$($finding.Details)",
                    "Finding Details",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            }
        }
    })

    $findingsGroup.Controls.Add($script:diagListView)
    $mainLayout.Controls.Add($findingsGroup, 0, 2)
    #endregion

    #region Log TextBox
    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = "Log"
    $logGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:diagLogBox = New-Object System.Windows.Forms.TextBox
    $script:diagLogBox.Multiline = $true
    $script:diagLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:diagLogBox.ReadOnly = $true
    $script:diagLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:diagLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:diagLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:diagLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $logGroup.Controls.Add($script:diagLogBox)
    $mainLayout.Controls.Add($logGroup, 0, 3)
    #endregion

    $tab.Controls.Add($mainLayout)
}

#endregion
