<#
.SYNOPSIS
    Disk Cleanup Module - Clean temp files and find large unused files
.DESCRIPTION
    Two-tab module:
    1. Safe Cleanup - Automated cleanup of known-safe temp/cache locations
    2. Unused Files - Find and delete large files not accessed in 90+ days
.NOTES
    Requires elevation for system folder cleanup
#>

$script:ModuleName = "Disk Cleanup"
$script:ModuleDescription = "Clean temp files and find large unused files on C: drive"

#region Cleanup Category Definitions
$script:CleanupCategories = @(
    @{
        Name = "Windows Temp Files"
        Paths = @("C:\Windows\Temp")
        Pattern = "*"
        RequiresElevation = $true
        MaxAgeDays = 0  # 0 = all files
        DefaultChecked = $true
    },
    @{
        Name = "User Temp Files"
        Paths = @("$env:TEMP", "$env:TMP")
        Pattern = "*"
        RequiresElevation = $false
        MaxAgeDays = 0
        DefaultChecked = $true
    },
    @{
        Name = "Windows Update Cache"
        Paths = @("C:\Windows\SoftwareDistribution\Download")
        Pattern = "*"
        RequiresElevation = $true
        MaxAgeDays = 0
        DefaultChecked = $true
    },
    @{
        Name = "Chrome Cache"
        Paths = @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
                  "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache")
        Pattern = "*"
        RequiresElevation = $false
        MaxAgeDays = 0
        DefaultChecked = $true
    },
    @{
        Name = "Edge Cache"
        Paths = @("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
                  "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache")
        Pattern = "*"
        RequiresElevation = $false
        MaxAgeDays = 0
        DefaultChecked = $true
    },
    @{
        Name = "Firefox Cache"
        Paths = @("$env:LOCALAPPDATA\Mozilla\Firefox\Profiles")
        Pattern = "cache2"
        RequiresElevation = $false
        MaxAgeDays = 0
        DefaultChecked = $true
        Recurse = $true
    },
    @{
        Name = "Recycle Bin"
        Paths = @()  # Special handling
        IsRecycleBin = $true
        RequiresElevation = $false
        MaxAgeDays = 0
        DefaultChecked = $true
    },
    @{
        Name = "Delivery Optimization"
        Paths = @("C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache")
        Pattern = "*"
        RequiresElevation = $true
        MaxAgeDays = 0
        DefaultChecked = $false  # Unchecked by default - can affect Windows Update
    },
    @{
        Name = "Thumbnail Cache"
        Paths = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer")
        Pattern = "thumbcache_*.db"
        RequiresElevation = $false
        MaxAgeDays = 0
        DefaultChecked = $true
    },
    @{
        Name = "Error Memory Dumps"
        Paths = @("C:\Windows\Minidump", "C:\Windows\LiveKernelReports")
        Pattern = "*"
        RequiresElevation = $true
        MaxAgeDays = 0
        DefaultChecked = $true
        IncludeFiles = @("C:\Windows\MEMORY.DMP")
    },
    @{
        Name = "Old Log Files (30+ days)"
        Paths = @("C:\Windows\Logs", "C:\Windows\Panther")
        Pattern = "*.log"
        RequiresElevation = $true
        MaxAgeDays = 30
        DefaultChecked = $true
        Recurse = $true
    },
    @{
        Name = "Installer Leftovers (30+ days)"
        Paths = @("$env:TEMP", "$env:USERPROFILE\Downloads")
        Pattern = "*.msi"
        RequiresElevation = $false
        MaxAgeDays = 30
        DefaultChecked = $false  # Unchecked - user might want these
        AdditionalPatterns = @("*.exe")
    }
)

# Paths to exclude from unused file scan
$script:ExcludedPaths = @(
    "C:\Windows",
    "C:\Program Files",
    "C:\Program Files (x86)",
    "C:\ProgramData",
    "C:\`$Recycle.Bin",
    "C:\System Volume Information",
    "C:\Recovery"
)
#endregion

#region Helper Functions

function Format-FileSize {
    <#
    .SYNOPSIS
        Formats bytes into human-readable size string.
    #>
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        return "{0:N1} MB" -f ($Bytes / 1MB)
    }
    elseif ($Bytes -ge 1KB) {
        return "{0:N0} KB" -f ($Bytes / 1KB)
    }
    else {
        return "$Bytes B"
    }
}

