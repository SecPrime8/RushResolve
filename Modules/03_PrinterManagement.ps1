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
    "\\RUDWV-PS401"        # Primary RMC print server - only server we use
)

# Load default server from settings (must be in allowlist)
$script:PrintServer = Get-ModuleSetting -ModuleName "PrinterManagement" -Key "defaultServer" -Default "\\RUDWV-PS401"
# Validate default is in allowlist
if ($script:PrintServer -and $script:AllowedPrintServers -notcontains $script:PrintServer) {
    $script:PrintServer = $script:AllowedPrintServers[0]
}
$script:PrinterBackupShare = "\\rush.edu\vdi\apphub\tools\NetworkPrinters"

# Host profile shares (populated by the legacy Excel macro "Create Printer Text Files")
# XA is install-ready (full UNC per line) and is the default read/install target.
$script:ProfileShareXA     = "\\rush.edu\VDI\Personal\_PrinterMappingsXA"
$script:ProfileSharePlain  = "\\rush.edu\VDI\Personal\_PrinterMappings"
$script:ProfileShareAppHub = "\\rush.edu\vdi\AppHub\Tools\NetworkPrinters"
# Default server prefix for Plain-format rows (matches the Excel macro's hardcoded svrText)
$script:ProfileDefaultServerPrefix = "\\RUDWV-PS401.rush.edu"
#endregion

#region Security Functions
# NOTE: must be a $script: block, not a plain function. The loader dot-sources
# each module INSIDE a function, so a top-level function is gone by the time a
# WinForms handler fires. As a plain function this made "Refresh && Install" a
# silent dead end: it confirmed, then threw CommandNotFoundException into the
# handler, which WinForms swallowed.
$script:TestPrinterPathAllowed = {
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
# Uses background jobs + DoEvents polling to keep UI responsive on Windows 10
$script:GetServerPrinters = {
    param([string]$Server)

    $printers = @()
    $serverName = $Server.TrimStart('\')

    # Quick connectivity check using .NET Ping with built-in 2s timeout (non-blocking)
    Start-AppActivity "Testing connection to $serverName..."
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($serverName, 2000)
        if ($reply.Status -ne 'Success') {
            Write-SessionLog -Message "Print server $serverName is unreachable (ping: $($reply.Status))" -Category "Printer Management"
            return @()
        }
    }
    catch {
        Write-SessionLog -Message "Cannot reach print server $serverName - $($_.Exception.Message)" -Category "Printer Management"
        return @()
    }

    # Helper: Run a job with DoEvents polling and timeout
    # Returns job output or $null on timeout/failure
    $runWithTimeout = {
        param([scriptblock]$JobScript, [object[]]$JobArgs, [string]$Label, [int]$TimeoutSeconds = 15)
        Start-AppActivity "$Label..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $job = Start-Job -ScriptBlock $JobScript -ArgumentList $JobArgs
            $start = Get-Date
            while ($job.State -eq 'Running') {
                Start-Sleep -Milliseconds 200
                [System.Windows.Forms.Application]::DoEvents()
                if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSeconds) {
                    Stop-Job $job -ErrorAction SilentlyContinue
                    Remove-Job $job -Force -ErrorAction SilentlyContinue
                    return $null
                }
            }
            $output = Receive-Job $job -ErrorAction Stop
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            return $output
        }
        catch {
            if ($job) { Remove-Job $job -Force -ErrorAction SilentlyContinue }
            return $null
        }
    }

    # Method 1: Try Get-Printer cmdlet (requires Print Management) - Skip if not available
    if ($script:HasPrintManagement) {
        $getPrinterScript = {
            param($s)
            Get-Printer -ComputerName $s -ErrorAction Stop | Where-Object { $_.Shared } |
                ForEach-Object {
                    $shareName = if ($_.ShareName) { $_.ShareName } else { $_.Name }
                    [PSCustomObject]@{
                        Name = $_.Name; ShareName = $shareName
                        Location = $_.Location; Comment = $_.Comment; DriverName = $_.DriverName
                    }
                }
        }
        $jobOutput = & $runWithTimeout $getPrinterScript @($serverName) "Querying printers via Get-Printer" 15
        if ($jobOutput) {
            foreach ($p in $jobOutput) {
                $printers += @{
                    Name = $p.Name; ShareName = $p.ShareName
                    FullPath = "\\$serverName\$($p.ShareName)"
                    Location = $p.Location; Comment = $p.Comment; DriverName = $p.DriverName
                }
            }
            if ($printers.Count -gt 0) {
                return $printers | Sort-Object { $_.Name }
            }
        }
    }

    # Method 2: Try WMI (older but often works)
    $wmiScript = {
        param($s)
        Get-WmiObject -Class Win32_Printer -ComputerName $s -ErrorAction Stop |
            Where-Object { $_.Shared -eq $true } |
            ForEach-Object {
                $shareName = if ($_.ShareName) { $_.ShareName } else { $_.Name }
                [PSCustomObject]@{
                    Name = $_.Name; ShareName = $shareName
                    Location = $_.Location; Comment = $_.Comment; DriverName = $_.DriverName
                }
            }
    }
    $jobOutput = & $runWithTimeout $wmiScript @($serverName) "Querying printers via WMI" 15
    if ($jobOutput) {
        foreach ($p in $jobOutput) {
            $printers += @{
                Name = $p.Name; ShareName = $p.ShareName
                FullPath = "\\$serverName\$($p.ShareName)"
                Location = $p.Location; Comment = $p.Comment; DriverName = $p.DriverName
            }
        }
        if ($printers.Count -gt 0) {
            return $printers | Sort-Object { $_.Name }
        }
    }

    # Method 3: Enumerate shared printers via net view (most compatible)
    $netViewScript = {
        param($s)
        $netOutput = net view "\\$s" 2>&1
        $results = @()
        $lines = $netOutput -split "`n"
        foreach ($line in $lines) {
            if ($line -match "Print") {
                $parts = $line -split '\s{2,}'
                if ($parts.Count -ge 1) {
                    $shareName = $parts[0].Trim()
                    $comment = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }
                    if ($shareName -and $shareName -ne "") {
                        $results += [PSCustomObject]@{
                            Name = $shareName; ShareName = $shareName
                            Location = ""; Comment = $comment; DriverName = ""
                        }
                    }
                }
            }
        }
        return $results
    }
    $jobOutput = & $runWithTimeout $netViewScript @($serverName) "Querying printers via net view" 15
    if ($jobOutput) {
        foreach ($p in $jobOutput) {
            $printers += @{
                Name = $p.Name; ShareName = $p.ShareName
                FullPath = "\\$serverName\$($p.ShareName)"
                Location = $p.Location; Comment = $p.Comment; DriverName = $p.DriverName
            }
        }
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

# Add network printer for ALL users (requires elevation via UAC RunAs)
# Uses printui.dll /ga to add per-machine printer connection
# Triggers a single UAC prompt instead of credential-based elevation (fixes Win10 "privilege not held" error)
$script:AddNetworkPrinterAllUsers = {
    param([string]$PrinterPath)

    try {
        # Use -Verb RunAs for UAC elevation (same pattern as Module 7 DISM tools)
        # Fire-and-forget: current user already has the printer, this just persists for all users
        Start-Process -FilePath "rundll32.exe" `
            -ArgumentList "printui.dll,PrintUIEntry /ga /n`"$PrinterPath`"" `
            -Verb RunAs -WindowStyle Hidden

        [System.Windows.Forms.Application]::DoEvents()
        return @{ Success = $true; Error = $null }
    }
    catch {
        # User cancelled UAC prompt or other error
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
        $printer = Get-WmiObject -Query "SELECT * FROM Win32_Printer WHERE Name='$($PrinterName -replace '\\','\\\\')'" -ErrorAction Stop
        if ($printer) {
            $printer.PrintTestPage() | Out-Null
        }
        return @{ Success = $true; Error = $null }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}


# ---------------- Host profile (per-host printer file) helpers ----------------

# Parse a single raw line from a host profile text file into a row hashtable.
# Returns $null if the line is blank / junk / the literal "ComputerHostName" placeholder.
$script:ParseProfileLine = {
    param([string]$Line)

    if ($null -eq $Line) { return $null }
    # Strip CRs and stray NUL bytes (mis-decoded UTF-16 leftovers), then trim
    $trimmed = ($Line -replace "`r", "" -replace "`0", "").Trim()
    if (-not $trimmed) { return $null }
    if ($trimmed -ieq "ComputerHostName") { return $null }

    $isDefault = $false
    if ($trimmed -match '=default\s*$') {
        $isDefault = $true
        $trimmed = ($trimmed -replace '=default\s*$', '').Trim()
    }
    if (-not $trimmed) { return $null }

    if ($trimmed.StartsWith('\\')) {
        $fullPath = $trimmed
        $name = $null
        if ($trimmed -match '^\\\\[^\\]+\\(.+)$') { $name = $Matches[1] }
        if (-not $name) { return $null }
    }
    else {
        $name = $trimmed
        $fullPath = "$($script:ProfileDefaultServerPrefix)\$name"
    }

    return @{
        FullPath    = $fullPath
        Name        = $name
        IsDefault   = $isDefault
        IsPending   = $false
        Status      = "Unknown"
        BrowsedFrom = $null  # set when row added from Browse pane
    }
}

# Read a profile file with encoding detection. The legacy Excel macro (VBA)
# writes files whose encoding varies (ANSI, UTF-16 with/without BOM); reading
# UTF-16 as UTF-8 turns the whole file into one garbled line, which is why
# profiles "with a printer listed" used to render empty.
$script:ReadProfileText = {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return "" }

    # BOM detection
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }

    # No BOM: NUL bytes betray UTF-16. Odd-index NULs = little endian.
    if ($bytes -contains 0) {
        $nullAtOdd = $false
        $scanLimit = [Math]::Min($bytes.Length, 200)
        for ($i = 1; $i -lt $scanLimit; $i += 2) {
            if ($bytes[$i] -eq 0) { $nullAtOdd = $true; break }
        }
        if ($nullAtOdd) {
            return [System.Text.Encoding]::Unicode.GetString($bytes)
        }
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes)
    }

    # Plain bytes: ANSI (legacy default; identical to UTF-8 for ASCII names)
    return [System.Text.Encoding]::Default.GetString($bytes)
}

