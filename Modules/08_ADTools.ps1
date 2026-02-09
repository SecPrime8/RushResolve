<#
.SYNOPSIS
    Active Directory Tools Module for Rush Resolve
.DESCRIPTION
    User management tools: search users, unlock accounts, reset passwords, view group memberships.
    Uses ADSI (System.DirectoryServices) - NO RSAT required. 100% portable.
#>

$script:ModuleName = "AD Tools"
$script:ModuleDescription = "Search users, unlock accounts, reset passwords (portable ADSI, no RSAT)"

#region Script Blocks

# Search for AD user by sAMAccountName
$script:SearchADUser = {
    param(
        [string]$Username,
        [System.Windows.Forms.TextBox]$LogBox
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Searching for user: $Username`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # Create DirectorySearcher
        $searcher = New-Object DirectoryServices.DirectorySearcher
        $searcher.Filter = "(&(objectClass=user)(sAMAccountName=$Username))"
        $searcher.PropertiesToLoad.Add("displayName") | Out-Null
        $searcher.PropertiesToLoad.Add("mail") | Out-Null
        $searcher.PropertiesToLoad.Add("department") | Out-Null
        $searcher.PropertiesToLoad.Add("title") | Out-Null
        $searcher.PropertiesToLoad.Add("lastLogon") | Out-Null
        $searcher.PropertiesToLoad.Add("userAccountControl") | Out-Null
        $searcher.PropertiesToLoad.Add("pwdLastSet") | Out-Null
        $searcher.PropertiesToLoad.Add("lockoutTime") | Out-Null
        $searcher.PropertiesToLoad.Add("memberOf") | Out-Null
        $searcher.PropertiesToLoad.Add("distinguishedName") | Out-Null

        $result = $searcher.FindOne()

        if (-not $result) {
            $LogBox.AppendText("[$timestamp] User not found: $Username`r`n")
            Write-SessionLog -Message "AD Search: User not found ($Username)" -Category "AD Tools"
            return @{ Success = $false; Message = "User not found" }
        }

        # Parse user properties
        $props = $result.Properties
        $userInfo = @{
            Success = $true
            Username = $Username
            DisplayName = if ($props["displayName"].Count -gt 0) { $props["displayName"][0] } else { "N/A" }
            Email = if ($props["mail"].Count -gt 0) { $props["mail"][0] } else { "N/A" }
            Department = if ($props["department"].Count -gt 0) { $props["department"][0] } else { "N/A" }
            Title = if ($props["title"].Count -gt 0) { $props["title"][0] } else { "N/A" }
            DN = if ($props["distinguishedName"].Count -gt 0) { $props["distinguishedName"][0] } else { "N/A" }
            Groups = @()
            IsLocked = $false
            IsDisabled = $false
            LastLogon = "Never"
            PasswordLastSet = "N/A"
        }

        # Parse userAccountControl flags
        if ($props["userAccountControl"].Count -gt 0) {
            $uac = [int]$props["userAccountControl"][0]
            $userInfo.IsDisabled = ($uac -band 0x2) -ne 0  # ADS_UF_ACCOUNTDISABLE
        }

        # Parse lockoutTime
        if ($props["lockoutTime"].Count -gt 0) {
            $lockoutTime = $props["lockoutTime"][0]
            if ($lockoutTime -gt 0) {
                $userInfo.IsLocked = $true
            }
        }

        # Parse lastLogon (INT64)
        if ($props["lastLogon"].Count -gt 0) {
            $lastLogonInt64 = $props["lastLogon"][0]
            if ($lastLogonInt64 -gt 0) {
                try {
                    $lastLogonDate = [DateTime]::FromFileTime($lastLogonInt64)
                    $userInfo.LastLogon = $lastLogonDate.ToString("yyyy-MM-dd HH:mm:ss")
                }
                catch {
                    $userInfo.LastLogon = "Parse error"
                }
            }
        }

        # Parse pwdLastSet
        if ($props["pwdLastSet"].Count -gt 0) {
            $pwdLastSetInt64 = $props["pwdLastSet"][0]
            if ($pwdLastSetInt64 -gt 0) {
                try {
                    $pwdLastSetDate = [DateTime]::FromFileTime($pwdLastSetInt64)
                    $userInfo.PasswordLastSet = $pwdLastSetDate.ToString("yyyy-MM-dd HH:mm:ss")
                }
                catch {
                    $userInfo.PasswordLastSet = "Parse error"
                }
            }
        }

        # Parse memberOf
        if ($props["memberOf"].Count -gt 0) {
            foreach ($dn in $props["memberOf"]) {
                # Extract CN from DN
                if ($dn -match "CN=([^,]+)") {
                    $userInfo.Groups += $matches[1]
                }
            }
        }

        $LogBox.AppendText("[$timestamp] User found: $($userInfo.DisplayName)`r`n")
        $LogBox.AppendText("[$timestamp]   Email: $($userInfo.Email)`r`n")
        $LogBox.AppendText("[$timestamp]   Locked: $($userInfo.IsLocked)    Disabled: $($userInfo.IsDisabled)`r`n")
        Write-SessionLog -Message "AD Search: Found user ($Username - $($userInfo.DisplayName))" -Category "AD Tools"

        return $userInfo
    }
    catch {
        $errorMsg = $_.Exception.Message
        $LogBox.AppendText("[$timestamp] ERROR: $errorMsg`r`n")
        Write-SessionLog -Message "AD Search: ERROR - $errorMsg" -Category "AD Tools"
        return @{ Success = $false; Message = $errorMsg }
    }
    finally {
        $LogBox.ScrollToCaret()
    }
}

# Unlock AD user account
$script:UnlockADUser = {
    param(
        [string]$Username,
        [System.Windows.Forms.TextBox]$LogBox
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Attempting to unlock account: $Username`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # Get credentials
        $cred = Get-ElevatedCredential -Message "Enter domain admin credentials to unlock $Username"
        if (-not $cred) {
            $LogBox.AppendText("[$timestamp] Cancelled - no credentials provided`r`n")
            return @{ Success = $false; Message = "Cancelled by user" }
        }

        # Search for user
        $searcher = New-Object DirectoryServices.DirectorySearcher
        $searcher.Filter = "(&(objectClass=user)(sAMAccountName=$Username))"
        $result = $searcher.FindOne()

        if (-not $result) {
            $LogBox.AppendText("[$timestamp] User not found: $Username`r`n")
            return @{ Success = $false; Message = "User not found" }
        }

        # Get DirectoryEntry with elevated credentials
        $dirEntry = $result.GetDirectoryEntry()
        $dirEntry.Username = $cred.UserName
        $dirEntry.Password = $cred.GetNetworkCredential().Password

        # Unlock the account
        $dirEntry.InvokeSet("IsAccountLocked", $false)
        $dirEntry.CommitChanges()

        $LogBox.AppendText("[$timestamp] SUCCESS: Account unlocked for $Username`r`n")
        Write-SessionLog -Message "AD Unlock: SUCCESS ($Username)" -Category "AD Tools"
        return @{ Success = $true; Message = "Account unlocked successfully" }
    }
    catch {
        $errorMsg = $_.Exception.Message
        $LogBox.AppendText("[$timestamp] ERROR: $errorMsg`r`n")

        # Provide guidance based on error
        if ($errorMsg -match "access.*denied" -or $errorMsg -match "0x5") {
            $LogBox.AppendText("[$timestamp] Hint: Access denied - insufficient permissions or invalid credentials`r`n")
        }
        elseif ($errorMsg -match "Logon failure") {
            $LogBox.AppendText("[$timestamp] Hint: Invalid username or password`r`n")
        }

        Write-SessionLog -Message "AD Unlock: ERROR - $errorMsg ($Username)" -Category "AD Tools"
        return @{ Success = $false; Message = $errorMsg }
    }
    finally {
        $LogBox.ScrollToCaret()
    }
}

