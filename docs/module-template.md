# Module Developer Guide

## Overview

Windows Tech Toolkit uses a drop-in module system. Each `.ps1` file in the `Modules/` folder becomes a tab in the application.

## Module Requirements

Every module MUST define:

1. `$script:ModuleName` - Display name for the tab
2. `$script:ModuleDescription` - Tooltip text (optional but recommended)
3. `Initialize-Module` function - Sets up the tab's UI

## Basic Template

```powershell
<#
.SYNOPSIS
    Brief description of what this module does
#>

$script:ModuleName = "My Module"
$script:ModuleDescription = "Does something useful for IT technicians"

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Create your UI here
    # Add controls to $tab
}
```

## Available Helper Functions

The main application provides these functions to all modules:

### Credential Elevation

```powershell
# Prompt for admin credentials
$cred = Get-ElevatedCredential -Message "Enter admin credentials to do X"

# Run PowerShell code as admin
$result = Invoke-Elevated -ScriptBlock {
    # Your admin code here
    Restart-Service -Name Spooler -Force
} -OperationName "restart Print Spooler"

if ($result.Success) {
    # Operation succeeded
    $output = $result.Output
} else {
    # Operation failed
    $error = $result.Error
}

# Run an executable as admin
$result = Start-ElevatedProcess -FilePath "msiexec.exe" `
    -ArgumentList "/i installer.msi /qn" `
    -Wait -Hidden `
    -OperationName "install software"
```

### UI Helpers

```powershell
# Create standard log output textbox
$logBox = New-OutputTextBox
$logBox.Height = 150
$tab.Controls.Add($logBox)

# Write timestamped log entry
Write-Log -TextBox $logBox -Message "Operation completed"

# Create standard button (with optional elevation indicator)
$btn = New-Button -Text "Do Something" -Width 120 -RequiresElevation
```

### Settings

```powershell
# Get a module-specific setting
$value = Get-ModuleSetting -ModuleName "MyModule" -Key "someSetting" -Default "defaultValue"

# Save a module-specific setting
Set-ModuleSetting -ModuleName "MyModule" -Key "someSetting" -Value "newValue"
```

## UI Patterns

### Standard Layout

Most modules use this layout:
- Top: Main content area (info display, lists, etc.)
- Middle: Button bar for actions
- Bottom: Log output textbox

### Button Styling

- **Normal buttons**: Default styling
- **Elevation required**: Yellow background with `*` suffix
- **Destructive actions**: Red/pink background

### Naming Convention

Module files should be named with numeric prefixes for ordering:
- `01_SystemInfo.ps1`
- `02_SoftwareInstaller.ps1`
- `03_PrinterManagement.ps1`

## Complete Example

```powershell
$script:ModuleName = "Service Manager"
$script:ModuleDescription = "Start, stop, and restart Windows services"

function Initialize-Module {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabPage]$tab
    )

    # Service list
    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Dock = [System.Windows.Forms.DockStyle]::Top
    $listBox.Height = 300

    # Populate services
    Get-Service | ForEach-Object {
        $listBox.Items.Add("$($_.Status) - $($_.DisplayName)")
    }

    # Button panel
    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $buttonPanel.Height = 50

    # Restart button (requires elevation)
    $restartBtn = New-Object System.Windows.Forms.Button
    $restartBtn.Text = "Restart Service *"
    $restartBtn.Width = 120
    $restartBtn.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    $restartBtn.Add_Click({
        $selected = $listBox.SelectedItem
        if ($selected) {
            $serviceName = ($selected -split ' - ')[1]
            $result = Invoke-Elevated -ScriptBlock {
                param($name)
                Restart-Service -DisplayName $name -Force
            } -ArgumentList $serviceName -OperationName "restart $serviceName"

            if ($result.Success) {
                Write-Log -TextBox $logBox -Message "Restarted: $serviceName"
            } else {
                Write-Log -TextBox $logBox -Message "ERROR: $($result.Error)"
            }
        }
    })
    $buttonPanel.Controls.Add($restartBtn)

    # Log box
    $logBox = New-OutputTextBox

    # Add controls
    $tab.Controls.Add($logBox)
    $tab.Controls.Add($buttonPanel)
    $tab.Controls.Add($listBox)

    Write-Log -TextBox $logBox -Message "Service Manager loaded"
}
```

## Testing Your Module

1. Save your `.ps1` file in the `Modules/` folder
2. Restart TechToolkit.ps1
3. Your module should appear as a new tab
4. If it doesn't load, check the PowerShell console for error messages

## Common Issues

### Module doesn't appear
- Check that `$script:ModuleName` is defined
- Check that `Initialize-Module` function exists
- Check for syntax errors in your script

### Elevation doesn't work
- Ensure you're using `Invoke-Elevated` or `Start-ElevatedProcess`
- Check that credentials are valid
- Look for error messages in the log output

### UI doesn't display correctly
- Remember to add controls to `$tab`, not create a new form
- Use `Dock` property for responsive layouts
- Test with different window sizes
