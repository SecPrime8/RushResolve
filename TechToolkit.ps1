<#
.SYNOPSIS
    Windows Tech Toolkit - Portable IT Technician Toolbox
.DESCRIPTION
    Modular PowerShell GUI application for IT technicians.
    Runs as standard user with on-demand credential elevation.
.NOTES
    Version: 2.0
    Author: Rush IT Field Services
    Requires: PowerShell 5.1+, Windows 10/11
#>

#region Assembly Loading
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
#endregion

#region Script Variables
$script:AppName = "Windows Tech Toolkit"
$script:AppVersion = "2.0"
$script:AppPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ModulesPath = Join-Path $script:AppPath "Modules"
$script:ConfigPath = Join-Path $script:AppPath "Config"
$script:SettingsFile = Join-Path $script:ConfigPath "settings.json"

# Credential caching (in-memory only, never persisted)
$script:CachedCredential = $null
$script:CacheCredentials = $false
#endregion

#region Settings Management
function Get-DefaultSettings {
    return @{
        global = @{
            cacheCredentials = $false
            windowWidth = 900
            windowHeight = 700
            lastTab = ""
        }
        modules = @{}
    }
}

function Load-Settings {
    if (Test-Path $script:SettingsFile) {
        try {
            $content = Get-Content $script:SettingsFile -Raw
            $script:Settings = $content | ConvertFrom-Json
            $script:CacheCredentials = $script:Settings.global.cacheCredentials
        }
        catch {
            Write-Warning "Failed to load settings, using defaults: $_"
            $script:Settings = Get-DefaultSettings
        }
    }
    else {
        $script:Settings = Get-DefaultSettings
        Save-Settings
    }
}

function Save-Settings {
    try {
        if (-not (Test-Path $script:ConfigPath)) {
            New-Item -Path $script:ConfigPath -ItemType Directory -Force | Out-Null
        }
        $script:Settings | ConvertTo-Json -Depth 5 | Set-Content $script:SettingsFile -Force
    }
    catch {
        Write-Warning "Failed to save settings: $_"
    }
}

function Get-ModuleSetting {
    param(
        [string]$ModuleName,
        [string]$Key,
        $Default = $null
    )
    if ($script:Settings.modules.$ModuleName -and $script:Settings.modules.$ModuleName.$Key) {
        return $script:Settings.modules.$ModuleName.$Key
    }
    return $Default
}

function Set-ModuleSetting {
    param(
        [string]$ModuleName,
        [string]$Key,
        $Value
    )
    if (-not $script:Settings.modules.$ModuleName) {
        $script:Settings.modules | Add-Member -NotePropertyName $ModuleName -NotePropertyValue @{} -Force
    }
    $script:Settings.modules.$ModuleName | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    Save-Settings
}
#endregion

#region Credential Elevation Helpers

# Check if currently running as administrator
function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Cache the elevation status at startup
$script:IsElevated = Test-IsElevated

function Get-ElevatedCredential {
    <#
    .SYNOPSIS
        Prompts for administrator credentials using Windows credential dialog.
    .PARAMETER Message
        Custom message to display in the credential dialog.
    .PARAMETER Force
        Bypass cached credentials and always prompt.
    .OUTPUTS
        PSCredential object or $null if cancelled.
    #>
    param(
        [string]$Message = "Enter administrator credentials",
        [switch]$Force
    )

    # Return cached credential if available and not forced
    if (-not $Force -and $script:CacheCredentials -and $script:CachedCredential) {
        return $script:CachedCredential
    }

    try {
        $cred = Get-Credential -Message $Message

        if ($cred -and $script:CacheCredentials) {
            $script:CachedCredential = $cred
        }

        return $cred
    }
    catch {
        return $null
    }
}

