<#
.SYNOPSIS
    Disk Cleanup Module - Clean temp files and remove old user profiles
.DESCRIPTION
    Two-tab module:
    1. Safe Cleanup - Automated cleanup of known-safe temp/cache locations
    2. Profile Cleanup - Remove old user profiles with bulk selection options
.NOTES
    Requires elevation for system folder cleanup and profile deletion
#>

$script:ModuleName = "Disk Cleanup"
$script:ModuleDescription = "Clean temp files and remove old user profiles"

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

#endregion

#region Helper Functions

# Invoke-Elevated returns its payload via ConvertTo-Json | ConvertFrom-Json, so
# .Output is a PSCustomObject - which has no .ContainsKey() and no string indexer.
# Calling .ContainsKey() on it threw and broke BOTH scan buttons whenever the tech
# actually supplied credentials (cancelling the prompt left the @{} literal in
# place, so the buttons only "worked" when you declined to authenticate).
# These helpers accept either shape.
$script:MapHasKey = {
    param($Map, [string]$Key)
    if ($null -eq $Map) { return $false }
    if ($Map -is [System.Collections.IDictionary]) { return $Map.Contains($Key) }
    return ($null -ne $Map.PSObject.Properties[$Key])
}

$script:MapGet = {
    param($Map, [string]$Key)
    if ($null -eq $Map) { return $null }
    if ($Map -is [System.Collections.IDictionary]) { return $Map[$Key] }
    $prop = $Map.PSObject.Properties[$Key]
    if ($prop) { return $prop.Value }
    return $null
}

