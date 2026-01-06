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

# Credential caching with PIN protection
$script:CachedCredential = $null          # Encrypted credential blob (or decrypted PSCredential when unlocked)
$script:CacheCredentials = $false         # Whether caching is enabled
$script:CredentialPINHash = $null         # SHA256 hash of PIN
$script:PINLastVerified = $null           # DateTime of last successful PIN entry
$script:PINTimeout = 15                   # Minutes before PIN re-required
$script:PINFailCount = 0                  # Track failed PIN attempts
$script:CredentialFile = Join-Path $script:ConfigPath "credential.dat"
$script:PINFile = Join-Path $script:ConfigPath "credential.pin"
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

#region PIN-Protected Credential Cache

# Add required assembly for DPAPI
Add-Type -AssemblyName System.Security

function Get-PINHash {
    <#
    .SYNOPSIS
        Generates SHA256 hash of PIN for secure storage/comparison.
    #>
    param([string]$PIN)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PIN)
    $hash = $sha256.ComputeHash($bytes)
    return [Convert]::ToBase64String($hash)
}

function Protect-Credential {
    <#
    .SYNOPSIS
        Encrypts a PSCredential using DPAPI with PIN as additional entropy.
    #>
    param(
        [PSCredential]$Credential,
        [string]$PIN
    )

    try {
        # Convert credential to storable format
        $username = $Credential.UserName
        $password = $Credential.GetNetworkCredential().Password
        $data = "$username|$password"
        $dataBytes = [System.Text.Encoding]::UTF8.GetBytes($data)

        # Use PIN as additional entropy
        $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes($PIN)

        # Encrypt with DPAPI (CurrentUser scope + entropy)
        $encryptedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $dataBytes,
            $entropyBytes,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )

        return $encryptedBytes
    }
    catch {
        Write-Warning "Failed to encrypt credential: $_"
        return $null
    }
}

function Unprotect-Credential {
    <#
    .SYNOPSIS
        Decrypts credential blob using DPAPI with PIN as entropy.
    #>
    param(
        [byte[]]$EncryptedData,
        [string]$PIN
    )

    try {
        # Use PIN as entropy
        $entropyBytes = [System.Text.Encoding]::UTF8.GetBytes($PIN)

        # Decrypt with DPAPI
        $decryptedBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $EncryptedData,
            $entropyBytes,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )

        $data = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
        $parts = $data -split '\|', 2

        if ($parts.Count -eq 2) {
            $securePassword = ConvertTo-SecureString $parts[1] -AsPlainText -Force
            return New-Object System.Management.Automation.PSCredential($parts[0], $securePassword)
        }
        return $null
    }
    catch {
        # Decryption failed (wrong PIN or corrupted data)
        return $null
    }
}

function Save-EncryptedCredential {
    <#
    .SYNOPSIS
        Saves encrypted credential and PIN hash to disk.
    #>
    param(
        [byte[]]$EncryptedData,
        [string]$PINHash
    )

    try {
        if (-not (Test-Path $script:ConfigPath)) {
            New-Item -Path $script:ConfigPath -ItemType Directory -Force | Out-Null
        }

        # Save encrypted credential
        [System.IO.File]::WriteAllBytes($script:CredentialFile, $EncryptedData)

        # Save PIN hash
        Set-Content -Path $script:PINFile -Value $PINHash -Force

        return $true
    }
    catch {
        Write-Warning "Failed to save credential: $_"
        return $false
    }
}

function Load-EncryptedCredential {
    <#
    .SYNOPSIS
        Loads encrypted credential and PIN hash from disk.
    .OUTPUTS
        Hashtable with EncryptedData and PINHash, or $null if not found.
    #>

    if ((Test-Path $script:CredentialFile) -and (Test-Path $script:PINFile)) {
        try {
            $encryptedData = [System.IO.File]::ReadAllBytes($script:CredentialFile)
            $pinHash = Get-Content -Path $script:PINFile -Raw
            return @{
                EncryptedData = $encryptedData
                PINHash = $pinHash.Trim()
            }
        }
        catch {
            Write-Warning "Failed to load credential: $_"
        }
    }
    return $null
}

function Remove-EncryptedCredential {
    <#
    .SYNOPSIS
        Removes saved credential files from disk.
    #>
    if (Test-Path $script:CredentialFile) { Remove-Item $script:CredentialFile -Force }
    if (Test-Path $script:PINFile) { Remove-Item $script:PINFile -Force }
    $script:CachedCredential = $null
    $script:CredentialPINHash = $null
    $script:PINLastVerified = $null
    $script:PINFailCount = 0
}