function Get-CategorySize {
    <#
    .SYNOPSIS
        Calculates total size and file count for a cleanup category.
    .OUTPUTS
        Hashtable with TotalBytes, FileCount, AccessDenied boolean, DebugInfo string.
    #>
    param([hashtable]$Category)

    $result = @{
        TotalBytes = 0
        FileCount = 0
        AccessDenied = $false
        DebugInfo = ""
    }

    # Special handling for Recycle Bin
    if ($Category.IsRecycleBin) {
        try {
            $shell = New-Object -ComObject Shell.Application
            $recycleBin = $shell.Namespace(0xA)  # Recycle Bin
            $items = $recycleBin.Items()
            $result.FileCount = $items.Count
            foreach ($item in $items) {
                $result.TotalBytes += $item.Size
            }
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
            $result.DebugInfo = "Recycle Bin: $($result.FileCount) items"
        }
        catch {
            $result.AccessDenied = $true
            $result.DebugInfo = "Recycle Bin: Access denied - $($_.Exception.Message)"
        }
        return $result
    }

    # Regular path-based categories
    $debugLines = @()
    foreach ($basePath in $Category.Paths) {
        # Expand environment variables - handle both $env:VAR and %VAR% formats
        $expandedPath = $basePath
        # First expand PowerShell $env: variables if they weren't expanded at definition
        if ($basePath -match '\$env:') {
            $expandedPath = $ExecutionContext.InvokeCommand.ExpandString($basePath)
        }
        # Then expand Windows %VAR% style variables
        $expandedPath = [Environment]::ExpandEnvironmentVariables($expandedPath)

        if (-not (Test-Path $expandedPath)) {
            $debugLines += "  Path not found: $expandedPath (raw: $basePath)"
            continue
        }

        try {
            $pattern = if ($Category.Pattern) { $Category.Pattern } else { "*" }
            $recurse = if ($Category.Recurse) { $true } else { $false }
            $maxAge = $Category.MaxAgeDays
            $cutoffDate = if ($maxAge -gt 0) { (Get-Date).AddDays(-$maxAge) } else { $null }

            $debugLines += "  Scanning: $expandedPath (pattern: $pattern, recurse: $recurse)"

            # Get files
            $files = @(Get-ChildItem -Path $expandedPath -Filter $pattern -File -Recurse:$recurse -Force -ErrorAction SilentlyContinue)

            # Handle additional patterns
            if ($Category.AdditionalPatterns) {
                foreach ($addPattern in $Category.AdditionalPatterns) {
                    $additionalFiles = @(Get-ChildItem -Path $expandedPath -Filter $addPattern -File -Recurse:$recurse -Force -ErrorAction SilentlyContinue)
                    $files += $additionalFiles
                }
            }

            $filesFoundInPath = 0
            $bytesInPath = 0

            foreach ($file in $files) {
                # Apply age filter if specified
                if ($cutoffDate -and $file.LastWriteTime -gt $cutoffDate) { continue }

                $result.TotalBytes += $file.Length
                $result.FileCount++
                $filesFoundInPath++
                $bytesInPath += $file.Length
            }

            $debugLines += "    Found: $filesFoundInPath files ($(Format-FileSize -Bytes $bytesInPath))"
        }
        catch [System.UnauthorizedAccessException] {
            $result.AccessDenied = $true
            $debugLines += "    Access denied: $expandedPath"
        }
        catch {
            $debugLines += "    Error: $($_.Exception.Message)"
        }
    }

    $result.DebugInfo = $debugLines -join "`r`n"

    # Handle individual files (like MEMORY.DMP)
    if ($Category.IncludeFiles) {
        foreach ($filePath in $Category.IncludeFiles) {
            if (Test-Path $filePath) {
                try {
                    $file = Get-Item $filePath -Force -ErrorAction SilentlyContinue
                    if ($file) {
                        $result.TotalBytes += $file.Length
                        $result.FileCount++
                    }
                }
                catch { }
            }
        }
    }

    return $result
}