$script:FormatFileSize = {
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

$script:GetCategorySize = {
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

            $debugLines += "    Found: $filesFoundInPath files ($(& $script:FormatFileSize -Bytes $bytesInPath))"
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

$script:ClearCategory = {
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

$script:GetAllProfiles = {
    # Returns ALL non-system, non-current-user profiles (no age filtering)
    $currentUser = $env:USERNAME
    $results = @()

    try {
        # Get all non-system profiles
        $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop | Where-Object {
            -not $_.Special -and
            $_.LocalPath -notmatch '\\(Default|Public|Default User|All Users)$' -and
            $_.LocalPath -notmatch "\\$currentUser$"
        }

        foreach ($userProfile in $profiles) {
            # Skip loaded profiles (user has active session)
            if ($userProfile.Loaded) { continue }

            # Determine last use: prefer LastUseTime, fallback to folder modification date
            $lastUsed = $userProfile.LastUseTime
            if (-not $lastUsed -and $userProfile.LocalPath -and (Test-Path $userProfile.LocalPath)) {
                $lastUsed = (Get-Item $userProfile.LocalPath -Force).LastWriteTime
            }

            # If we still can't determine, use a very old date
            if (-not $lastUsed) {
                $lastUsed = [datetime]::MinValue
            }

            $username = Split-Path $userProfile.LocalPath -Leaf
            $daysOld = if ($lastUsed -eq [datetime]::MinValue) { 9999 } else { [math]::Floor(((Get-Date) - $lastUsed).TotalDays) }

            $results += [PSCustomObject]@{
                Username = $username
                Path = $userProfile.LocalPath
                SID = $userProfile.SID
                LastUsed = $lastUsed
                Size = [long]0
                SizeFormatted = "..."
                DaysOld = $daysOld
            }
        }
    }
    catch {
        Write-Warning "Failed to query profiles: $($_.Exception.Message)"
    }

    return $results | Sort-Object -Property DaysOld -Descending
}

$script:RemoveUserProfile = {
    param(
        [string]$SID,
        [PSCredential]$Credential
    )

    $result = @{
        Success = $false
        Error = $null
    }

    try {
        $deleteResult = Invoke-Elevated -ScriptBlock {
            param($sid)
            $userProfile = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.SID -eq $sid }
            if ($userProfile) {
                Remove-CimInstance -InputObject $userProfile -ErrorAction Stop
                return $true
            }
            return $false
        } -ArgumentList $SID -Credential $Credential -OperationName "delete user profile"

        $result.Success = $deleteResult.Success
        $result.Error = $deleteResult.Error
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

#endregion

#region UI Helper Functions

$script:UpdateSafeCleanupTotal = {
    $totalBytes = 0
    $totalFiles = 0

    foreach ($item in $script:categoryListView.CheckedItems) {
        if ($item.Tag -is [hashtable] -and $item.Tag.TotalBytes) {
            $totalBytes += $item.Tag.TotalBytes
            $totalFiles += $item.Tag.FileCount
        }
    }

    $script:safeTotalLabel.Text = "Selected: $totalFiles files ($(& $script:FormatFileSize -Bytes $totalBytes))"
}

$script:UpdateProfileTotal = {
    $totalBytes = 0
    $count = 0

    foreach ($item in $script:Disk_profileListView.CheckedItems) {
        $totalBytes += $item.Tag.Size
        $count++
    }

    $script:profileTotalLabel.Text = "Selected: $count profiles ($(& $script:FormatFileSize -Bytes $totalBytes))"

    # Update delete button text with count
    if ($script:deleteProfilesBtn) {
        if ($count -gt 0) {
            $script:deleteProfilesBtn.Text = "Delete Selected ($count)"
        } else {
            $script:deleteProfilesBtn.Text = "Delete Selected"
        }
    }
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
        & $script:UpdateSafeCleanupTotal
    })

    $listGroup.Controls.Add($script:categoryListView)
    $safeLayout.Controls.Add($listGroup, 0, 1)

    # Buttons panel
    $safeButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $safeButtonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $safeButtonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $safeButtonPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)

    $script:safeScanBtn = New-Object System.Windows.Forms.Button
    $script:safeScanBtn.Text = "Scan"
    $script:safeScanBtn.Width = 100
    $script:safeScanBtn.Height = 30
    $script:safeScanBtn.Add_Click({
        Start-AppActivity "Scanning cleanup categories..."
        $script:safeLogBox.Clear()

        # Check if any categories need elevation
        $needsElevation = $false
        foreach ($item in $script:categoryListView.Items) {
            $cat = if ($item.Tag.Category) { $item.Tag.Category } else { $item.Tag }
            if ($cat.RequiresElevation) { $needsElevation = $true; break }
        }

        # Batch scan elevated categories in one elevated call for efficiency
        $elevatedSizes = @{}
        if ($needsElevation) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:safeLogBox.AppendText("[$timestamp] Some categories require admin access for accurate sizes...`r`n")
            [System.Windows.Forms.Application]::DoEvents()

            # Build list of elevated scan targets
            $elevatedTargets = @()
            foreach ($item in $script:categoryListView.Items) {
                $cat = if ($item.Tag.Category) { $item.Tag.Category } else { $item.Tag }
                if ($cat.RequiresElevation -and -not $cat.IsRecycleBin) {
                    $elevatedTargets += @{
                        Name = $cat.Name
                        Paths = $cat.Paths
                        Pattern = $cat.Pattern
                        MaxAgeDays = $cat.MaxAgeDays
                        Recurse = [bool]$cat.Recurse
                        AdditionalPatterns = $cat.AdditionalPatterns
                        IncludeFiles = $cat.IncludeFiles
                    }
                }
            }

            if ($elevatedTargets.Count -gt 0) {
                $elevResult = Invoke-Elevated -ScriptBlock {
                    param($targets)
                    $results = @{}
                    foreach ($t in $targets) {
                        $totalBytes = 0
                        $fileCount = 0
                        foreach ($basePath in $t.Paths) {
                            $expandedPath = [Environment]::ExpandEnvironmentVariables($basePath)
                            if (-not (Test-Path $expandedPath)) { continue }
                            $pattern = if ($t.Pattern) { $t.Pattern } else { "*" }
                            $recurse = $t.Recurse
                            $cutoffDate = if ($t.MaxAgeDays -gt 0) { (Get-Date).AddDays(-$t.MaxAgeDays) } else { $null }
                            $files = @(Get-ChildItem -Path $expandedPath -Filter $pattern -File -Recurse:$recurse -Force -ErrorAction SilentlyContinue)
                            if ($t.AdditionalPatterns) {
                                foreach ($ap in $t.AdditionalPatterns) {
                                    $files += @(Get-ChildItem -Path $expandedPath -Filter $ap -File -Recurse:$recurse -Force -ErrorAction SilentlyContinue)
                                }
                            }
                            foreach ($f in $files) {
                                if ($cutoffDate -and $f.LastWriteTime -gt $cutoffDate) { continue }
                                $totalBytes += $f.Length
                                $fileCount++
                            }
                        }
                        if ($t.IncludeFiles) {
                            foreach ($fp in $t.IncludeFiles) {
                                if (Test-Path $fp) {
                                    try {
                                        $fi = Get-Item $fp -Force -ErrorAction SilentlyContinue
                                        if ($fi) { $totalBytes += $fi.Length; $fileCount++ }
                                    } catch {}
                                }
                            }
                        }
                        $results[$t.Name] = @{ TotalBytes = $totalBytes; FileCount = $fileCount }
                    }
                    return $results
                } -ArgumentList @(,$elevatedTargets) -OperationName "scan system folders"

                if ($elevResult.Success -and $elevResult.Output) {
                    $elevatedSizes = $elevResult.Output
                }
            }
        }

        $totalSize = 0
        $totalFiles = 0
        $index = 0

        foreach ($item in $script:categoryListView.Items) {
            $index++
            $cat = if ($item.Tag.Category) { $item.Tag.Category } else { $item.Tag }
            Set-AppProgress -Value $index -Maximum $script:categoryListView.Items.Count -Message "Scanning: $($cat.Name)"

            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:safeLogBox.AppendText("[$timestamp] Scanning $($cat.Name)...`r`n")
            [System.Windows.Forms.Application]::DoEvents()

            # Use elevated results for elevated categories, local scan for others
            if ($cat.RequiresElevation -and -not $cat.IsRecycleBin -and (& $script:MapHasKey $elevatedSizes $cat.Name)) {
                $elevEntry = & $script:MapGet $elevatedSizes $cat.Name
                $sizeInfo = @{
                    TotalBytes = $elevEntry.TotalBytes
                    FileCount = $elevEntry.FileCount
                    AccessDenied = $false
                    DebugInfo = "  Scanned with elevation"
                }
            } else {
                $sizeInfo = & $script:GetCategorySize -Category $cat
            }

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
                $item.SubItems[1].Text = & $script:FormatFileSize -Bytes $sizeInfo.TotalBytes
                $item.SubItems[2].Text = $sizeInfo.FileCount.ToString()
                $item.Tag = @{
                    Category = $cat
                    TotalBytes = $sizeInfo.TotalBytes
                    FileCount = $sizeInfo.FileCount
                }
                $script:safeLogBox.AppendText("[$timestamp]   Total: $($sizeInfo.FileCount) files ($(& $script:FormatFileSize -Bytes $sizeInfo.TotalBytes))`r`n")
            }
        }

        & $script:UpdateSafeCleanupTotal
        Clear-AppStatus

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:safeLogBox.AppendText("[$timestamp] Scan complete.`r`n")
        Write-SessionLog -Message "Safe Cleanup scan completed" -Category "Disk Cleanup"
    })
    $safeButtonPanel.Controls.Add($script:safeScanBtn)

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
        $confirmMsg = "Delete approximately $totalFiles files ($(& $script:FormatFileSize -Bytes $totalBytes))?`n`nCategories:`n"
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

            $cleanResult = & $script:ClearCategory -Category $cat -Credential $cred

            $totalFreed += $cleanResult.FreedBytes
            $totalDeleted += $cleanResult.DeletedCount

            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:safeLogBox.AppendText("[$timestamp]   Deleted: $($cleanResult.DeletedCount) files ($(& $script:FormatFileSize -Bytes $cleanResult.FreedBytes))`r`n")

            if ($cleanResult.Errors.Count -gt 0) {
                $script:safeLogBox.AppendText("[$timestamp]   Errors: $($cleanResult.Errors.Count)`r`n")
            }
        }

        Clear-AppStatus

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:safeLogBox.AppendText("[$timestamp] Cleanup complete! Freed $(& $script:FormatFileSize -Bytes $totalFreed) ($totalDeleted files)`r`n")
        Write-SessionLog -Message "Safe Cleanup: Freed $(& $script:FormatFileSize -Bytes $totalFreed) ($totalDeleted files)" -Category "Disk Cleanup"

        [System.Windows.Forms.MessageBox]::Show(
            "Cleanup complete!`n`nFreed: $(& $script:FormatFileSize -Bytes $totalFreed)`nFiles deleted: $totalDeleted",
            "Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        # Re-scan to update sizes
        $script:safeScanBtn.PerformClick()
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

    #region Profile Cleanup Tab
    $profileTab = New-Object System.Windows.Forms.TabPage
    $profileTab.Text = "Profile Cleanup"
    $profileTab.Padding = New-Object System.Windows.Forms.Padding(10)

    $profileLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $profileLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $profileLayout.RowCount = 4
    $profileLayout.ColumnCount = 1
    $profileLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 45))) | Out-Null
    $profileLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 60))) | Out-Null
    $profileLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 45))) | Out-Null
    $profileLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null

    # Top button panel with selection buttons
    $profileTopPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $profileTopPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $profileTopPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $profileTopPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)

    $scanProfilesBtn = New-Object System.Windows.Forms.Button
    $scanProfilesBtn.Text = "Scan Profiles"
    $scanProfilesBtn.Width = 110
    $scanProfilesBtn.Height = 30
    $scanProfilesBtn.Add_Click({
        Start-AppActivity "Scanning user profiles..."
        $script:profileLogBox.Clear()
        $script:Disk_profileListView.Items.Clear()

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:profileLogBox.AppendText("[$timestamp] Scanning for all non-system user profiles...`r`n")
        $script:profileLogBox.AppendText("[$timestamp] Excluding: current user ($env:USERNAME), system profiles, loaded profiles`r`n")
        [System.Windows.Forms.Application]::DoEvents()

        # Get profile list (works without elevation)
        $profiles = & $script:GetAllProfiles

        if ($profiles -and $profiles.Count -gt 0) {
            # Get elevation for accurate size calculation on other users' folders
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:profileLogBox.AppendText("[$timestamp] Calculating profile sizes (requires elevation)...`r`n")
            [System.Windows.Forms.Application]::DoEvents()

            $profilePaths = @($profiles | ForEach-Object { $_.Path })
            $sizeResult = Invoke-Elevated -ScriptBlock {
                param($paths)
                $sizes = @{}
                foreach ($p in $paths) {
                    if (Test-Path $p) {
                        try {
                            $sum = (Get-ChildItem -Path $p -Recurse -Force -ErrorAction SilentlyContinue |
                                Measure-Object -Property Length -Sum).Sum
                            $sizes[$p] = if ($sum) { $sum } else { 0 }
                        } catch {
                            $sizes[$p] = 0
                        }
                    } else {
                        $sizes[$p] = 0
                    }
                }
                return $sizes
            } -ArgumentList @(,$profilePaths) -OperationName "calculate profile sizes"

            # Apply sizes back to profile objects
            if ($sizeResult.Success -and $sizeResult.Output) {
                $sizeMap = $sizeResult.Output
                foreach ($userProfile in $profiles) {
                    if (& $script:MapHasKey $sizeMap $userProfile.Path) {
                        $userProfile.Size = [long](& $script:MapGet $sizeMap $userProfile.Path)
                        $userProfile.SizeFormatted = & $script:FormatFileSize -Bytes $userProfile.Size
                    }
                }
            } else {
                $timestamp = Get-Date -Format "HH:mm:ss"
                $script:profileLogBox.AppendText("[$timestamp] Warning: Could not calculate sizes - $($sizeResult.Error)`r`n")
            }
        }

        # Populate ListView with ALL profiles
        $script:Disk_profileListView.BeginUpdate()
        foreach ($userProfile in $profiles) {
            $item = New-Object System.Windows.Forms.ListViewItem("")
            $item.SubItems.Add($userProfile.Username) | Out-Null
            $item.SubItems.Add($userProfile.LastUsed.ToString("yyyy-MM-dd")) | Out-Null
            $item.SubItems.Add($userProfile.SizeFormatted) | Out-Null
            $item.SubItems.Add($userProfile.DaysOld.ToString()) | Out-Null
            $item.Tag = $userProfile
            $script:Disk_profileListView.Items.Add($item) | Out-Null
        }
        $script:Disk_profileListView.EndUpdate()

        Clear-AppStatus
        & $script:UpdateProfileTotal

        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:profileLogBox.AppendText("[$timestamp] Found $($profiles.Count) user profiles.`r`n")

        if ($profiles.Count -eq 0) {
            $script:profileLogBox.AppendText("[$timestamp] No profiles found (only current user exists).`r`n")
        }
    })
    $profileTopPanel.Controls.Add($scanProfilesBtn)

    # Separator label
    $separatorLabel = New-Object System.Windows.Forms.Label
    $separatorLabel.Text = "  |  "
    $separatorLabel.AutoSize = $true
    $separatorLabel.Padding = New-Object System.Windows.Forms.Padding(5, 8, 5, 0)
    $profileTopPanel.Controls.Add($separatorLabel)

    $select30Btn = New-Object System.Windows.Forms.Button
    $select30Btn.Text = "Select 30+ Days"
    $select30Btn.Width = 135
    $select30Btn.Height = 30
    $select30Btn.Add_Click({
        foreach ($item in $script:Disk_profileListView.Items) {
            $item.Checked = ($item.Tag.DaysOld -ge 30)
        }
    })
    $profileTopPanel.Controls.Add($select30Btn)

    $select90Btn = New-Object System.Windows.Forms.Button
    $select90Btn.Text = "Select 90+ Days"
    $select90Btn.Width = 135
    $select90Btn.Height = 30
    $select90Btn.Add_Click({
        foreach ($item in $script:Disk_profileListView.Items) {
            $item.Checked = ($item.Tag.DaysOld -ge 90)
        }
    })
    $profileTopPanel.Controls.Add($select90Btn)

    $clearAllBtn = New-Object System.Windows.Forms.Button
    $clearAllBtn.Text = "Clear All"
    $clearAllBtn.Width = 90
    $clearAllBtn.Height = 30
    $clearAllBtn.Add_Click({
        foreach ($item in $script:Disk_profileListView.Items) {
            $item.Checked = $false
        }
    })
    $profileTopPanel.Controls.Add($clearAllBtn)

    $profileLayout.Controls.Add($profileTopPanel, 0, 0)

    # Profile ListView
    $profileListGroup = New-Object System.Windows.Forms.GroupBox
    $profileListGroup.Text = "User Profiles"
    $profileListGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:Disk_profileListView = New-Object System.Windows.Forms.ListView
    $script:Disk_profileListView.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:Disk_profileListView.View = [System.Windows.Forms.View]::Details
    $script:Disk_profileListView.CheckBoxes = $true
    $script:Disk_profileListView.FullRowSelect = $true
    $script:Disk_profileListView.GridLines = $true
    $script:Disk_profileListView.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $script:Disk_profileListView.Columns.Add("", 30) | Out-Null  # Checkbox column
    $script:Disk_profileListView.Columns.Add("Username", 180) | Out-Null
    $script:Disk_profileListView.Columns.Add("Last Used", 100) | Out-Null
    $script:Disk_profileListView.Columns.Add("Size", 90) | Out-Null
    $script:Disk_profileListView.Columns.Add("Days Old", 80) | Out-Null

    # Enable column sorting
    $script:Disk_profileListView.Add_ColumnClick({
        param($sender, $e)

        $col = $e.Column
        $items = @($script:Disk_profileListView.Items)

        # Sort based on column
        switch ($col) {
            2 { # Last Used - sort by date
                $sorted = $items | Sort-Object { $_.Tag.LastUsed }
            }
            3 { # Size - sort by actual bytes
                $sorted = $items | Sort-Object { $_.Tag.Size } -Descending
            }
            4 { # Days Old - sort numerically
                $sorted = $items | Sort-Object { $_.Tag.DaysOld } -Descending
            }
            default {
                $sorted = $items | Sort-Object { $_.SubItems[$col].Text }
            }
        }

        $script:Disk_profileListView.BeginUpdate()
        $script:Disk_profileListView.Items.Clear()
        foreach ($item in $sorted) {
            $script:Disk_profileListView.Items.Add($item) | Out-Null
        }
        $script:Disk_profileListView.EndUpdate()
    })

    $script:Disk_profileListView.Add_ItemChecked({
        & $script:UpdateProfileTotal
    })

    $profileListGroup.Controls.Add($script:Disk_profileListView)
    $profileLayout.Controls.Add($profileListGroup, 0, 1)

    # Bottom panel with total and delete button
    $profileButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $profileButtonPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $profileButtonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $profileButtonPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)

    $script:profileTotalLabel = New-Object System.Windows.Forms.Label
    $script:profileTotalLabel.Text = "Selected: 0 profiles (0 B)"
    $script:profileTotalLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:profileTotalLabel.AutoSize = $true
    $script:profileTotalLabel.Padding = New-Object System.Windows.Forms.Padding(0, 7, 20, 0)
    $profileButtonPanel.Controls.Add($script:profileTotalLabel)

    $script:deleteProfilesBtn = New-Object System.Windows.Forms.Button
    $script:deleteProfilesBtn.Text = "Delete Selected"
    $script:deleteProfilesBtn.Width = 130
    $script:deleteProfilesBtn.Height = 30
    $script:deleteProfilesBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 230)
    $script:deleteProfilesBtn.Add_Click({
        $checkedItems = @($script:Disk_profileListView.CheckedItems)

        if ($checkedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "No profiles selected.",
                "Nothing to Delete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        # Build confirmation message with usernames
        $totalSize = 0
        $usernames = @()
        foreach ($item in $checkedItems) {
            $totalSize += $item.Tag.Size
            $usernames += $item.Tag.Username
        }

        $confirmMsg = "Permanently delete $($checkedItems.Count) user profile(s) ($(& $script:FormatFileSize -Bytes $totalSize))?`n`n"
        $confirmMsg += "Profiles to delete:`n"
        foreach ($u in $usernames) {
            $confirmMsg += "  - $u`n"
        }
        $confirmMsg += "`nThis will remove:`n  - User folders from C:\Users`n  - Registry entries`n  - Profile settings`n`nThis cannot be undone!"

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            $confirmMsg,
            "Confirm Profile Deletion",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        # Get elevated credentials
        $cred = Get-ElevatedCredential -Message "Enter admin credentials to delete user profiles"
        if (-not $cred) {
            [System.Windows.Forms.MessageBox]::Show(
                "Profile deletion cancelled - admin credentials required.",
                "Cancelled",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        Start-AppActivity "Deleting user profiles..."
        $deleted = 0
        $freed = 0
        $errors = @()

        foreach ($item in $checkedItems) {
            $userProfile = $item.Tag

            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:profileLogBox.AppendText("[$timestamp] Deleting profile: $($userProfile.Username)...`r`n")
            [System.Windows.Forms.Application]::DoEvents()

            $result = & $script:RemoveUserProfile -SID $userProfile.SID -Credential $cred

            if ($result.Success) {
                $deleted++
                $freed += $userProfile.Size
                $script:Disk_profileListView.Items.Remove($item)

                $timestamp = Get-Date -Format "HH:mm:ss"
                $script:profileLogBox.AppendText("[$timestamp]   SUCCESS: Deleted $($userProfile.Username)`r`n")
            }
            else {
                $errors += $userProfile.Username
                $timestamp = Get-Date -Format "HH:mm:ss"
                $script:profileLogBox.AppendText("[$timestamp]   ERROR: $($userProfile.Username) - $($result.Error)`r`n")
            }
        }

        Clear-AppStatus
        & $script:UpdateProfileTotal

        Write-SessionLog -Message "Profile Cleanup: Deleted $deleted profiles, freed $(& $script:FormatFileSize -Bytes $freed)" -Category "Disk Cleanup"

        $msg = "Deleted $deleted profile(s), freed $(& $script:FormatFileSize -Bytes $freed)"
        if ($errors.Count -gt 0) {
            $msg += "`n`n$($errors.Count) profile(s) could not be deleted:`n"
            foreach ($e in $errors) {
                $msg += "  - $e`n"
            }
        }

        [System.Windows.Forms.MessageBox]::Show(
            $msg,
            "Profile Deletion Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $profileButtonPanel.Controls.Add($script:deleteProfilesBtn)

    $profileLayout.Controls.Add($profileButtonPanel, 0, 2)

    # Log output
    $profileLogGroup = New-Object System.Windows.Forms.GroupBox
    $profileLogGroup.Text = "Log"
    $profileLogGroup.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:profileLogBox = New-Object System.Windows.Forms.TextBox
    $script:profileLogBox.Multiline = $true
    $script:profileLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:profileLogBox.ReadOnly = $true
    $script:profileLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:profileLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:profileLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:profileLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

    $profileLogGroup.Controls.Add($script:profileLogBox)
    $profileLayout.Controls.Add($profileLogGroup, 0, 3)

    $profileTab.Controls.Add($profileLayout)
    $script:subTabControl.TabPages.Add($profileTab)
    #endregion

    $mainPanel.Controls.Add($script:subTabControl, 0, 0)
    $tab.Controls.Add($mainPanel)
}

#endregion

#endregion