function Invoke-Elevated {
    <#
    .SYNOPSIS
        Runs a PowerShell script block with elevated credentials.
    .PARAMETER ScriptBlock
        The script block to execute.
    .PARAMETER Credential
        PSCredential to use. Will prompt if not provided.
    .PARAMETER ArgumentList
        Arguments to pass to the script block.
    .PARAMETER OperationName
        Friendly name for the operation (shown in credential prompt).
    .OUTPUTS
        Hashtable with Success, Error, Output, and ExitCode.
    #>
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$ScriptBlock,
        [PSCredential]$Credential,
        [object[]]$ArgumentList,
        [string]$OperationName = "this operation"
    )

    $result = @{
        Success = $false
        Error = $null
        Output = $null
        ExitCode = -1
    }

    # Get credentials if not provided
    if (-not $Credential) {
        $Credential = Get-ElevatedCredential -Message "Enter administrator credentials to $OperationName"
        if (-not $Credential) {
            $result.Error = "Operation cancelled by user"
            return $result
        }
    }

    try {
        # Create a temporary script file
        $tempScript = [System.IO.Path]::GetTempFileName() + ".ps1"

        # Write the script block to the temp file
        $scriptContent = @"
`$ErrorActionPreference = 'Stop'
try {
    `$output = & {
        $($ScriptBlock.ToString())
    } $($ArgumentList -join ' ')
    `$output | ConvertTo-Json -Depth 10 | Write-Output
    exit 0
}
catch {
    Write-Error `$_.Exception.Message
    exit 1
}
"@
        Set-Content -Path $tempScript -Value $scriptContent -Force

        # Run the script with credentials
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "powershell.exe"
        $processInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.CreateNoWindow = $true
        $processInfo.UserName = $Credential.UserName
        $processInfo.Password = $Credential.Password
        $processInfo.Domain = if ($Credential.UserName -match '\\') {
            ($Credential.UserName -split '\\')[0]
        } elseif ($Credential.UserName -match '@') {
            ($Credential.UserName -split '@')[1]
        } else {
            $env:USERDOMAIN
        }

        # Adjust username if domain was extracted
        if ($Credential.UserName -match '\\') {
            $processInfo.UserName = ($Credential.UserName -split '\\')[1]
        }
        elseif ($Credential.UserName -match '@') {
            $processInfo.UserName = ($Credential.UserName -split '@')[0]
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $process.Start() | Out-Null

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $result.ExitCode = $process.ExitCode

        if ($process.ExitCode -eq 0) {
            $result.Success = $true
            if ($stdout) {
                try {
                    $result.Output = $stdout | ConvertFrom-Json
                }
                catch {
                    $result.Output = $stdout
                }
            }
        }
        else {
            $result.Error = if ($stderr) { $stderr.Trim() } else { "Operation failed with exit code $($process.ExitCode)" }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        # Clean up temp file
        if (Test-Path $tempScript) {
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        }
    }

    return $result
}