# Load the host profile file, trying the XA share first, then Plain, then
# AppHub (a host's file sometimes exists on only one share). Returns:
#   @{ Success; Rows; LastWriteTime; Path; Reason; Share; UnparsedLines }
# Reason is one of: Loaded / NotFound / ShareUnreachable / Error.
$script:LoadProfile = {
    param([string]$Hostname)

    $shares = @(
        @{ Name = "XA";     Dir = $script:ProfileShareXA },
        @{ Name = "Plain";  Dir = $script:ProfileSharePlain },
        @{ Name = "AppHub"; Dir = $script:ProfileShareAppHub }
    )

    $res = @{
        Success       = $false
        Rows          = @()
        LastWriteTime = $null
        Path          = (Join-Path $script:ProfileShareXA "$Hostname.txt")
        Reason        = "Error"
        Share         = $null
        UnparsedLines = @()
        ShareStatus   = ""
    }

    # Find the host's file on the first share that has it
    $anyShareReachable = $false
    $foundFile = $null
    $shareStatus = @()
    foreach ($s in $shares) {
        if (-not (Test-Path $s.Dir -ErrorAction SilentlyContinue)) {
            $shareStatus += "$($s.Name)=unreachable"
            continue
        }
        $anyShareReachable = $true
        $candidate = Join-Path $s.Dir "$Hostname.txt"
        if (Test-Path $candidate -ErrorAction SilentlyContinue) {
            $foundFile = $candidate
            $res.Share = $s.Name
            $shareStatus += "$($s.Name)=found"
            break
        }
        $shareStatus += "$($s.Name)=no-file"
    }
    $res.ShareStatus = $shareStatus -join ", "

    if (-not $anyShareReachable) {
        $res.Reason = "ShareUnreachable"
        return $res
    }

    if (-not $foundFile) {
        $res.Reason = "NotFound"
        # still "success" from a control-flow standpoint - the pane just shows empty
        $res.Success = $true
        return $res
    }

    $res.Path = $foundFile

    try {
        $fi = Get-Item -Path $foundFile -ErrorAction Stop
        $res.LastWriteTime = $fi.LastWriteTime

        $text = & $script:ReadProfileText -Path $foundFile
        $rows = @()
        $unparsed = @()
        foreach ($line in ($text -split "`r?`n")) {
            $row = & $script:ParseProfileLine -Line $line
            if ($row) {
                $rows += $row
            }
            else {
                # Surface real content we couldn't parse instead of dropping it silently
                $cleaned = ($line -replace "`0", "").Trim()
                if ($cleaned -and $cleaned -ine "ComputerHostName") {
                    $unparsed += $cleaned
                }
            }
        }
        $res.Rows = $rows
        $res.UnparsedLines = $unparsed
        $res.Success = $true
        $res.Reason = "Loaded"
    }
    catch {
        $res.Reason = "Error: $($_.Exception.Message)"
    }
    return $res
}