# Reset AD user password
$script:ResetADPassword = {
    param(
        [string]$Username,
        [string]$NewPassword,
        [bool]$MustChangePassword,
        [System.Windows.Forms.TextBox]$LogBox
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $LogBox.AppendText("[$timestamp] Attempting to reset password for: $Username`r`n")
    $LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # Get credentials
        $cred = Get-ElevatedCredential -Message "Enter domain admin credentials to reset password for $Username"
        if (-not $cred) {
            $LogBox.AppendText("[$timestamp] Cancelled - no credentials provided`r`n")
            return @{ Success = $false; Message = "Cancelled by user" }
        }

        # Search for user
        $searcher = New-Object DirectoryServices.DirectorySearcher
        $searcher.Filter = "(&(objectClass=user)(sAMAccountName=$Username))"
        $result = $searcher.FindOne()

        if (-not $result) {
            $LogBox.AppendText("[$timestamp] User not found: $Username`r`n")
            return @{ Success = $false; Message = "User not found" }
        }

        # Get DirectoryEntry with elevated credentials
        $dirEntry = $result.GetDirectoryEntry()
        $dirEntry.Username = $cred.UserName
        $dirEntry.Password = $cred.GetNetworkCredential().Password

        # Reset password
        $dirEntry.Invoke("SetPassword", $NewPassword)

        # Set "must change password at next logon" flag
        if ($MustChangePassword) {
            $dirEntry.InvokeSet("pwdLastSet", 0)
        }

        $dirEntry.CommitChanges()

        $LogBox.AppendText("[$timestamp] SUCCESS: Password reset for $Username`r`n")
        if ($MustChangePassword) {
            $LogBox.AppendText("[$timestamp]   User must change password at next logon`r`n")
        }
        Write-SessionLog -Message "AD Password Reset: SUCCESS ($Username)" -Category "AD Tools"
        return @{ Success = $true; Message = "Password reset successfully" }
    }
    catch {
        $errorMsg = $_.Exception.Message
        $LogBox.AppendText("[$timestamp] ERROR: $errorMsg`r`n")

        # Provide guidance based on error
        if ($errorMsg -match "password.*complexity" -or $errorMsg -match "password.*policy") {
            $LogBox.AppendText("[$timestamp] Hint: Password does not meet complexity requirements`r`n")
        }
        elseif ($errorMsg -match "access.*denied" -or $errorMsg -match "0x5") {
            $LogBox.AppendText("[$timestamp] Hint: Access denied - insufficient permissions`r`n")
        }

        Write-SessionLog -Message "AD Password Reset: ERROR - $errorMsg ($Username)" -Category "AD Tools"
        return @{ Success = $false; Message = $errorMsg }
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
    $searchADUserRef = $script:SearchADUser
    $unlockADUserRef = $script:UnlockADUser
    $resetADPasswordRef = $script:ResetADPassword

    # Main layout - 4 rows
    $mainPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $mainPanel.RowCount = 4
    $mainPanel.ColumnCount = 1
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60))) | Out-Null   # Search
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 180))) | Out-Null  # User Info
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 55))) | Out-Null   # Actions
    $mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null   # Log

    #region Row 0 - Search Panel
    $searchGroup = New-Object System.Windows.Forms.GroupBox
    $searchGroup.Text = "User Search"
    $searchGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $searchGroup.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 5)

    $searchPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $searchPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $searchPanel.WrapContents = $false

    $usernameLabel = New-Object System.Windows.Forms.Label
    $usernameLabel.Text = "Username:"
    $usernameLabel.AutoSize = $true
    $usernameLabel.Padding = New-Object System.Windows.Forms.Padding(0, 7, 5, 0)
    $searchPanel.Controls.Add($usernameLabel)

    $script:usernameTextBox = New-Object System.Windows.Forms.TextBox
    $script:usernameTextBox.Width = 180
    $searchPanel.Controls.Add($script:usernameTextBox)

    $searchBtn = New-Object System.Windows.Forms.Button
    $searchBtn.Text = "Search"
    $searchBtn.Width = 80
    $searchBtn.Height = 28
    $searchPanel.Controls.Add($searchBtn)

    $searchGroup.Controls.Add($searchPanel)
    $mainPanel.Controls.Add($searchGroup, 0, 0)
    #endregion

    #region Row 1 - User Info Display
    $infoGroup = New-Object System.Windows.Forms.GroupBox
    $infoGroup.Text = "User Information"
    $infoGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $infoGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $script:userInfoTextBox = New-Object System.Windows.Forms.TextBox
    $script:userInfoTextBox.Multiline = $true
    $script:userInfoTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:userInfoTextBox.ReadOnly = $true
    $script:userInfoTextBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:userInfoTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:userInfoTextBox.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $script:userInfoTextBox.Text = "Search for a user to view details..."

    $infoGroup.Controls.Add($script:userInfoTextBox)
    $mainPanel.Controls.Add($infoGroup, 0, 1)
    #endregion

    #region Row 2 - Actions
    $actionGroup = New-Object System.Windows.Forms.GroupBox
    $actionGroup.Text = "Actions"
    $actionGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionGroup.Padding = New-Object System.Windows.Forms.Padding(10, 3, 10, 3)

    $actionPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $actionPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:unlockBtn = New-Object System.Windows.Forms.Button
    $script:unlockBtn.Text = "Unlock Account *"
    $script:unlockBtn.Width = 140
    $script:unlockBtn.Height = 30
    $script:unlockBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    $script:unlockBtn.Enabled = $false
    $actionPanel.Controls.Add($script:unlockBtn)

    $script:resetPasswordBtn = New-Object System.Windows.Forms.Button
    $script:resetPasswordBtn.Text = "Reset Password *"
    $script:resetPasswordBtn.Width = 145
    $script:resetPasswordBtn.Height = 30
    $script:resetPasswordBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    $script:resetPasswordBtn.Enabled = $false
    $actionPanel.Controls.Add($script:resetPasswordBtn)

    $script:copyGroupsBtn = New-Object System.Windows.Forms.Button
    $script:copyGroupsBtn.Text = "Copy Groups"
    $script:copyGroupsBtn.Width = 100
    $script:copyGroupsBtn.Height = 30
    $script:copyGroupsBtn.Enabled = $false
    $actionPanel.Controls.Add($script:copyGroupsBtn)

    $actionGroup.Controls.Add($actionPanel)
    $mainPanel.Controls.Add($actionGroup, 0, 2)
    #endregion

    #region Row 3 - Activity Log
    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = "Activity Log"
    $logGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logGroup.Padding = New-Object System.Windows.Forms.Padding(5)

    $logPanel = New-Object System.Windows.Forms.Panel
    $logPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

    $script:adLogBox = New-Object System.Windows.Forms.TextBox
    $script:adLogBox.Multiline = $true
    $script:adLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:adLogBox.ReadOnly = $true
    $script:adLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:adLogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:adLogBox.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $script:adLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill

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

    $logPanel.Controls.Add($script:adLogBox)
    $logPanel.Controls.Add($logBtnPanel)
    $logGroup.Controls.Add($logPanel)
    $mainPanel.Controls.Add($logGroup, 0, 3)
    #endregion

    #region Event Handlers

    # Store references for closures
    $usernameTextBoxRef = $script:usernameTextBox
    $userInfoTextBoxRef = $script:userInfoTextBox
    $logBoxRef = $script:adLogBox
    $unlockBtnRef = $script:unlockBtn
    $resetPasswordBtnRef = $script:resetPasswordBtn
    $copyGroupsBtnRef = $script:copyGroupsBtn

    # Script-level variable to store current user data
    $script:currentUserData = $null

    # Search button
    $searchBtn.Add_Click({
        $username = $usernameTextBoxRef.Text.Trim()
        if (-not $username) {
            [System.Windows.Forms.MessageBox]::Show("Please enter a username", "Input Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        # Disable action buttons while searching
        $unlockBtnRef.Enabled = $false
        $resetPasswordBtnRef.Enabled = $false
        $copyGroupsBtnRef.Enabled = $false

        # Search for user
        $userResult = & $searchADUserRef -Username $username -LogBox $logBoxRef

        if ($userResult.Success) {
            # Store user data
            $script:currentUserData = $userResult

            # Display user info
            $infoText = @"
Display Name:     $($userResult.DisplayName)
Username:         $($userResult.Username)
Email:            $($userResult.Email)
Department:       $($userResult.Department)
Title:            $($userResult.Title)

Status:
  Locked:         $($userResult.IsLocked)
  Disabled:       $($userResult.IsDisabled)

Activity:
  Last Logon:     $($userResult.LastLogon)
  Password Set:   $($userResult.PasswordLastSet)

Groups ($($userResult.Groups.Count)):
$($userResult.Groups | ForEach-Object { "  - $_" } | Out-String)

Distinguished Name:
$($userResult.DN)
"@
            $userInfoTextBoxRef.Text = $infoText

            # Enable action buttons
            $unlockBtnRef.Enabled = $true
            $resetPasswordBtnRef.Enabled = $true
            if ($userResult.Groups.Count -gt 0) {
                $copyGroupsBtnRef.Enabled = $true
            }
        } else {
            $userInfoTextBoxRef.Text = "User not found or error occurred. Check activity log."
            $script:currentUserData = $null
        }
    }.GetNewClosure())

    # Unlock account button
    $script:unlockBtn.Add_Click({
        if (-not $script:currentUserData) { return }

        $username = $script:currentUserData.Username
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Unlock account for user: $username?`n`nThis will clear the account lockout status.`n`nContinue?",
            "Unlock Account",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $result = & $unlockADUserRef -Username $username -LogBox $logBoxRef
            if ($result.Success) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Account unlocked successfully for: $username",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                # Refresh user info
                $searchBtn.PerformClick()
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to unlock account:`n`n$($result.Message)",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        }
    }.GetNewClosure())

    # Reset password button
    $script:resetPasswordBtn.Add_Click({
        if (-not $script:currentUserData) { return }

        $username = $script:currentUserData.Username

        # Create password input form
        $pwdForm = New-Object System.Windows.Forms.Form
        $pwdForm.Text = "Reset Password for $username"
        $pwdForm.Size = New-Object System.Drawing.Size(380, 220)
        $pwdForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $pwdForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $pwdForm.MaximizeBox = $false
        $pwdForm.MinimizeBox = $false

        # New password
        $pwdLabel = New-Object System.Windows.Forms.Label
        $pwdLabel.Text = "New Password:"
        $pwdLabel.Location = New-Object System.Drawing.Point(10, 20)
        $pwdLabel.AutoSize = $true
        $pwdForm.Controls.Add($pwdLabel)

        $pwdTextBox = New-Object System.Windows.Forms.TextBox
        $pwdTextBox.Location = New-Object System.Drawing.Point(130, 17)
        $pwdTextBox.Width = 220
        $pwdTextBox.UseSystemPasswordChar = $true
        $pwdForm.Controls.Add($pwdTextBox)

        # Confirm password
        $confirmLabel = New-Object System.Windows.Forms.Label
        $confirmLabel.Text = "Confirm Password:"
        $confirmLabel.Location = New-Object System.Drawing.Point(10, 55)
        $confirmLabel.AutoSize = $true
        $pwdForm.Controls.Add($confirmLabel)

        $confirmTextBox = New-Object System.Windows.Forms.TextBox
        $confirmTextBox.Location = New-Object System.Drawing.Point(130, 52)
        $confirmTextBox.Width = 220
        $confirmTextBox.UseSystemPasswordChar = $true
        $pwdForm.Controls.Add($confirmTextBox)

        # Must change password checkbox
        $mustChangeCheckbox = New-Object System.Windows.Forms.CheckBox
        $mustChangeCheckbox.Text = "User must change password at next logon"
        $mustChangeCheckbox.Location = New-Object System.Drawing.Point(10, 90)
        $mustChangeCheckbox.AutoSize = $true
        $mustChangeCheckbox.Checked = $true
        $pwdForm.Controls.Add($mustChangeCheckbox)

        # Show password checkbox
        $showPwdCheckbox = New-Object System.Windows.Forms.CheckBox
        $showPwdCheckbox.Text = "Show passwords"
        $showPwdCheckbox.Location = New-Object System.Drawing.Point(10, 115)
        $showPwdCheckbox.AutoSize = $true
        $showPwdCheckbox.Add_CheckedChanged({
            $pwdTextBox.UseSystemPasswordChar = -not $showPwdCheckbox.Checked
            $confirmTextBox.UseSystemPasswordChar = -not $showPwdCheckbox.Checked
        })
        $pwdForm.Controls.Add($showPwdCheckbox)

        # OK button
        $okBtn = New-Object System.Windows.Forms.Button
        $okBtn.Text = "Reset Password"
        $okBtn.Location = New-Object System.Drawing.Point(115, 150)
        $okBtn.Width = 120
        $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $pwdForm.Controls.Add($okBtn)

        # Cancel button
        $cancelBtn = New-Object System.Windows.Forms.Button
        $cancelBtn.Text = "Cancel"
        $cancelBtn.Location = New-Object System.Drawing.Point(240, 150)
        $cancelBtn.Width = 75
        $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $pwdForm.Controls.Add($cancelBtn)

        $pwdForm.AcceptButton = $okBtn
        $pwdForm.CancelButton = $cancelBtn

        if ($pwdForm.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $newPassword = $pwdTextBox.Text
            $confirmPassword = $confirmTextBox.Text

            # Validate passwords match
            if ($newPassword -ne $confirmPassword) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Passwords do not match!",
                    "Validation Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
                $pwdForm.Dispose()
                return
            }

            # Validate password not empty
            if (-not $newPassword) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Password cannot be empty!",
                    "Validation Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
                $pwdForm.Dispose()
                return
            }

            $mustChange = $mustChangeCheckbox.Checked

            # Reset password
            $result = & $resetADPasswordRef -Username $username -NewPassword $newPassword -MustChangePassword $mustChange -LogBox $logBoxRef

            if ($result.Success) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Password reset successfully for: $username",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                # Refresh user info
                $searchBtn.PerformClick()
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to reset password:`n`n$($result.Message)",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        }

        $pwdForm.Dispose()
    }.GetNewClosure())

    # Copy groups button
    $script:copyGroupsBtn.Add_Click({
        if (-not $script:currentUserData -or $script:currentUserData.Groups.Count -eq 0) { return }

        $groupList = $script:currentUserData.Groups -join "`r`n"
        [System.Windows.Forms.Clipboard]::SetText($groupList)
        [System.Windows.Forms.MessageBox]::Show("Copied $($script:currentUserData.Groups.Count) groups to clipboard!", "Info", [System.Windows.Forms.MessageBoxButtons]::OK)
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

    # Log module load
    $timestamp = Get-Date -Format "HH:mm:ss"
    $script:adLogBox.AppendText("[$timestamp] AD Tools module loaded (ADSI-based, no RSAT)`r`n")
}

#endregion