function Start-ElevatedProcess {
    <#
    .SYNOPSIS
        Runs an executable with elevated credentials.
    .PARAMETER FilePath
        Path to the executable.
    .PARAMETER ArgumentList
        Arguments to pass to the executable.
    .PARAMETER Credential
        PSCredential to use. Will prompt if not provided.
    .PARAMETER Wait
        Wait for process to complete.
    .PARAMETER Hidden
        Run process hidden (no window).
    .PARAMETER OperationName
        Friendly name for the operation (shown in credential prompt).
    .OUTPUTS
        Hashtable with Success, Error, and ExitCode.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string]$ArgumentList = "",
        [PSCredential]$Credential,
        [switch]$Wait,
        [switch]$Hidden,
        [string]$OperationName = "this operation"
    )

    $result = @{
        Success = $false
        Error = $null
        ExitCode = -1
    }

    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $FilePath
        $processInfo.Arguments = $ArgumentList

        # If already running as admin, run directly without credentials
        if ($script:IsElevated) {
            $processInfo.UseShellExecute = $true
            # No credential needed
        }
        else {
            # Get credentials if not provided
            if (-not $Credential) {
                $Credential = Get-ElevatedCredential -Message "Enter administrator credentials to $OperationName"
                if (-not $Credential) {
                    $result.Error = "Operation cancelled by user"
                    return $result
                }
            }

            $processInfo.UseShellExecute = $false
            $processInfo.UserName = $Credential.UserName
            $processInfo.Password = $Credential.Password

            # Handle domain
            if ($Credential.UserName -match '\\') {
                $processInfo.Domain = ($Credential.UserName -split '\\')[0]
                $processInfo.UserName = ($Credential.UserName -split '\\')[1]
            }
            elseif ($Credential.UserName -match '@') {
                $processInfo.Domain = ($Credential.UserName -split '@')[1]
                $processInfo.UserName = ($Credential.UserName -split '@')[0]
            }
            else {
                $processInfo.Domain = $env:USERDOMAIN
            }
        }

        if ($Hidden) {
            $processInfo.CreateNoWindow = $true
            $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $process.Start() | Out-Null

        if ($Wait) {
            $process.WaitForExit()
            $result.ExitCode = $process.ExitCode
            $result.Success = ($process.ExitCode -eq 0)
            if (-not $result.Success) {
                $result.Error = "Process exited with code $($process.ExitCode)"
            }
        }
        else {
            $result.Success = $true
            $result.ExitCode = 0
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Clear-CachedCredentials {
    $script:CachedCredential = $null
    [System.Windows.Forms.MessageBox]::Show(
        "Cached credentials have been cleared.",
        "Credentials Cleared",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}
#endregion

#region Module Loading
function Get-Modules {
    <#
    .SYNOPSIS
        Discovers modules in the Modules folder.
    .OUTPUTS
        Array of module file paths, sorted by name.
    #>
    if (-not (Test-Path $script:ModulesPath)) {
        New-Item -Path $script:ModulesPath -ItemType Directory -Force | Out-Null
        return @()
    }

    return Get-ChildItem -Path $script:ModulesPath -Filter "*.ps1" | Sort-Object Name
}

function Load-Module {
    <#
    .SYNOPSIS
        Loads a single module and creates its tab.
    .PARAMETER ModuleFile
        FileInfo object for the module script.
    .PARAMETER TabControl
        The TabControl to add the module's tab to.
    #>
    param(
        [System.IO.FileInfo]$ModuleFile,
        [System.Windows.Forms.TabControl]$TabControl
    )

    try {
        # Clear module variables
        $script:ModuleName = $null
        $script:ModuleDescription = $null

        # Dot-source the module (this sets $ModuleName, $ModuleDescription, and defines Initialize-Module)
        . $ModuleFile.FullName

        # Validate module has required components
        if (-not $script:ModuleName) {
            throw "Module does not define `$ModuleName"
        }

        # Create tab page
        $tab = New-Object System.Windows.Forms.TabPage
        $tab.Text = $script:ModuleName
        if ($script:ModuleDescription) {
            $tab.ToolTipText = $script:ModuleDescription
        }
        $tab.Padding = New-Object System.Windows.Forms.Padding(10)

        # Call module's initialization function
        if (Get-Command -Name "Initialize-Module" -ErrorAction SilentlyContinue) {
            Initialize-Module -tab $tab
        }
        else {
            throw "Module does not define Initialize-Module function"
        }

        # Add tab to control
        $TabControl.TabPages.Add($tab)

        return $true
    }
    catch {
        Write-Warning "Failed to load module '$($ModuleFile.Name)': $_"
        return $false
    }
}
#endregion

#region UI Helper Functions
function New-OutputTextBox {
    <#
    .SYNOPSIS
        Creates a standard output textbox for module logging.
    .OUTPUTS
        TextBox control configured for log output.
    #>
    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $textBox.ReadOnly = $true
    $textBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $textBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $textBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $textBox.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $textBox.Height = 150
    return $textBox
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped message to a TextBox.
    .PARAMETER TextBox
        The TextBox to write to.
    .PARAMETER Message
        The message to write.
    #>
    param(
        [System.Windows.Forms.TextBox]$TextBox,
        [string]$Message
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    $TextBox.AppendText("[$timestamp] $Message`r`n")
    $TextBox.ScrollToCaret()
}

function New-Button {
    <#
    .SYNOPSIS
        Creates a standard button with consistent styling.
    #>
    param(
        [string]$Text,
        [int]$Width = 120,
        [int]$Height = 30,
        [switch]$RequiresElevation
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = if ($RequiresElevation) { "$Text" } else { $Text }
    $button.Width = $Width
    $button.Height = $Height
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    if ($RequiresElevation) {
        $button.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 180, 100)
    }

    return $button
}
#endregion

#region Main Window
function Show-MainWindow {
    # Load settings first
    Load-Settings

    # Create main form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($script:AppName) v$($script:AppVersion)"
    $form.Size = New-Object System.Drawing.Size(
        $script:Settings.global.windowWidth,
        $script:Settings.global.windowHeight
    )
    $form.MinimumSize = New-Object System.Drawing.Size(900, 700)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Icon = [System.Drawing.SystemIcons]::Application

    # Menu strip
    $menuStrip = New-Object System.Windows.Forms.MenuStrip

    # Tools menu
    $toolsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $toolsMenu.Text = "&Tools"

    # Credential Options submenu
    $credentialMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $credentialMenu.Text = "Credential Options"

    # Cache credentials checkbox
    $cacheMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $cacheMenuItem.Text = "Cache Credentials (Session Only)"
    $cacheMenuItem.CheckOnClick = $true
    $cacheMenuItem.Checked = $script:CacheCredentials
    $cacheMenuItem.Add_Click({
        $script:CacheCredentials = $cacheMenuItem.Checked
        $script:Settings.global.cacheCredentials = $script:CacheCredentials
        Save-Settings
        if (-not $script:CacheCredentials) {
            $script:CachedCredential = $null
        }
    })
    $credentialMenu.DropDownItems.Add($cacheMenuItem) | Out-Null

    # Clear cached credentials
    $clearCredMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $clearCredMenuItem.Text = "Clear Cached Credentials"
    $clearCredMenuItem.Add_Click({ Clear-CachedCredentials })
    $credentialMenu.DropDownItems.Add($clearCredMenuItem) | Out-Null

    $toolsMenu.DropDownItems.Add($credentialMenu) | Out-Null

    # Separator
    $toolsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Refresh modules
    $refreshMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $refreshMenuItem.Text = "Refresh Modules"
    $refreshMenuItem.Add_Click({
        [System.Windows.Forms.MessageBox]::Show(
            "Please restart the application to reload modules.",
            "Refresh Modules",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $toolsMenu.DropDownItems.Add($refreshMenuItem) | Out-Null

    $menuStrip.Items.Add($toolsMenu) | Out-Null

    # Help menu
    $helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $helpMenu.Text = "&Help"

    $aboutMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $aboutMenuItem.Text = "About"
    $aboutMenuItem.Add_Click({
        [System.Windows.Forms.MessageBox]::Show(
            "$($script:AppName) v$($script:AppVersion)`n`nPortable IT Technician Toolkit`nRush University Medical Center`n`nRunning as: $env:USERDOMAIN\$env:USERNAME",
            "About",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })
    $helpMenu.DropDownItems.Add($aboutMenuItem) | Out-Null

    $menuStrip.Items.Add($helpMenu) | Out-Null

    $form.MainMenuStrip = $menuStrip
    $form.Controls.Add($menuStrip)

    # Tab control
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $tabControl.ShowToolTips = $true
    $tabControl.ItemSize = New-Object System.Drawing.Size(130, 30)
    $tabControl.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed

    # Status strip (bottom bar)
    $statusStrip = New-Object System.Windows.Forms.StatusStrip

    $userLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $userLabel.Text = "Running as: $env:USERDOMAIN\$env:USERNAME"
    $userLabel.Spring = $true
    $userLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusStrip.Items.Add($userLabel) | Out-Null

    $versionLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $versionLabel.Text = "v$($script:AppVersion)"
    $versionLabel.ForeColor = [System.Drawing.Color]::Gray
    $statusStrip.Items.Add($versionLabel) | Out-Null

    # Panel to hold tab control (between menu and status bar)
    $mainPanel = New-Object System.Windows.Forms.Panel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.Padding = New-Object System.Windows.Forms.Padding(10, 35, 10, 5)
    $mainPanel.Controls.Add($tabControl)

    # Add controls in correct order (top to bottom)
    $form.Controls.Add($mainPanel)
    $form.Controls.Add($statusStrip)

    # Load modules
    $modules = Get-Modules
    $loadedCount = 0

    foreach ($module in $modules) {
        if (Load-Module -ModuleFile $module -TabControl $tabControl) {
            $loadedCount++
        }
    }

    # If no modules loaded, show a welcome tab
    if ($loadedCount -eq 0) {
        $welcomeTab = New-Object System.Windows.Forms.TabPage
        $welcomeTab.Text = "Welcome"
        $welcomeTab.Padding = New-Object System.Windows.Forms.Padding(20)

        $welcomeLabel = New-Object System.Windows.Forms.Label
        $welcomeLabel.Text = @"
Welcome to $($script:AppName)!

No modules were found in the Modules folder.

To add functionality:
1. Create a .ps1 file in the Modules folder
2. Define `$ModuleName and `$ModuleDescription variables
3. Define an Initialize-Module function
4. Restart this application

Example module structure:
`$ModuleName = "My Module"
`$ModuleDescription = "Does something useful"

function Initialize-Module {
    param([System.Windows.Forms.TabPage]`$tab)
    # Add your UI controls here
}
"@
        $welcomeLabel.AutoSize = $true
        $welcomeLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11)
        $welcomeLabel.Location = New-Object System.Drawing.Point(20, 20)
        $welcomeTab.Controls.Add($welcomeLabel)

        $tabControl.TabPages.Add($welcomeTab)
    }

    # Save window size on close
    $form.Add_FormClosing({
        $script:Settings.global.windowWidth = $form.Width
        $script:Settings.global.windowHeight = $form.Height
        if ($tabControl.SelectedTab) {
            $script:Settings.global.lastTab = $tabControl.SelectedTab.Text
        }
        Save-Settings
    })

    # Restore last tab
    if ($script:Settings.global.lastTab) {
        foreach ($tab in $tabControl.TabPages) {
            if ($tab.Text -eq $script:Settings.global.lastTab) {
                $tabControl.SelectedTab = $tab
                break
            }
        }
    }

    # Show form
    [void]$form.ShowDialog()
}
#endregion

#region Main Entry Point
# Run the application
Show-MainWindow
#endregion