function Clear-Category {
    <#
    .SYNOPSIS
        Deletes files in a cleanup category.
    .OUTPUTS
        Hashtable with DeletedCount, FreedBytes, Errors array.
    #>
    param(
        [hashtable]$Category,
        [PSCredential]$Credential
    )

    $result = @{
        DeletedCount = 0
        FreedBytes = 0
        Errors = @()
    }

    # Special handling for Recycle Bin
    if ($Category.IsRecycleBin) {
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            $result.DeletedCount = 1  # Treat as single operation
        }
        catch {
            $result.Errors += "Recycle Bin: $($_.Exception.Message)"
        }
        return $result
    }

    # Determine if we need elevation
    $needsElevation = $Category.RequiresElevation

    foreach ($basePath in $Category.Paths) {
        $expandedPath = [Environment]::ExpandEnvironmentVariables($basePath)

        if (-not (Test-Path $expandedPath)) { continue }

        $pattern = if ($Category.Pattern) { $Category.Pattern } else { "*" }
        $recurse = if ($Category.Recurse) { $true } else { $false }
        $maxAge = $Category.MaxAgeDays
        $cutoffDate = if ($maxAge -gt 0) { (Get-Date).AddDays(-$maxAge) } else { $null }

        try {
            $files = Get-ChildItem -Path $expandedPath -Filter $pattern -File -Recurse:$recurse -Force -ErrorAction SilentlyContinue

            if ($Category.AdditionalPatterns) {
                foreach ($addPattern in $Category.AdditionalPatterns) {
                    $files += Get-ChildItem -Path $expandedPath -Filter $addPattern -File -Recurse:$recurse -Force -ErrorAction SilentlyContinue
                }
            }

            foreach ($file in $files) {
                if ($cutoffDate -and $file.LastWriteTime -gt $cutoffDate) { continue }

                try {
                    $fileSize = $file.Length

                    if ($needsElevation -and $Credential) {
                        # Use elevated deletion
                        $deleteResult = Invoke-Elevated -ScriptBlock {
                            param($path)
                            Remove-Item -Path $path -Force -ErrorAction Stop
                            return $true
                        } -ArgumentList $file.FullName -Credential $Credential -OperationName "delete file"

                        if ($deleteResult.Success) {
                            $result.DeletedCount++
                            $result.FreedBytes += $fileSize
                        }
                    }
                    else {
                        Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                        $result.DeletedCount++
                        $result.FreedBytes += $fileSize
                    }
                }
                catch {
                    $result.Errors += "$($file.Name): $($_.Exception.Message)"
                }
            }
        }
        catch {
            $result.Errors += "$expandedPath : $($_.Exception.Message)"
        }
    }

    # Handle individual files
    if ($Category.IncludeFiles) {
        foreach ($filePath in $Category.IncludeFiles) {
            if (Test-Path $filePath) {
                try {
                    $file = Get-Item $filePath -Force
                    $fileSize = $file.Length

                    if ($needsElevation -and $Credential) {
                        $deleteResult = Invoke-Elevated -ScriptBlock {
                            param($path)
                            Remove-Item -Path $path -Force -ErrorAction Stop
                            return $true
                        } -ArgumentList $filePath -Credential $Credential -OperationName "delete file"

                        if ($deleteResult.Success) {
                            $result.DeletedCount++
                            $result.FreedBytes += $fileSize
                        }
                    }
                    else {
                        Remove-Item -Path $filePath -Force -ErrorAction Stop
                        $result.DeletedCount++
                        $result.FreedBytes += $fileSize
                    }
                }
                catch {
                    $result.Errors += "$filePath : $($_.Exception.Message)"
                }
            }
        }
    }

    return $result
}