function Test-PINTimeout {
    <#
    .SYNOPSIS
        Checks if PIN needs to be re-entered (timeout expired).
    #>
    if (-not $script:PINLastVerified) { return $true }
    $elapsed = (Get-Date) - $script:PINLastVerified
    return $elapsed.TotalMinutes -ge $script:PINTimeout
}

function Show-PINEntryDialog {
    <#
    .SYNOPSIS
        Shows dialog to enter PIN. Returns PIN if valid, $null if cancelled.
    .PARAMETER IsNewPIN
        If true, shows "Set PIN" dialog with confirmation. If false, shows "Enter PIN" dialog.
    #>
    param(
        [bool]$IsNewPIN = $false,
        [string]$Title = ""
    )

    $dialogTitle = if ($IsNewPIN) { "Set PIN" } else { if ($Title) { $Title } else { "Enter PIN" } }
    $dialogHeight = if ($IsNewPIN) { 200 } else { 150 }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $dialogTitle
    $form.Size = New-Object System.Drawing.Size(350, $dialogHeight)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $yPos = 15

    $label = New-Object System.Windows.Forms.Label
    $labelText = if ($IsNewPIN) { "Create a 6+ digit PIN to protect your credentials:" } else { "Enter your PIN:" }
    $label.Text = $labelText
    $label.Location = New-Object System.Drawing.Point(15, $yPos)
    $label.AutoSize = $true
    $form.Controls.Add($label)
    $yPos += 25

    $pinBox = New-Object System.Windows.Forms.TextBox
    $pinBox.Location = New-Object System.Drawing.Point(15, $yPos)
    $pinBox.Width = 300
    $pinBox.UseSystemPasswordChar = $true
    $pinBox.MaxLength = 20
    $form.Controls.Add($pinBox)
    $yPos += 30

    $confirmBox = $null
    if ($IsNewPIN) {
        $confirmLabel = New-Object System.Windows.Forms.Label
        $confirmLabel.Text = "Confirm PIN:"
        $confirmLabel.Location = New-Object System.Drawing.Point(15, $yPos)
        $confirmLabel.AutoSize = $true
        $form.Controls.Add($confirmLabel)
        $yPos += 22

        $confirmBox = New-Object System.Windows.Forms.TextBox
        $confirmBox.Location = New-Object System.Drawing.Point(15, $yPos)
        $confirmBox.Width = 300
        $confirmBox.UseSystemPasswordChar = $true
        $confirmBox.MaxLength = 20
        $form.Controls.Add($confirmBox)
        $yPos += 35
    }
    else {
        $yPos += 15
    }

    $resultPIN = $null

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "OK"
    $okBtn.Location = New-Object System.Drawing.Point(150, $yPos)
    $okBtn.Width = 75
    $okBtn.Add_Click({
        $pin = $pinBox.Text

        # Validate PIN length
        if ($pin.Length -lt 6) {
            [System.Windows.Forms.MessageBox]::Show(
                "PIN must be at least 6 digits.",
                "Invalid PIN",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        # Validate digits only
        if ($pin -notmatch '^\d+$') {
            [System.Windows.Forms.MessageBox]::Show(
                "PIN must contain only digits.",
                "Invalid PIN",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        # If new PIN, check confirmation
        if ($IsNewPIN -and $confirmBox) {
            if ($pin -ne $confirmBox.Text) {
                [System.Windows.Forms.MessageBox]::Show(
                    "PINs do not match.",
                    "Mismatch",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                return
            }
        }

        $script:DialogResultPIN = $pin
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(235, $yPos)
    $cancelBtn.Width = 75
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelBtn)

    $form.AcceptButton = $okBtn
    $form.CancelButton = $cancelBtn

    $script:DialogResultPIN = $null

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $result = $script:DialogResultPIN
        $form.Dispose()
        return $result
    }

    $form.Dispose()
    return $null
}

function Lock-CachedCredentials {
    <#
    .SYNOPSIS
        Forces PIN re-entry on next credential use.
    #>
    $script:PINLastVerified = $null
    [System.Windows.Forms.MessageBox]::Show(
        "Credentials locked. PIN required for next elevated operation.",
        "Locked",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
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
        Prompts for administrator credentials with PIN protection.
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

    # If caching disabled, just prompt directly
    if (-not $script:CacheCredentials) {
        try {
            return Get-Credential -Message $Message
        }
        catch {
            return $null
        }
    }

    # Check if we have an in-memory unlocked credential and PIN hasn't timed out
    if (-not $Force -and $script:CachedCredential -is [PSCredential] -and -not (Test-PINTimeout)) {
        return $script:CachedCredential
    }

    # Try to load from disk if not in memory
    $savedCred = Load-EncryptedCredential
    if ($savedCred) {
        # We have saved credentials - need PIN to unlock
        $attemptsLeft = 3 - $script:PINFailCount

        while ($attemptsLeft -gt 0) {
            $pin = Show-PINEntryDialog -Title "Unlock Credentials ($attemptsLeft attempts left)"
            if (-not $pin) {
                # User cancelled - offer to reset
                $reset = [System.Windows.Forms.MessageBox]::Show(
                    "Would you like to clear saved credentials and enter new ones?",
                    "Reset Credentials",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($reset -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Remove-EncryptedCredential
                    break
                }
                return $null
            }

            # Verify PIN hash
            $enteredHash = Get-PINHash -PIN $pin
            if ($enteredHash -eq $savedCred.PINHash) {
                # PIN correct - decrypt credential
                $decrypted = Unprotect-Credential -EncryptedData $savedCred.EncryptedData -PIN $pin
                if ($decrypted) {
                    $script:CachedCredential = $decrypted
                    $script:CredentialPINHash = $savedCred.PINHash
                    $script:PINLastVerified = Get-Date
                    $script:PINFailCount = 0
                    return $decrypted
                }
                else {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Failed to decrypt credentials. File may be corrupted.",
                        "Error",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    )
                    Remove-EncryptedCredential
                    break
                }
            }
            else {
                # Wrong PIN
                $script:PINFailCount++
                $attemptsLeft = 3 - $script:PINFailCount

                if ($attemptsLeft -gt 0) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Incorrect PIN. $attemptsLeft attempts remaining.",
                        "Wrong PIN",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                }
                else {
                    # Max attempts reached
                    $reset = [System.Windows.Forms.MessageBox]::Show(
                        "Maximum PIN attempts reached. Clear saved credentials and start over?",
                        "Locked Out",
                        [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                    if ($reset -eq [System.Windows.Forms.DialogResult]::Yes) {
                        Remove-EncryptedCredential
                    }
                    else {
                        return $null
                    }
                }
            }
        }
    }

    # No saved credential (or was cleared) - prompt for new one
    try {
        $cred = Get-Credential -Message $Message
        if (-not $cred) { return $null }

        # Prompt for new PIN
        $pin = Show-PINEntryDialog -IsNewPIN $true
        if (-not $pin) {
            # User cancelled PIN setup - still return credential but don't cache
            return $cred
        }

        # Encrypt and save
        $encrypted = Protect-Credential -Credential $cred -PIN $pin
        if ($encrypted) {
            $pinHash = Get-PINHash -PIN $pin
            if (Save-EncryptedCredential -EncryptedData $encrypted -PINHash $pinHash) {
                $script:CachedCredential = $cred
                $script:CredentialPINHash = $pinHash
                $script:PINLastVerified = Get-Date
                $script:PINFailCount = 0

                [System.Windows.Forms.MessageBox]::Show(
                    "Credentials saved and encrypted with your PIN.",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            }
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
    # Clear in-memory credential
    $script:CachedCredential = $null
    $script:CredentialPINHash = $null
    $script:PINLastVerified = $null
    $script:PINFailCount = 0

    # Delete encrypted files from disk
    Remove-EncryptedCredential

    [System.Windows.Forms.MessageBox]::Show(
        "Cached credentials have been cleared from memory and disk.",
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

#region Status Bar Helper Functions
function Start-AppActivity {
    <#
    .SYNOPSIS
        Shows pulsing activity indicator for operations with unknown duration.
    .PARAMETER Message
        Status message to display.
    #>
    param([string]$Message)
    $script:statusLabel.Text = $Message
    $script:statusLabel.ForeColor = [System.Drawing.Color]::Black
    $script:activityBar.Visible = $true
    $script:progressBar.Visible = $false
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-AppProgress {
    <#
    .SYNOPSIS
        Shows progress bar for operations with known number of steps.
    .PARAMETER Value
        Current step number.
    .PARAMETER Maximum
        Total number of steps.
    .PARAMETER Message
        Optional status message to display.
    #>
    param(
        [int]$Value,
        [int]$Maximum = 100,
        [string]$Message = ""
    )
    if ($Message) { $script:statusLabel.Text = $Message }
    $script:statusLabel.ForeColor = [System.Drawing.Color]::Black
    $script:activityBar.Visible = $false
    $script:progressBar.Maximum = $Maximum
    $script:progressBar.Value = $Value
    $script:progressBar.Visible = $true
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-AppError {
    <#
    .SYNOPSIS
        Shows error message in status bar (red text).
    .PARAMETER Message
        Error message to display.
    #>
    param([string]$Message)
    $script:statusLabel.Text = $Message
    $script:statusLabel.ForeColor = [System.Drawing.Color]::Red
    $script:activityBar.Visible = $false
    $script:progressBar.Visible = $false
    [System.Windows.Forms.Application]::DoEvents()
}

function Clear-AppStatus {
    <#
    .SYNOPSIS
        Clears status bar - hides indicators and clears message.
    #>
    $script:statusLabel.Text = ""
    $script:statusLabel.ForeColor = [System.Drawing.Color]::Black
    $script:activityBar.Visible = $false
    $script:progressBar.Visible = $false
    [System.Windows.Forms.Application]::DoEvents()
}
#endregion

#region Settings Dialog
function Show-SettingsDialog {
    <#
    .SYNOPSIS
        Shows settings dialog for configuring default paths.
    #>
    $settingsForm = New-Object System.Windows.Forms.Form
    $settingsForm.Text = "Settings"
    $settingsForm.Size = New-Object System.Drawing.Size(500, 320)
    $settingsForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $settingsForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $settingsForm.MaximizeBox = $false
    $settingsForm.MinimizeBox = $false

    $yPos = 15

    # Software Installer Section
    $swLabel = New-Object System.Windows.Forms.Label
    $swLabel.Text = "Software Installer"
    $swLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $swLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $swLabel.AutoSize = $true
    $settingsForm.Controls.Add($swLabel)
    $yPos += 25

    # Network Path
    $netPathLabel = New-Object System.Windows.Forms.Label
    $netPathLabel.Text = "Default Network Path:"
    $netPathLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $netPathLabel.AutoSize = $true
    $settingsForm.Controls.Add($netPathLabel)
    $yPos += 22

    $netPathTextBox = New-Object System.Windows.Forms.TextBox
    $netPathTextBox.Location = New-Object System.Drawing.Point(15, $yPos)
    $netPathTextBox.Width = 380
    $netPathTextBox.Text = Get-ModuleSetting -ModuleName "SoftwareInstaller" -Key "networkPath" -Default ""
    $settingsForm.Controls.Add($netPathTextBox)

    $netBrowseBtn = New-Object System.Windows.Forms.Button
    $netBrowseBtn.Text = "..."
    $netBrowseBtn.Location = New-Object System.Drawing.Point(400, ($yPos - 2))
    $netBrowseBtn.Width = 40
    $netBrowseBtn.Height = 25
    $netBrowseBtn.Add_Click({
        $folder = New-Object System.Windows.Forms.FolderBrowserDialog
        $folder.Description = "Select network installer directory"
        if ($folder.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $netPathTextBox.Text = $folder.SelectedPath
        }
    })
    $settingsForm.Controls.Add($netBrowseBtn)
    $yPos += 35

    # Local Path
    $localPathLabel = New-Object System.Windows.Forms.Label
    $localPathLabel.Text = "Default Local/USB Path:"
    $localPathLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $localPathLabel.AutoSize = $true
    $settingsForm.Controls.Add($localPathLabel)
    $yPos += 22

    $localPathTextBox = New-Object System.Windows.Forms.TextBox
    $localPathTextBox.Location = New-Object System.Drawing.Point(15, $yPos)
    $localPathTextBox.Width = 380
    $localPathTextBox.Text = Get-ModuleSetting -ModuleName "SoftwareInstaller" -Key "localPath" -Default ""
    $settingsForm.Controls.Add($localPathTextBox)

    $localBrowseBtn = New-Object System.Windows.Forms.Button
    $localBrowseBtn.Text = "..."
    $localBrowseBtn.Location = New-Object System.Drawing.Point(400, ($yPos - 2))
    $localBrowseBtn.Width = 40
    $localBrowseBtn.Height = 25
    $localBrowseBtn.Add_Click({
        $folder = New-Object System.Windows.Forms.FolderBrowserDialog
        $folder.Description = "Select local installer directory"
        if ($folder.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $localPathTextBox.Text = $folder.SelectedPath
        }
    })
    $settingsForm.Controls.Add($localBrowseBtn)
    $yPos += 40

    # Printer Management Section
    $printerLabel = New-Object System.Windows.Forms.Label
    $printerLabel.Text = "Printer Management"
    $printerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $printerLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $printerLabel.AutoSize = $true
    $settingsForm.Controls.Add($printerLabel)
    $yPos += 25

    # Print Server
    $serverLabel = New-Object System.Windows.Forms.Label
    $serverLabel.Text = "Default Print Server:"
    $serverLabel.Location = New-Object System.Drawing.Point(15, $yPos)
    $serverLabel.AutoSize = $true
    $settingsForm.Controls.Add($serverLabel)
    $yPos += 22

    $serverTextBox = New-Object System.Windows.Forms.TextBox
    $serverTextBox.Location = New-Object System.Drawing.Point(15, $yPos)
    $serverTextBox.Width = 380
    $serverTextBox.Text = Get-ModuleSetting -ModuleName "PrinterManagement" -Key "defaultServer" -Default "\\RUDWV-PS401"
    $settingsForm.Controls.Add($serverTextBox)
    $yPos += 45

    # Buttons
    $saveBtn = New-Object System.Windows.Forms.Button
    $saveBtn.Text = "Save"
    $saveBtn.Location = New-Object System.Drawing.Point(290, $yPos)
    $saveBtn.Width = 80
    $saveBtn.Height = 30
    $saveBtn.Add_Click({
        Set-ModuleSetting -ModuleName "SoftwareInstaller" -Key "networkPath" -Value $netPathTextBox.Text.Trim()
        Set-ModuleSetting -ModuleName "SoftwareInstaller" -Key "localPath" -Value $localPathTextBox.Text.Trim()
        Set-ModuleSetting -ModuleName "PrinterManagement" -Key "defaultServer" -Value $serverTextBox.Text.Trim()
        [System.Windows.Forms.MessageBox]::Show(
            "Settings saved. Changes will apply when modules are refreshed or restarted.",
            "Settings Saved",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        $settingsForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $settingsForm.Close()
    })
    $settingsForm.Controls.Add($saveBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.Location = New-Object System.Drawing.Point(380, $yPos)
    $cancelBtn.Width = 80
    $cancelBtn.Height = 30
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $settingsForm.Controls.Add($cancelBtn)

    $settingsForm.AcceptButton = $saveBtn
    $settingsForm.CancelButton = $cancelBtn

    $settingsForm.ShowDialog() | Out-Null
    $settingsForm.Dispose()
}
#endregion

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
    $cacheMenuItem.Text = "Enable Credential Caching (PIN Protected)"
    $cacheMenuItem.CheckOnClick = $true
    $cacheMenuItem.Checked = $script:CacheCredentials
    $cacheMenuItem.Add_Click({
        $script:CacheCredentials = $cacheMenuItem.Checked
        $script:Settings.global.cacheCredentials = $script:CacheCredentials
        Save-Settings
        if (-not $script:CacheCredentials) {
            Clear-CachedCredentials
        }
    })
    $credentialMenu.DropDownItems.Add($cacheMenuItem) | Out-Null

    # Lock Now (force PIN re-entry)
    $lockMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $lockMenuItem.Text = "Lock Now (Require PIN)"
    $lockMenuItem.Add_Click({ Lock-CachedCredentials })
    $credentialMenu.DropDownItems.Add($lockMenuItem) | Out-Null

    # Separator
    $credentialMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Clear cached credentials
    $clearCredMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $clearCredMenuItem.Text = "Clear Cached Credentials"
    $clearCredMenuItem.Add_Click({ Clear-CachedCredentials })
    $credentialMenu.DropDownItems.Add($clearCredMenuItem) | Out-Null

    $toolsMenu.DropDownItems.Add($credentialMenu) | Out-Null

    # Settings
    $settingsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $settingsMenuItem.Text = "Settings..."
    $settingsMenuItem.Add_Click({ Show-SettingsDialog })
    $toolsMenu.DropDownItems.Add($settingsMenuItem) | Out-Null

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

    # Activity indicator (pulsing/marquee for indeterminate progress)
    $script:activityBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $script:activityBar.Width = 80
    $script:activityBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $script:activityBar.MarqueeAnimationSpeed = 30
    $script:activityBar.Visible = $false
    $statusStrip.Items.Add($script:activityBar) | Out-Null

    # Status message label
    $script:statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:statusLabel.Text = ""
    $script:statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusStrip.Items.Add($script:statusLabel) | Out-Null

    # Progress bar (for determinate progress like "2 of 5")
    $script:progressBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $script:progressBar.Width = 120
    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $script:progressBar.Visible = $false
    $statusStrip.Items.Add($script:progressBar) | Out-Null

    # Separator before user info
    $separator = New-Object System.Windows.Forms.ToolStripStatusLabel
    $separator.Spring = $true
    $statusStrip.Items.Add($separator) | Out-Null

    $userLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $userLabel.Text = "Running as: $env:USERDOMAIN\$env:USERNAME"
    $userLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
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