# Format profile rows into lines for a specific share layout.
# Format: "XA" | "Plain" | "AppHub"
$script:FormatProfileLines = {
    param([array]$Rows, [string]$Format)

    $lines = @()
    foreach ($r in $Rows) {
        $suffix = if ($r.IsDefault) { "=default" } else { "" }
        switch ($Format) {
            "Plain" { $lines += "$($r.Name)$suffix" }
            default {
                # XA and AppHub both get the \\RUDWV-PS401.rush.edu\<name> form.
                # (AppHub ends up XA-formatted because the macro's second write wins.)
                $lines += "$($script:ProfileDefaultServerPrefix)\$($r.Name)$suffix"
            }
        }
    }
    return $lines
}

# Save profile rows to all three shares for a host.
# Returns @{ Results = @(@{ Share; Path; Success; Error }); LastWriteTime = <fresh XA stamp> }
$script:SaveProfile = {
    param([string]$Hostname, [array]$Rows)

    $writeTargets = @(
        @{ Share = "XA";     Format = "XA";     Dir = $script:ProfileShareXA },
        @{ Share = "Plain";  Format = "Plain";  Dir = $script:ProfileSharePlain },
        @{ Share = "AppHub"; Format = "AppHub"; Dir = $script:ProfileShareAppHub }
    )

    $results = @()
    foreach ($t in $writeTargets) {
        $entry = @{
            Share   = $t.Share
            Path    = (Join-Path $t.Dir "$Hostname.txt")
            Success = $false
            Error   = $null
        }
        try {
            if (-not (Test-Path $t.Dir -ErrorAction SilentlyContinue)) {
                throw "Share not reachable: $($t.Dir)"
            }
            $lines = & $script:FormatProfileLines -Rows $Rows -Format $t.Format
            # Write as UTF-8 without BOM to stay compatible with the legacy files.
            $content = ($lines -join "`r`n")
            [System.IO.File]::WriteAllText($entry.Path, $content + "`r`n", (New-Object System.Text.UTF8Encoding $false))
            $entry.Success = $true
        }
        catch {
            $entry.Error = $_.Exception.Message
        }
        $results += $entry
    }

    $stamp = $null
    $xaResult = $results | Where-Object { $_.Share -eq "XA" } | Select-Object -First 1
    if ($xaResult -and $xaResult.Success) {
        try { $stamp = (Get-Item -Path $xaResult.Path -ErrorAction Stop).LastWriteTime } catch {}
    }

    return @{ Results = $results; LastWriteTime = $stamp }
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

    # Main layout - three columns via nested SplitContainers, plus an activity
    # log docked at the bottom.  Outer table: top row = panes, bottom row = log.
    $script:rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $script:rootLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:rootLayout.RowCount = 2
    $script:rootLayout.ColumnCount = 1
    $script:rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $script:rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 120))) | Out-Null

    # Outer split: Installed | (Profile | Browse)
    $script:splitContainer = New-Object System.Windows.Forms.SplitContainer
    $script:splitContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:splitContainer.Orientation = [System.Windows.Forms.Orientation]::Vertical
    $script:splitContainer.Panel1MinSize = 100
    $script:splitContainer.Panel2MinSize = 100

    # Inner split: Profile | Browse (sits inside outer Panel2)
    $script:splitContainerInner = New-Object System.Windows.Forms.SplitContainer
    $script:splitContainerInner.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:splitContainerInner.Orientation = [System.Windows.Forms.Orientation]::Vertical
    $script:splitContainerInner.Panel1MinSize = 100
    $script:splitContainerInner.Panel2MinSize = 100

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
    $refreshInstalledBtn.Height = 30
    $refreshInstalledBtn.Width = $refreshInstalledBtn.PreferredSize.Width + 6
    $installedBtnPanel.Controls.Add($refreshInstalledBtn)

    $setDefaultBtn = New-Object System.Windows.Forms.Button
    $setDefaultBtn.Text = "Set Default"
    $setDefaultBtn.Height = 30
    $setDefaultBtn.Width = $setDefaultBtn.PreferredSize.Width + 6
    $installedBtnPanel.Controls.Add($setDefaultBtn)

    $testPrintBtn = New-Object System.Windows.Forms.Button
    $testPrintBtn.Text = "Test Page"
    $testPrintBtn.Height = 30
    $testPrintBtn.Width = $testPrintBtn.PreferredSize.Width + 6
    $installedBtnPanel.Controls.Add($testPrintBtn)

    $clearQueueBtn = New-Object System.Windows.Forms.Button
    $clearQueueBtn.Text = "Clear Queue"
    $clearQueueBtn.Height = 30
    $clearQueueBtn.Width = $clearQueueBtn.PreferredSize.Width + 6
    $installedBtnPanel.Controls.Add($clearQueueBtn)

    $removeBtn = New-Object System.Windows.Forms.Button
    $removeBtn.Text = "Remove"
    $removeBtn.Height = 30
    $removeBtn.Width = $removeBtn.PreferredSize.Width + 6
    $removeBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 230)
    $installedBtnPanel.Controls.Add($removeBtn)

    # Backup button
    $backupBtn = New-Object System.Windows.Forms.Button
    $backupBtn.Text = "Backup"
    $backupBtn.Height = 30
    $backupBtn.Width = $backupBtn.PreferredSize.Width + 6
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
    $restoreBtn.Height = 30
    $restoreBtn.Width = $restoreBtn.PreferredSize.Width + 6
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

                    # Refresh installed printer list.
                    # NOTE: was $refreshInstalledBtn.PerformClick(). That button is a
                    # local of Initialize-Module and is $null inside this handler, so
                    # it threw AFTER the success dialog - Restore reported failure
                    # having actually succeeded.
                    & $script:RefreshInstalledPrinters
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

    #region Middle Panel - Host Profile
    $profilePanel = New-Object System.Windows.Forms.TableLayoutPanel
    $profilePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $profilePanel.RowCount = 3
    $profilePanel.ColumnCount = 1
    $profilePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
    $profilePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $profilePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 70))) | Out-Null

    $script:profileLabel = New-Object System.Windows.Forms.Label
    $script:profileLabel.Text = "Profile for $env:COMPUTERNAME"
    $script:profileLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:profileLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:profileLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $profilePanel.Controls.Add($script:profileLabel, 0, 0)

    $script:profileListView = New-Object System.Windows.Forms.ListView
    $script:profileListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:profileListView.View = [System.Windows.Forms.View]::Details
    $script:profileListView.FullRowSelect = $true
    $script:profileListView.GridLines = $true
    $script:profileListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:profileListView.Columns.Add("Printer", 180) | Out-Null
    $script:profileListView.Columns.Add("Default", 55) | Out-Null
    $script:profileListView.Columns.Add("Status", 90) | Out-Null
    $profilePanel.Controls.Add($script:profileListView, 0, 1)

    $profileBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $profileBtnPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $profileBtnPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)

    $script:profileReloadBtn = New-Object System.Windows.Forms.Button
    $script:profileReloadBtn.Text = "Reload"
    $script:profileReloadBtn.Height = 30
    $script:profileReloadBtn.Width = $script:profileReloadBtn.PreferredSize.Width + 6
    $profileBtnPanel.Controls.Add($script:profileReloadBtn)

    $script:profileSaveBtn = New-Object System.Windows.Forms.Button
    $script:profileSaveBtn.Text = "Save Profile"
    $script:profileSaveBtn.Height = 30
    $script:profileSaveBtn.Width = $script:profileSaveBtn.PreferredSize.Width + 6
    $script:profileSaveBtn.Enabled = $false
    $profileBtnPanel.Controls.Add($script:profileSaveBtn)

    $script:profileInstallBtn = New-Object System.Windows.Forms.Button
    $script:profileInstallBtn.Text = "Refresh && Install"
    $script:profileInstallBtn.Height = 30
    $script:profileInstallBtn.Width = $script:profileInstallBtn.PreferredSize.Width + 6
    $script:profileInstallBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 255, 230)
    $profileBtnPanel.Controls.Add($script:profileInstallBtn)

    $script:profileRemoveBtn = New-Object System.Windows.Forms.Button
    $script:profileRemoveBtn.Text = "Remove"
    $script:profileRemoveBtn.Height = 30
    $script:profileRemoveBtn.Width = $script:profileRemoveBtn.PreferredSize.Width + 6
    $profileBtnPanel.Controls.Add($script:profileRemoveBtn)

    $script:profileMarkDefaultBtn = New-Object System.Windows.Forms.Button
    $script:profileMarkDefaultBtn.Text = "Mark Default"
    $script:profileMarkDefaultBtn.Height = 30
    $script:profileMarkDefaultBtn.Width = $script:profileMarkDefaultBtn.PreferredSize.Width + 6
    $profileBtnPanel.Controls.Add($script:profileMarkDefaultBtn)

    # Create a profile for a host that has none, from this machine's printers
    $script:profileNewFromInstalledBtn = New-Object System.Windows.Forms.Button
    $script:profileNewFromInstalledBtn.Text = "New from Installed"
    $script:profileNewFromInstalledBtn.Height = 30
    $script:profileNewFromInstalledBtn.Width = $script:profileNewFromInstalledBtn.PreferredSize.Width + 6
    $script:profileNewFromInstalledBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 220)
    $profileBtnPanel.Controls.Add($script:profileNewFromInstalledBtn)

    # Look up ANY computer's profile by hostname (defaults to this machine)
    $profileHostLabel = New-Object System.Windows.Forms.Label
    $profileHostLabel.Text = "Host:"
    $profileHostLabel.AutoSize = $true
    $profileHostLabel.Padding = New-Object System.Windows.Forms.Padding(8, 8, 2, 0)
    $profileBtnPanel.Controls.Add($profileHostLabel)

    $script:profileHostBox = New-Object System.Windows.Forms.TextBox
    $script:profileHostBox.Width = 130
    $script:profileHostBox.Text = $env:COMPUTERNAME
    $script:profileHostBox.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 3)
    $profileBtnPanel.Controls.Add($script:profileHostBox)

    $script:profileLoadHostBtn = New-Object System.Windows.Forms.Button
    $script:profileLoadHostBtn.Text = "Load Host"
    $script:profileLoadHostBtn.Height = 30
    $script:profileLoadHostBtn.Width = $script:profileLoadHostBtn.PreferredSize.Width + 6
    $profileBtnPanel.Controls.Add($script:profileLoadHostBtn)

    $profilePanel.Controls.Add($profileBtnPanel, 0, 2)
    $script:splitContainerInner.Panel1.Controls.Add($profilePanel)
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
    $addSelectedBtn.Text = "Add to Machine"
    $addSelectedBtn.Height = 30
    $addSelectedBtn.Width = $addSelectedBtn.PreferredSize.Width + 6
    $addSelectedBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 255, 230)
    $serverBtnPanel.Controls.Add($addSelectedBtn)

    $script:addToProfileBtn = New-Object System.Windows.Forms.Button
    $script:addToProfileBtn.Text = "Add to Profile"
    $script:addToProfileBtn.Height = 30
    $script:addToProfileBtn.Width = $script:addToProfileBtn.PreferredSize.Width + 6
    $script:addToProfileBtn.BackColor = [System.Drawing.Color]::FromArgb(230, 240, 255)
    $serverBtnPanel.Controls.Add($script:addToProfileBtn)

    $manualAddBtn = New-Object System.Windows.Forms.Button
    $manualAddBtn.Text = "Add by Path..."
    $manualAddBtn.Height = 30
    $manualAddBtn.Width = $manualAddBtn.PreferredSize.Width + 6
    $serverBtnPanel.Controls.Add($manualAddBtn)

    $rightPanel.Controls.Add($serverBtnPanel, 0, 3)
    $script:splitContainerInner.Panel2.Controls.Add($rightPanel)
    #endregion

    # Wire inner split into outer Panel2, and outer split into root layout.
    $script:splitContainer.Panel2.Controls.Add($script:splitContainerInner)
    $script:rootLayout.Controls.Add($script:splitContainer, 0, 0)

    #region Activity Log (bottom)
    $logHeader = New-Object System.Windows.Forms.Label
    $logHeader.Text = "Activity Log"
    $logHeader.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $logHeader.AutoSize = $true

    $script:activityLogBox = New-Object System.Windows.Forms.ListBox
    $script:activityLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:activityLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:activityLogBox.IntegralHeight = $false

    $logContainer = New-Object System.Windows.Forms.TableLayoutPanel
    $logContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logContainer.RowCount = 2
    $logContainer.ColumnCount = 1
    $logContainer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 18))) | Out-Null
    $logContainer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $logContainer.Controls.Add($logHeader, 0, 0)
    $logContainer.Controls.Add($script:activityLogBox, 0, 1)
    $script:rootLayout.Controls.Add($logContainer, 0, 1)
    #endregion

    #region State Variables
    $script:ServerPrintersList = @()
    $script:ProfileRows         = @()
    $script:ProfileLoadedTime   = $null
    $script:ProfileDirty        = $false
    $script:ProfileHost         = $env:COMPUTERNAME
    $script:ProfilePath         = Join-Path $script:ProfileShareXA "$env:COMPUTERNAME.txt"
    $script:ProfileReason       = $null
    #endregion

    # Activity log helper - writes to the in-tab box and to the persistent session log.
    $script:PrinterLog = {
        param([string]$Message, [string]$Level = "INFO")
        try {
            $ts = Get-Date -Format "HH:mm:ss"
            $line = "[$ts] [$Level] $Message"
            if ($script:activityLogBox) {
                $script:activityLogBox.Items.Add($line) | Out-Null
                $script:activityLogBox.TopIndex = [Math]::Max(0, $script:activityLogBox.Items.Count - 1)
            }
        } catch { }
        try { Write-SessionLog -Message $Message -Category "Printer Management" } catch { }
    }

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

    # Normalize a printer path for comparison: lowercase and strip the domain
    # suffix from the server segment. Profile rows use the FQDN server
    # (\\RUDWV-PS401.rush.edu\X) while installed printers report the short
    # name (\\RUDWV-PS401\X) - without this, installed printers show "Missing".
    $script:NormalizePrinterPath = {
        param([string]$PrinterPath)
        if (-not $PrinterPath) { return "" }
        $p = $PrinterPath.ToLower().Trim()
        if ($p -match '^\\\\([^\\]+)\\(.+)$') {
            $server = $Matches[1] -replace '\.rush\.edu$', ''
            return "\\$server\$($Matches[2])"
        }
        return $p
    }

    # Recompute Status for every profile row by diffing against installed printers.
    $script:ComputeProfileStatuses = {
        $installed = & $script:GetInstalledPrinters
        # Build a set of installed network printer paths (normalized, case-insensitive)
        $installedPaths = @{}
        foreach ($p in $installed) {
            if ($p.Name) { $installedPaths[(& $script:NormalizePrinterPath -PrinterPath $p.Name)] = $true }
        }
        foreach ($r in $script:ProfileRows) {
            if ($r.IsPending) {
                $r.Status = "Pending"
            }
            elseif ($installedPaths.ContainsKey((& $script:NormalizePrinterPath -PrinterPath $r.FullPath))) {
                $r.Status = "Installed"
            }
            else {
                $r.Status = "Missing"
            }
        }
    }

    # Re-render the Profile ListView from $script:ProfileRows
    $script:RenderProfilePane = {
        $rowCount = @($script:ProfileRows).Count
        & $script:PrinterLog "RenderProfilePane: rendering $rowCount row(s)" "DEBUG"

        $script:profileListView.BeginUpdate()
        $script:profileListView.Items.Clear()
        & $script:ComputeProfileStatuses

        $added = 0
        foreach ($r in @($script:ProfileRows)) {
            if ($null -eq $r) { continue }
            $display = if ($r.FullPath) { [string]$r.FullPath } else { "(no path)" }
            $item = New-Object System.Windows.Forms.ListViewItem($display)
            $defaultText = if ($r.IsDefault) { "Yes" } else { "" }
            [void]$item.SubItems.Add($defaultText)
            $statusLabel = if ($r.IsPending) { "*pending*" } else { [string]$r.Status }
            [void]$item.SubItems.Add($statusLabel)
            $item.Tag = $r

            if ($r.IsPending) {
                $item.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
                $item.ForeColor = [System.Drawing.Color]::DarkOrange
            }
            elseif ($r.Status -eq "Installed") {
                $item.ForeColor = [System.Drawing.Color]::DarkGreen
            }
            elseif ($r.Status -eq "Missing") {
                $item.ForeColor = [System.Drawing.Color]::DarkRed
            }

            if ($r.IsDefault) {
                $item.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
            }

            [void]$script:profileListView.Items.Add($item)
            $added++
        }
        $script:profileListView.EndUpdate()
        $script:profileListView.Refresh()

        & $script:PrinterLog "RenderProfilePane: added $added of $rowCount row(s); ListView.Items.Count=$($script:profileListView.Items.Count)" "DEBUG"

        $script:profileSaveBtn.Enabled = [bool]$script:ProfileDirty
    }

    # Load profile from share into state and render.
    $script:LoadProfileToUI = {
        $result = & $script:LoadProfile -Hostname $script:ProfileHost
        $script:ProfilePath = $result.Path
        $script:ProfileReason = $result.Reason

        switch ($result.Reason) {
            "Loaded" {
                $script:ProfileRows = @($result.Rows)
                $script:ProfileLoadedTime = $result.LastWriteTime
                $script:ProfileDirty = $false

                $suffix = ""
                if ($result.Share -and $result.Share -ne "XA") { $suffix += " [$($result.Share) share]" }
                if (@($result.UnparsedLines).Count -gt 0) { $suffix += " - $(@($result.UnparsedLines).Count) unparsed line(s), see log" }
                $script:profileLabel.Text = "Profile for $($script:ProfileHost)$suffix"

                & $script:PrinterLog "Loaded profile ($($script:ProfileRows.Count) rows) from $($result.Path)"
                foreach ($ul in @($result.UnparsedLines)) {
                    & $script:PrinterLog "Unparsed profile line (kept out of the list): '$ul'" "WARN"
                }
            }
            "NotFound" {
                $script:ProfileRows = @()
                $script:ProfileLoadedTime = $null
                $script:ProfileDirty = $false
                $script:profileLabel.Text = "No profile found for $($script:ProfileHost) - use 'New from Installed'"
                & $script:PrinterLog "No profile file for $($script:ProfileHost) on any share ($($result.ShareStatus))" "WARN"
            }
            "ShareUnreachable" {
                $script:ProfileRows = @()
                $script:ProfileLoadedTime = $null
                $script:ProfileDirty = $false
                $script:profileLabel.Text = "Profile shares unreachable"
                & $script:PrinterLog "No profile share reachable ($($result.ShareStatus))" "ERROR"
            }
            default {
                $script:ProfileRows = @()
                $script:ProfileLoadedTime = $null
                $script:ProfileDirty = $false
                $script:profileLabel.Text = "Profile load error"
                & $script:PrinterLog "Profile load error: $($result.Reason)" "ERROR"
            }
        }
        & $script:RenderProfilePane
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
            [System.Windows.Forms.MessageBox]::Show(
                "Please select a printer to send a test page.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $printerName = $script:installedListView.SelectedItems[0].Text
        $result = & $script:SendTestPage -PrinterName $printerName

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

        foreach ($printer in $checkedItems) {
            $result = & $script:AddNetworkPrinterAllUsers -PrinterPath $printer.FullPath
            # Also add for current user so it shows immediately
            if ($result.Success) {
                & $script:AddNetworkPrinter -PrinterPath $printer.FullPath | Out-Null
            }

            if ($result.Success) {
                $successCount++
            }
            else {
                $failedPrinters += "$($printer.Name): $($result.Error)"
            }
        }

        if ($failedPrinters.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Successfully added $successCount printer(s) for $modeText.",
                "Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
        else {
            $message = "Added $successCount printer(s) for $modeText.`n`nFailed:`n" + ($failedPrinters -join "`n")
            [System.Windows.Forms.MessageBox]::Show(
                $message,
                "Partial Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }

        & $script:RefreshInstalledPrinters
    })

    # ---------- Profile pane event handlers ----------

    $script:profileReloadBtn.Add_Click({
        & $script:LoadProfileToUI
    })

    # Load a different computer's profile by hostname
    $script:profileLoadHostBtn.Add_Click({
        $h = $script:profileHostBox.Text.Trim()
        if (-not $h) { return }

        if ($script:ProfileDirty) {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "You have unsaved profile changes for $($script:ProfileHost).`n`nDiscard them and load $($h.ToUpper())?",
                "Unsaved Changes",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $script:ProfileHost = $h.ToUpper()
        & $script:PrinterLog "Switching profile host to $($script:ProfileHost)"
        & $script:LoadProfileToUI
    })

    $script:profileHostBox.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            $script:profileLoadHostBtn.PerformClick()
        }
    })

    # Seed a new profile from this computer's installed network printers
    $script:profileNewFromInstalledBtn.Add_Click({
        $installed = & $script:GetInstalledPrinters
        $network = @($installed | Where-Object { $_.IsNetwork -and $_.Name -match '^\\\\[^\\]+\\.+' })

        if ($network.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "No network printers are installed on this computer.",
                "Nothing to Add",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        $added = 0
        foreach ($p in $network) {
            if ($p.Name -notmatch '^\\\\[^\\]+\\(.+)$') { continue }
            $bareName = $Matches[1]

            $dup = $false
            foreach ($existing in $script:ProfileRows) {
                if ($existing.Name -ieq $bareName) { $dup = $true; break }
            }
            if ($dup) { continue }

            $row = @{
                FullPath    = "$($script:ProfileDefaultServerPrefix)\$bareName"
                Name        = $bareName
                IsDefault   = [bool]$p.IsDefault
                IsPending   = $true
                Status      = "Pending"
                BrowsedFrom = $null
            }
            $tmp = @($script:ProfileRows) + @($row)
            $script:ProfileRows = $tmp
            $added++
        }

        if ($added -gt 0) {
            $script:ProfileDirty = $true
            & $script:RenderProfilePane
            & $script:PrinterLog "Added $added installed network printer(s) to profile for $($script:ProfileHost) (pending save)"
        }
        else {
            & $script:PrinterLog "All installed network printers are already in the profile" "WARN"
        }
    })

    # Add checked Browse-pane rows into the profile as pending entries.
    # Per decision D4, profile rows are always recorded as \\RUDWV-PS401.rush.edu\<name>
    # regardless of which Browse server they were enumerated from.
    $script:addToProfileBtn.Add_Click({
        $checked = @()
        foreach ($item in $script:serverListView.CheckedItems) { $checked += $item.Tag }
        if ($checked.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Check at least one printer to add to the profile.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $selectedBrowseServer = $script:serverComboBox.SelectedItem
        $added = 0
        foreach ($p in $checked) {
            $bareName = $p.ShareName
            if (-not $bareName -and $p.Name) { $bareName = $p.Name }
            if (-not $bareName) { continue }

            # Skip duplicates (case-insensitive name match)
            $dup = $false
            foreach ($existing in $script:ProfileRows) {
                if ($existing.Name -ieq $bareName) { $dup = $true; break }
            }
            if ($dup) {
                & $script:PrinterLog "Skipping $bareName - already in profile" "WARN"
                continue
            }

            $row = @{
                FullPath    = "$($script:ProfileDefaultServerPrefix)\$bareName"
                Name        = $bareName
                IsDefault   = $false
                IsPending   = $true
                Status      = "Pending"
                BrowsedFrom = $selectedBrowseServer
            }
            # Defensive: rebuild via local var to dodge any $script: += scope quirks in event handlers
            $tmp = @($script:ProfileRows) + @($row)
            $script:ProfileRows = $tmp
            $added++
        }
        & $script:PrinterLog "AddToProfile: ProfileRows.Count after add = $($script:ProfileRows.Count)" "DEBUG"

        if ($added -gt 0) {
            $script:ProfileDirty = $true
            & $script:RenderProfilePane
            & $script:PrinterLog "Added $added printer(s) to profile (pending save)"
        }

        # Clear check marks
        foreach ($item in $script:serverListView.Items) { $item.Checked = $false }
    })

    $script:profileRemoveBtn.Add_Click({
        if ($script:profileListView.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Select a profile row to remove.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $toRemove = @()
        foreach ($item in $script:profileListView.SelectedItems) { $toRemove += $item.Tag }
        $new = @()
        foreach ($r in $script:ProfileRows) {
            $keep = $true
            foreach ($d in $toRemove) { if ($d -eq $r) { $keep = $false; break } }
            if ($keep) { $new += $r }
        }
        $script:ProfileRows = $new
        $script:ProfileDirty = $true
        & $script:RenderProfilePane
        & $script:PrinterLog "Removed $($toRemove.Count) row(s) from profile (pending save)"
    })

    $script:profileMarkDefaultBtn.Add_Click({
        if ($script:profileListView.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Select a profile row to mark as default.",
                "No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $target = $script:profileListView.SelectedItems[0].Tag
        foreach ($r in $script:ProfileRows) {
            $r.IsDefault = ($r -eq $target)
        }
        $script:ProfileDirty = $true
        & $script:RenderProfilePane
        & $script:PrinterLog "Marked $($target.Name) as default (pending save)"
    })

    $script:profileSaveBtn.Add_Click({
        if (-not $script:ProfileDirty) { return }

        # B6: check for on-share modification since load (XA is source of truth)
        if (Test-Path $script:ProfilePath -ErrorAction SilentlyContinue) {
            try {
                $currentStamp = (Get-Item -Path $script:ProfilePath).LastWriteTime
                if ($script:ProfileLoadedTime -and ($currentStamp -gt $script:ProfileLoadedTime)) {
                    $conflict = [System.Windows.Forms.MessageBox]::Show(
                        "Profile was modified on the server since you loaded it.`n`nYes = Overwrite`nNo = Reload (discard your edits)`nCancel = Do nothing",
                        "Profile Conflict",
                        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                        [System.Windows.Forms.MessageBoxIcon]::Warning)
                    if ($conflict -eq [System.Windows.Forms.DialogResult]::No) {
                        & $script:LoadProfileToUI
                        return
                    }
                    if ($conflict -ne [System.Windows.Forms.DialogResult]::Yes) {
                        return
                    }
                }
            } catch { }
        }

        $save = & $script:SaveProfile -Hostname $script:ProfileHost -Rows $script:ProfileRows
        $failed = 0
        foreach ($r in $save.Results) {
            if ($r.Success) {
                & $script:PrinterLog "Wrote $($r.Share) profile: $($r.Path) ($($script:ProfileRows.Count) rows)"
            } else {
                $failed++
                & $script:PrinterLog "FAILED $($r.Share) write ($($r.Path)): $($r.Error)" "ERROR"
            }
        }

        if ($failed -eq 0) {
            # Clear pending markers on all rows (they're now on disk)
            foreach ($r in $script:ProfileRows) { $r.IsPending = $false }
            $script:ProfileDirty = $false
            if ($save.LastWriteTime) { $script:ProfileLoadedTime = $save.LastWriteTime }
            & $script:RenderProfilePane
            & $script:PrinterLog "Profile saved to all three shares"
        }
        elseif ($failed -lt $save.Results.Count) {
            # Partial success - XA succeeded? keep dirty so tech can retry
            & $script:PrinterLog "Partial save: $($save.Results.Count - $failed) of $($save.Results.Count) shares succeeded" "WARN"
            [System.Windows.Forms.MessageBox]::Show(
                "Profile was saved to some shares but not others. See the activity log for details. You can click Save Profile again after resolving the issue.",
                "Partial Save",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "Profile save failed on all shares. See the activity log for details.",
                "Save Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $script:profileInstallBtn.Add_Click({
        # Re-read profile file from share first (C1)
        & $script:LoadProfileToUI
        if ($script:ProfileReason -ne "Loaded" -and $script:ProfileReason -ne "NotFound") { return }
        if ($script:ProfileRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Profile is empty - nothing to install.",
                "Nothing to Install",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        $toInstall = @()
        $alreadyInstalled = @()
        foreach ($r in $script:ProfileRows) {
            if ($r.Status -eq "Missing") { $toInstall += $r }
            elseif ($r.Status -eq "Installed") { $alreadyInstalled += $r }
        }

        if ($toInstall.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Everything in the profile is already installed.",
                "Nothing to Install",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        # Build confirm dialog per D3
        $msg = "Ready to install the following printers from the profile:`r`n`r`n"
        foreach ($r in $toInstall) {
            $mark = if ($r.IsDefault) { "    [DEFAULT]" } else { "" }
            $msg += "  $($r.FullPath)$mark`r`n"
        }
        if ($alreadyInstalled.Count -gt 0) {
            $msg += "`r`nAlready installed (will be skipped):`r`n"
            foreach ($r in $alreadyInstalled) { $msg += "  $($r.FullPath)`r`n" }
        }
        $msg += "`r`nProceed?"

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            $msg, "Confirm Install",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $installed = 0
        $failed = 0
        $defaultTarget = $null

        foreach ($r in $toInstall) {
            # Validate against allowlist (C5)
            $check = & $script:TestPrinterPathAllowed -PrinterPath $r.FullPath
            if (-not $check.Allowed) {
                & $script:PrinterLog "REJECTED $($r.FullPath): $($check.Reason)" "ERROR"
                $failed++
                continue
            }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & $script:AddNetworkPrinter -PrinterPath $r.FullPath
            $sw.Stop()
            if ($result.Success) {
                $installed++
                & $script:PrinterLog "Installed $($r.FullPath) ($([int]$sw.Elapsed.TotalMilliseconds) ms)"
                if ($r.IsDefault) { $defaultTarget = $r.FullPath }
            }
            else {
                $failed++
                & $script:PrinterLog "FAILED $($r.FullPath): $($result.Error)" "ERROR"
            }
        }

        # Set the default printer if any row was flagged (covers newly-installed ones)
        if (-not $defaultTarget) {
            foreach ($r in $script:ProfileRows) {
                if ($r.IsDefault) { $defaultTarget = $r.FullPath; break }
            }
        }
        if ($defaultTarget) {
            $dres = & $script:SetDefaultPrinter -PrinterName $defaultTarget
            if ($dres.Success) {
                & $script:PrinterLog "Set default printer: $defaultTarget"
            } else {
                & $script:PrinterLog "Could not set default $defaultTarget - $($dres.Error)" "WARN"
            }
        }

        & $script:RefreshInstalledPrinters
        & $script:RenderProfilePane
        & $script:PrinterLog "Install complete: $installed succeeded, $failed failed"
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
        $okBtn.AutoSize = $true
        $okBtn.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
        $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $inputForm.Controls.Add($okBtn)

        $cancelBtn = New-Object System.Windows.Forms.Button
        $cancelBtn.Text = "Cancel"
        $cancelBtn.Location = New-Object System.Drawing.Point(295, 110)
        $cancelBtn.AutoSize = $true
        $cancelBtn.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
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

            $result = & $script:AddNetworkPrinterAllUsers -PrinterPath $printerPath
            # Also add for current user so it shows immediately
            if ($result.Success) {
                & $script:AddNetworkPrinter -PrinterPath $printerPath | Out-Null
            }

            if ($result.Success) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Printer added successfully for $modeText.`n`nPath: $printerPath",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                & $script:RefreshInstalledPrinters
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

    # Add to tab
    $tab.Controls.Add($script:rootLayout)

    # Set splitter positions after form is sized: outer ~33%, inner ~50% of the remainder
    $tab.Add_SizeChanged({
        if ($script:splitContainer.Width -gt 0) {
            $script:splitContainer.SplitterDistance = [int]($script:splitContainer.Width / 3)
        }
        if ($script:splitContainerInner.Width -gt 0) {
            $script:splitContainerInner.SplitterDistance = [int]($script:splitContainerInner.Width / 2)
        }
    })

    # Initial load - installed printers (with error handling for Windows 10 compatibility)
    try {
        & $script:RefreshInstalledPrinters
    }
    catch {
        Write-SessionLog -Message "Failed to load installed printers during module init: $($_.Exception.Message)" -Category "Printer Management"
        # UI will still load, user can manually refresh
    }

    # Auto-load server printers if default server is configured (with error handling)
    if ($script:PrintServer) {
        try {
            & $script:RefreshServerPrinters
        }
        catch {
            Write-SessionLog -Message "Failed to auto-load server printers during module init: $($_.Exception.Message)" -Category "Printer Management"
            # UI will still load, user can manually browse
        }
    }

    # Auto-load this host's profile file (failures degrade the Profile pane only,
    # the Installed and Browse panes remain fully functional).
    try {
        & $script:LoadProfileToUI
    }
    catch {
        & $script:PrinterLog "Profile auto-load failed: $($_.Exception.Message)" "ERROR"
    }

    # Show compatibility note if PrintManagement module not available
    if (-not $script:HasPrintManagement) {
        # NOTE: was Set-AppStatus, which is defined nowhere. As the last statement
        # of Initialize-Module it threw CommandNotFoundException on every machine
        # without the PrintManagement feature, and the loader then replaced the
        # whole Printers tab with a red "Module failed to load" label.
        $script:compatNote = "Note: Using Windows 10 compatibility mode (WMI-based printer management)"
        & $script:PrinterLog $script:compatNote "INFO"
        if ($script:statusLabel) {
            $script:statusLabel.Text = $script:compatNote
            $script:statusLabel.ForeColor = [System.Drawing.Color]::Black
        }
    }
}