function Find-UnusedFiles {
    <#
    .SYNOPSIS
        Finds large files that haven't been modified in specified days.
    .DESCRIPTION
        Uses native forfiles.exe for reliability in restricted environments.
        Falls back to PowerShell if forfiles fails.
    .OUTPUTS
        Array of file objects with Path, Size, LastModified properties.
    #>
    param(
        [int]$MinSizeMB = 100,
        [int]$DaysUnused = 90,
        [scriptblock]$ProgressCallback
    )

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $minBytes = $MinSizeMB * 1MB

    if ($ProgressCallback) {
        & $ProgressCallback -Message "Starting scan: files >= ${MinSizeMB}MB, not modified in ${DaysUnused}+ days"
        & $ProgressCallback -Message "Using native forfiles.exe for reliability..."
    }

    # Search user-accessible locations (skip system folders)
    $searchPaths = @(
        "$env:USERPROFILE",
        "C:\Users\Public"
    )

    # Also check for other user profiles if accessible
    $usersDir = "C:\Users"
    if (Test-Path $usersDir) {
        Get-ChildItem -Path $usersDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -notin @("Public", "Default", "Default User", "All Users", $env:USERNAME)) {
                $searchPaths += $_.FullName
            }
        }
    }

    foreach ($searchPath in $searchPaths) {
        if (-not (Test-Path $searchPath)) { continue }

        if ($ProgressCallback) {
            & $ProgressCallback -Message "Scanning: $searchPath"
            [System.Windows.Forms.Application]::DoEvents()
        }

        try {
            # Use forfiles.exe - native Windows tool, works in restricted environments
            # /D -N means files modified more than N days ago
            $forfilesCmd = "forfiles /P `"$searchPath`" /S /D -$DaysUnused /C `"cmd /c echo @path,@fsize,@fdate`" 2>nul"

            $output = cmd /c $forfilesCmd 2>&1

            foreach ($line in $output) {
                if (-not $line -or $line -match "^ERROR" -or $line -match "^No files found") { continue }

                try {
                    # Parse: "C:\path\file.ext",12345678,01/15/2025
                    $parts = $line -split ','
                    if ($parts.Count -ge 2) {
                        $filePath = $parts[0].Trim('"')
                        $fileSize = [long]($parts[1].Trim())
                        $fileDate = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "Unknown" }

                        # Size filter
                        if ($fileSize -ge $minBytes) {
                            $results.Add([PSCustomObject]@{
                                Path = $filePath
                                Size = $fileSize
                                SizeFormatted = Format-FileSize -Bytes $fileSize
                                LastAccessed = $fileDate
                                Extension = [System.IO.Path]::GetExtension($filePath)
                            })

                            if ($ProgressCallback -and ($results.Count % 5 -eq 0)) {
                                & $ProgressCallback -Message "Found $($results.Count) files so far..."
                                [System.Windows.Forms.Application]::DoEvents()
                            }
                        }
                    }
                }
                catch {
                    # Skip unparseable lines
                }
            }
        }
        catch {
            if ($ProgressCallback) {
                & $ProgressCallback -Message "Warning: Could not scan $searchPath - $($_.Exception.Message)"
            }
        }
    }

    if ($ProgressCallback) {
        & $ProgressCallback -Message "Scan complete: Found $($results.Count) large unused files"
    }

    # Sort by size descending
    return $results | Sort-Object -Property Size -Descending
}

#endregion

#region UI Helper Functions

function Update-SafeCleanupTotal {
    $totalBytes = 0
    $totalFiles = 0

    foreach ($item in $script:categoryListView.CheckedItems) {
        if ($item.Tag -is [hashtable] -and $item.Tag.TotalBytes) {
            $totalBytes += $item.Tag.TotalBytes
            $totalFiles += $item.Tag.FileCount
        }
    }

    $script:safeTotalLabel.Text = "Selected: $totalFiles files ($(Format-FileSize -Bytes $totalBytes))"
}

function Update-UnusedFilesTotal {
    $totalBytes = 0
    $count = 0

    foreach ($item in $script:unusedListView.CheckedItems) {
        $totalBytes += $item.Tag.Size
        $count++
    }

    $script:unusedTotalLabel.Text = "Selected: $count files ($(Format-FileSize -Bytes $totalBytes))"
}

#endregion

#region Module UI

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Main layout panel
    $mainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.RowCount = 1
    $mainPanel.ColumnCount = 1
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null

    # Sub-tab control for Safe Cleanup vs Unused Files
    $script:subTabControl = New-Object System.Windows.Forms.TabControl
    $script:subTabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:subTabControl.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    #region Safe Cleanup Tab
    $safeTab = New-Object System.Windows.Forms.TabPage
    $safeTab.Text = "Safe Cleanup"
    $safeTab.Padding = New-Object System.Windows.Forms.Padding(10)

    $safeLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $safeLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $safeLayout.RowCount = 4
    $safeLayout.ColumnCount = 1
    $safeLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 35))) | Out-Null
    $safeLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null
    $safeLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 45))) | Out-Null
    $safeLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null

    # Header with total
    $safeHeader = New-Object System.Windows.Forms.Panel
    $safeHeader.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:safeTotalLabel = New-Object System.Windows.Forms.Label
    $script:safeTotalLabel.Text = "Selected: 0 files (0 B) - Click Scan to analyze"
    $script:safeTotalLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:safeTotalLabel.AutoSize = $true
    $script:safeTotalLabel.Location = New-Object System.Drawing.Point(5, 8)
    $safeHeader.Controls.Add($script:safeTotalLabel)

    $safeLayout.Controls.Add($safeHeader, 0, 0)

    # Category ListView
    $listGroup = New-Object System.Windows.Forms.GroupBox
    $listGroup.Text = "Cleanup Categories"
    $listGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:categoryListView = New-Object System.Windows.Forms.ListView
    $script:categoryListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:categoryListView.View = [System.Windows.Forms.View]::Details
    $script:categoryListView.CheckBoxes = $true
    $script:categoryListView.FullRowSelect = $true
    $script:categoryListView.GridLines = $true
    $script:categoryListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:categoryListView.Columns.Add("Category", 250) | Out-Null
    $script:categoryListView.Columns.Add("Size", 100) | Out-Null
    $script:categoryListView.Columns.Add("Files", 80) | Out-Null
    $script:categoryListView.Columns.Add("Requires Admin", 100) | Out-Null

    # Populate categories
    foreach ($cat in $script:CleanupCategories) {
        $item = New-Object System.Windows.Forms.ListViewItem($cat.Name)
        $item.SubItems.Add("(not scanned)") | Out-Null
        $item.SubItems.Add("-") | Out-Null
        $item.SubItems.Add($(if ($cat.RequiresElevation) { "Yes" } else { "No" })) | Out-Null
        $item.Checked = $cat.DefaultChecked
        $item.Tag = $cat
        $script:categoryListView.Items.Add($item) | Out-Null
    }

    # Update total when checkboxes change
    $script:categoryListView.Add_ItemChecked({
        Update-SafeCleanupTotal
    })

    $listGroup.Controls.Add($script:categoryListView)
    $safeLayout.Controls.Add($listGroup, 0, 1)

    # Buttons panel
    $safeButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $safeButtonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $safeButtonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $safeButtonPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)

    $scanBtn = New-Object System.Windows.Forms.Button
    $scanBtn.Text = "Scan"
    $scanBtn.Width = 100
    $scanBtn.Height = 30
    $scanBtn.Add_Click({
        Start-AppActivity "Scanning cleanup categories..."
        $script:safeLogBox.Clear()

        $totalSize = 0
        $totalFiles = 0
        $index = 0

        foreach ($item in $script:categoryListView.Items) {
            $index++
            $cat = $item.Tag
            Set-AppProgress -Value $index -Maximum $script:categoryListView.Items.Count -Message "Scanning: $($cat.Name)"

            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:safeLogBox.AppendText("[$timestamp] Scanning $($cat.Name)...`r`n")
            [System.Windows.Forms.Application]::DoEvents()

            $sizeInfo = Get-CategorySize -Category $cat

            # Show debug info from the scan
            if ($sizeInfo.DebugInfo) {
                $script:safeLogBox.AppendText("$($sizeInfo.DebugInfo)`r`n")
            }

            if ($sizeInfo.AccessDenied) {
                $item.SubItems[1].Text = "(Access Denied)"
                $item.SubItems[2].Text = "-"
                $script:safeLogBox.AppendText("[$timestamp]   Result: Access Denied`r`n")
            }
            else {
                $item.SubItems[1].Text = Format-FileSize -Bytes $sizeInfo.TotalBytes
                $item.SubItems[2].Text = $sizeInfo.FileCount.ToString()
                $item.Tag = @{
                    Category = $cat
                    TotalBytes = $sizeInfo.TotalBytes
                    FileCount = $sizeInfo.FileCount
                }
                $script:safeLogBox.AppendText("[$timestamp]   Total: $($sizeInfo.FileCount) files ($(Format-FileSize -Bytes $sizeInfo.TotalBytes))`r`n")
            }
        }

        Update-SafeCleanupTotal
        Clear-AppStatus

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:safeLogBox.AppendText("[$timestamp] Scan complete.`r`n")
        Write-SessionLog -Message "Safe Cleanup scan completed" -Category "Disk Cleanup"
    })
    $safeButtonPanel.Controls.Add($scanBtn)

    $cleanBtn = New-Object System.Windows.Forms.Button
    $cleanBtn.Text = "Clean Selected"
    $cleanBtn.Width = 120
    $cleanBtn.Height = 30
    $cleanBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 230)
    $cleanBtn.Add_Click({
        # Get checked items with size info
        $checkedItems = @()
        $totalBytes = 0
        $totalFiles = 0
        $needsElevation = $false

        foreach ($item in $script:categoryListView.CheckedItems) {
            if ($item.Tag -is [hashtable] -and $item.Tag.TotalBytes) {
                $checkedItems += $item
                $totalBytes += $item.Tag.TotalBytes
                $totalFiles += $item.Tag.FileCount
                if ($item.Tag.Category.RequiresElevation) {
                    $needsElevation = $true
                }
            }
        }

        if ($checkedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "No categories selected or scan not performed.",
                "Nothing to Clean",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        # Confirmation
        $confirmMsg = "Delete approximately $totalFiles files ($(Format-FileSize -Bytes $totalBytes))?`n`nCategories:`n"
        foreach ($item in $checkedItems) {
            $confirmMsg += "  - $($item.Tag.Category.Name)`n"
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            $confirmMsg,
            "Confirm Cleanup",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        # Get credentials if needed
        $cred = $null
        if ($needsElevation) {
            $cred = Get-ElevatedCredential -Message "Enter admin credentials for system cleanup"
            if (-not $cred) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Cleanup cancelled - credentials required for system folders.",
                    "Cancelled",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                return
            }
        }

        Start-AppActivity "Cleaning up..."
        $totalFreed = 0
        $totalDeleted = 0
        $index = 0

        foreach ($item in $checkedItems) {
            $index++
            $cat = $item.Tag.Category
            Set-AppProgress -Value $index -Maximum $checkedItems.Count -Message "Cleaning: $($cat.Name)"

            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:safeLogBox.AppendText("[$timestamp] Cleaning $($cat.Name)...`r`n")
            [System.Windows.Forms.Application]::DoEvents()

            $cleanResult = Clear-Category -Category $cat -Credential $cred

            $totalFreed += $cleanResult.FreedBytes
            $totalDeleted += $cleanResult.DeletedCount

            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:safeLogBox.AppendText("[$timestamp]   Deleted: $($cleanResult.DeletedCount) files ($(Format-FileSize -Bytes $cleanResult.FreedBytes))`r`n")

            if ($cleanResult.Errors.Count -gt 0) {
                $script:safeLogBox.AppendText("[$timestamp]   Errors: $($cleanResult.Errors.Count)`r`n")
            }
        }

        Clear-AppStatus

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:safeLogBox.AppendText("[$timestamp] Cleanup complete! Freed $(Format-FileSize -Bytes $totalFreed) ($totalDeleted files)`r`n")
        Write-SessionLog -Message "Safe Cleanup: Freed $(Format-FileSize -Bytes $totalFreed) ($totalDeleted files)" -Category "Disk Cleanup"

        [System.Windows.Forms.MessageBox]::Show(
            "Cleanup complete!`n`nFreed: $(Format-FileSize -Bytes $totalFreed)`nFiles deleted: $totalDeleted",
            "Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        # Re-scan to update sizes
        $scanBtn.PerformClick()
    })
    $safeButtonPanel.Controls.Add($cleanBtn)

    $safeLayout.Controls.Add($safeButtonPanel, 0, 2)

    # Log output
    $safeLogGroup = New-Object System.Windows.Forms.GroupBox
    $safeLogGroup.Text = "Log"
    $safeLogGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:safeLogBox = New-Object System.Windows.Forms.TextBox
    $script:safeLogBox.Multiline = $true
    $script:safeLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:safeLogBox.ReadOnly = $true
    $script:safeLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:safeLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:safeLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:safeLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $safeLogGroup.Controls.Add($script:safeLogBox)
    $safeLayout.Controls.Add($safeLogGroup, 0, 3)

    $safeTab.Controls.Add($safeLayout)
    $script:subTabControl.TabPages.Add($safeTab)
    #endregion

    #region Unused Files Tab
    $unusedTab = New-Object System.Windows.Forms.TabPage
    $unusedTab.Text = "Large Unused Files"
    $unusedTab.Padding = New-Object System.Windows.Forms.Padding(10)

    $unusedLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $unusedLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $unusedLayout.RowCount = 4
    $unusedLayout.ColumnCount = 1
    $unusedLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 45))) | Out-Null
    $unusedLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null
    $unusedLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 45))) | Out-Null
    $unusedLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null

    # Filter controls
    $filterPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $filterPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $filterPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $filterPanel.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)

    $minSizeLabel = New-Object System.Windows.Forms.Label
    $minSizeLabel.Text = "Min Size (MB):"
    $minSizeLabel.AutoSize = $true
    $minSizeLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $filterPanel.Controls.Add($minSizeLabel)

    $script:minSizeBox = New-Object System.Windows.Forms.NumericUpDown
    $script:minSizeBox.Width = 80
    $script:minSizeBox.Minimum = 1
    $script:minSizeBox.Maximum = 10000
    $script:minSizeBox.Value = 100
    $filterPanel.Controls.Add($script:minSizeBox)

    $daysLabel = New-Object System.Windows.Forms.Label
    $daysLabel.Text = "    Days Unused:"
    $daysLabel.AutoSize = $true
    $daysLabel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 5, 0)
    $filterPanel.Controls.Add($daysLabel)

    $script:daysBox = New-Object System.Windows.Forms.NumericUpDown
    $script:daysBox.Width = 80
    $script:daysBox.Minimum = 1
    $script:daysBox.Maximum = 3650
    $script:daysBox.Value = 90
    $filterPanel.Controls.Add($script:daysBox)

    $scanUnusedBtn = New-Object System.Windows.Forms.Button
    $scanUnusedBtn.Text = "Scan C: Drive"
    $scanUnusedBtn.Width = 120
    $scanUnusedBtn.Height = 28
    $scanUnusedBtn.Margin = New-Object System.Windows.Forms.Padding(20, 0, 0, 0)
    $scanUnusedBtn.Add_Click({
        Start-AppActivity "Scanning for unused files... This may take a while."
        $script:unusedLogBox.Clear()
        $script:unusedListView.Items.Clear()

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:unusedLogBox.AppendText("[$timestamp] Scanning C: drive for files larger than $($script:minSizeBox.Value) MB not accessed in $($script:daysBox.Value) days...`r`n")
        $script:unusedLogBox.AppendText("[$timestamp] Excluding system folders (Windows, Program Files, ProgramData)...`r`n")
        [System.Windows.Forms.Application]::DoEvents()

        # Progress callback to update log in real-time
        $progressCallback = {
            param([string]$Message)
            $ts = Get-Date -Format "HH:mm:ss"
            $script:unusedLogBox.AppendText("[$ts] $Message`r`n")
            $script:unusedLogBox.ScrollToCaret()
        }

        $files = Find-UnusedFiles -MinSizeMB $script:minSizeBox.Value -DaysUnused $script:daysBox.Value -ProgressCallback $progressCallback

        # Populate ListView with results
        $script:unusedListView.BeginUpdate()
        foreach ($file in $files) {
            $item = New-Object System.Windows.Forms.ListViewItem("")
            $item.SubItems.Add($file.Path) | Out-Null
            $item.SubItems.Add($file.SizeFormatted) | Out-Null
            $item.SubItems.Add($file.LastAccessed.ToString("yyyy-MM-dd")) | Out-Null
            $item.SubItems.Add($file.Extension) | Out-Null
            $item.Tag = $file
            $script:unusedListView.Items.Add($item) | Out-Null
        }
        $script:unusedListView.EndUpdate()

        Clear-AppStatus
        Update-UnusedFilesTotal

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:unusedLogBox.AppendText("[$timestamp] Found $($files.Count) files matching criteria.`r`n")
    })
    $filterPanel.Controls.Add($scanUnusedBtn)

    $unusedLayout.Controls.Add($filterPanel, 0, 0)

    # Unused files ListView
    $unusedListGroup = New-Object System.Windows.Forms.GroupBox
    $unusedListGroup.Text = "Files Not Modified in 90+ Days"
    $unusedListGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:unusedListView = New-Object System.Windows.Forms.ListView
    $script:unusedListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:unusedListView.View = [System.Windows.Forms.View]::Details
    $script:unusedListView.CheckBoxes = $true
    $script:unusedListView.FullRowSelect = $true
    $script:unusedListView.GridLines = $true
    $script:unusedListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:unusedListView.Columns.Add("", 30) | Out-Null  # Checkbox column
    $script:unusedListView.Columns.Add("Path", 400) | Out-Null
    $script:unusedListView.Columns.Add("Size", 100) | Out-Null
    $script:unusedListView.Columns.Add("Last Modified", 100) | Out-Null
    $script:unusedListView.Columns.Add("Type", 80) | Out-Null

    # Enable column sorting
    $script:unusedListView.Add_ColumnClick({
        param($sender, $e)

        $col = $e.Column
        $items = @($script:unusedListView.Items)

        # Sort based on column
        switch ($col) {
            2 { # Size - sort by actual bytes
                $sorted = $items | Sort-Object { $_.Tag.Size } -Descending
            }
            3 { # Last Modified
                $sorted = $items | Sort-Object { $_.Tag.LastAccessed }
            }
            default {
                $sorted = $items | Sort-Object { $_.SubItems[$col].Text }
            }
        }

        $script:unusedListView.BeginUpdate()
        $script:unusedListView.Items.Clear()
        foreach ($item in $sorted) {
            $script:unusedListView.Items.Add($item) | Out-Null
        }
        $script:unusedListView.EndUpdate()
    })

    $script:unusedListView.Add_ItemChecked({
        Update-UnusedFilesTotal
    })

    $unusedListGroup.Controls.Add($script:unusedListView)
    $unusedLayout.Controls.Add($unusedListGroup, 0, 1)

    # Buttons and total
    $unusedButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $unusedButtonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $unusedButtonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $unusedButtonPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)

    $script:unusedTotalLabel = New-Object System.Windows.Forms.Label
    $script:unusedTotalLabel.Text = "Selected: 0 files (0 B)"
    $script:unusedTotalLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:unusedTotalLabel.AutoSize = $true
    $script:unusedTotalLabel.Padding = New-Object System.Windows.Forms.Padding(0, 7, 20, 0)
    $unusedButtonPanel.Controls.Add($script:unusedTotalLabel)

    $selectAllBtn = New-Object System.Windows.Forms.Button
    $selectAllBtn.Text = "Select All"
    $selectAllBtn.Width = 90
    $selectAllBtn.Height = 30
    $selectAllBtn.Add_Click({
        foreach ($item in $script:unusedListView.Items) {
            $item.Checked = $true
        }
    })
    $unusedButtonPanel.Controls.Add($selectAllBtn)

    $selectNoneBtn = New-Object System.Windows.Forms.Button
    $selectNoneBtn.Text = "Select None"
    $selectNoneBtn.Width = 90
    $selectNoneBtn.Height = 30
    $selectNoneBtn.Add_Click({
        foreach ($item in $script:unusedListView.Items) {
            $item.Checked = $false
        }
    })
    $unusedButtonPanel.Controls.Add($selectNoneBtn)

    $deleteBtn = New-Object System.Windows.Forms.Button
    $deleteBtn.Text = "Delete Selected"
    $deleteBtn.Width = 120
    $deleteBtn.Height = 30
    $deleteBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 230)
    $deleteBtn.Add_Click({
        $checkedItems = @($script:unusedListView.CheckedItems)

        if ($checkedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "No files selected.",
                "Nothing to Delete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        $totalSize = 0
        foreach ($item in $checkedItems) {
            $totalSize += $item.Tag.Size
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Permanently delete $($checkedItems.Count) files ($(Format-FileSize -Bytes $totalSize))?`n`nThis cannot be undone!",
            "Confirm Delete",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        Start-AppActivity "Deleting files..."
        $deleted = 0
        $freed = 0
        $errors = @()

        foreach ($item in $checkedItems) {
            $file = $item.Tag
            try {
                Remove-Item -Path $file.Path -Force -ErrorAction Stop
                $deleted++
                $freed += $file.Size
                $script:unusedListView.Items.Remove($item)

                $timestamp = Get-Date -Format "HH:mm:ss"
                $script:unusedLogBox.AppendText("[$timestamp] Deleted: $($file.Path)`r`n")
            }
            catch {
                $errors += $file.Path
                $timestamp = Get-Date -Format "HH:mm:ss"
                $script:unusedLogBox.AppendText("[$timestamp] ERROR: Could not delete $($file.Path) - $($_.Exception.Message)`r`n")
            }
        }

        Clear-AppStatus
        Update-UnusedFilesTotal

        Write-SessionLog -Message "Unused Files: Deleted $deleted files, freed $(Format-FileSize -Bytes $freed)" -Category "Disk Cleanup"

        $msg = "Deleted $deleted files, freed $(Format-FileSize -Bytes $freed)"
        if ($errors.Count -gt 0) {
            $msg += "`n`n$($errors.Count) files could not be deleted (may be in use)."
        }

        [System.Windows.Forms.MessageBox]::Show(
            $msg,
            "Delete Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $unusedButtonPanel.Controls.Add($deleteBtn)

    $unusedLayout.Controls.Add($unusedButtonPanel, 0, 2)

    # Log output
    $unusedLogGroup = New-Object System.Windows.Forms.GroupBox
    $unusedLogGroup.Text = "Log"
    $unusedLogGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:unusedLogBox = New-Object System.Windows.Forms.TextBox
    $script:unusedLogBox.Multiline = $true
    $script:unusedLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:unusedLogBox.ReadOnly = $true
    $script:unusedLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:unusedLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:unusedLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:unusedLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $unusedLogGroup.Controls.Add($script:unusedLogBox)
    $unusedLayout.Controls.Add($unusedLogGroup, 0, 3)

    $unusedTab.Controls.Add($unusedLayout)
    $script:subTabControl.TabPages.Add($unusedTab)
    #endregion

    $mainPanel.Controls.Add($script:subTabControl, 0, 0)
    $tab.Controls.Add($mainPanel)
}

#endregion

#endregion
