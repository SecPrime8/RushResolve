# Define the KB number and path to the installer
$kbNumber = "KB2693643"


# Check if the KB is already installed
$kbInstalled = Get-HotFix | Where-Object {$_.HotFixID -eq $kbNumber}

if (-not $kbInstalled) {
    # If the KB is not present, install it
    Write-Host "Installing RSAT for $kbNumber..."
    $scriptPath = Join-Path $PWD.Path "WindowsTH-KB2693643-x64.msu"
    Start-Process -FilePath $scriptPath -ArgumentList "/quiet /norestart" -Wait
    Write-Host "Installation of $kbNumber initiated."
} else {
    # If the KB is already installed, notify the user
    Write-Host "$kbNumber is already installed. No changes made."
}


# Ensure script is run with Administrator privileges
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    $arguments = "& '" + $MyInvocation.MyCommand.Definition + "'"
    Start-Process powershell -Verb runAs -ArgumentList $arguments
    exit
}


# Import Active Directory module
Import-Module ActiveDirectory

# Define variables
$samAccountName = "$env:COMPUTERNAME`$"
$autoLoginUserName = "sbuser"
$distinguishedname = Get-ADUser -Identity $autoLoginUserName | Select-Object DistinguishedName
$allChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZbacdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()'


    # Generate password
    
    
    $password = ''
     For ($i = 1; $i -le 15; $i++)
     {  
        $index = Get-Random -Minimum 0 -Maximum $allChars.Length
        $password=$password + $allChars[$index]
        
    }


$cleartextpassword = "rushvdi@RUMC"

$password = $cleartextpassword | ConvertTo-SecureString -AsPlainText -Force





$adPath = "OU=MFTGREASEBOARD,OU=MEDICAL,OU=CAMPUS,DC=rush,DC=edu"

# Uninstall Office 365 Script
Write-Host "Starting the Office 365 uninstall process..."

# Define the path to the OfficeClickToRun executable
$officeClickToRunPath = "C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe"

# Check if the OfficeClickToRun.exe file exists
if (Test-Path $officeClickToRunPath) {
    # If the file exists, run the uninstall command
    cmd /c '"C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe" scenario=install scenariosubtype=ARP sourcetype=None productstoremove=O365ProPlusRetail.16_en-us_x-none culture=en-us version.16=16.0 DisplayLevel=False AcceptEULA=True ForceAppClose=True'
    
    Write-Host "Office 365 uninstall process complete."
} else {
    # If the file does not exist, display a message and continue script
    Write-Host "OfficeClickToRun.exe not found. Continuing Script."
}



# Uninstall Webex Teams Script
Write-Host "Starting the Webex Teams uninstall process..."

# Search for Webex Teams installation using its known product name
$webexTeams = Get-WmiObject -Query "SELECT * FROM Win32_Product WHERE Name LIKE '%Webex%'"

# If Webex Teams is found
if ($webexTeams) {
    foreach ($product in $webexTeams) {
        Write-Host "Found Webex product: $($product.Name)"
        Write-Host "Uninstalling $($product.Name)..."

        # Uninstall the product
        $product.Uninstall() | Out-Null

        Write-Host "$($product.Name) has been uninstalled."
    }
} else {
    Write-Host "No Webex Teams product found."
}

Write-Host "Webex Teams uninstall process complete."


#Uninstall Microsot Teams script
$registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"

# Remove Teams Machine-Wide Installer

Write-Host "Removing Teams Machine-wide Installer"

## Get all subkeys and match the subkey that contains "Teams Machine-Wide Installer" DisplayName.

$MachineWide = Get-ItemProperty -Path $registryPath | Where-Object -Property DisplayName -eq "Teams Machine-Wide Installer"

if ($MachineWide) {

Start-Process -FilePath "msiexec.exe" -ArgumentList "/x ""$($MachineWide.PSChildName)"" /qn" -NoNewWindow -Wait

}

else {

Write-Host "Teams Machine-Wide Installer not found"

}

# Uninstall LogonBox
Write-Host "Checking for LogonBox Credential Provider registry key..."

# Define the registry key path
$registryKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0BB77FA3-56BC-4744-BE62-19D4328837CC}"

# Check if the registry key exists
if (Test-Path $registryKeyPath) {
    Write-Host "Uninstalling LogonBox Credential Provider..."
    
    # Execute the msiexec command to uninstall
    Start-Process -FilePath "msiexec.exe" -ArgumentList "/X{0BB77FA3-56BC-4744-BE62-19D4328837CC} /qn" -NoNewWindow -Wait
    
    Write-Host "LogonBox Uninstall Process complete."
} else {
    # If the registry key does not exist, display a message
    Write-Host "LogonBox Credential Provider not found in the registry. Continuing script."
}


    $computergroups = ("Deny_Screen_Timeout_GPO", "mem_logonbox_sspr_6.2.1028_exclusion_device", "mem_epic_satellite_statusboard_device")
    foreach ($group in $computergroups) {

    Add-ADGroupMember -Identity $group -Members $samAccountName -ErrorAction SilentlyContinue
    }
    
    
#add autlogin to ext 13 attribute in ad
$adObjectType = "User"               # Replace with the type of your AD object (e.g., User, Computer, etc.)
$attributeName = "extensionAttribute13"             # The attribute to modify
$valueToAdd = "Autologin"            # The value to add

# Get the AD object
$adObject = Get-ADObject -Filter { Name -eq $autoLoginUserName -and objectClass -eq $adObjectType }

if ($adObject) {
    # Check current value of the ext13 attribute
    $currentValue = $adObject.$attributeName

    # Append the new value if it doesn't already exist
    if (-not ($currentValue -contains $valueToAdd)) {
        $newValue = if ($currentValue) { $currentValue + ";" + $valueToAdd } else { $valueToAdd }
        
        # Update the AD object with the new value
        Set-ADObject -Identity $adObject -Replace @{ $attributeName = $newValue }

        Write-Host "Successfully updated $attributeName for $adObjectName."
    } else {
        Write-Host "$valueToAdd already exists in $attributeName."
    }
} else {
    Write-Host "AD object '$adObjectName' not found."
}
    
    # Move the computer object to the specified OU
    $computer = Get-ADComputer -Identity $env:COMPUTERNAME
    Move-ADObject -Identity $computer.DistinguishedName -TargetPath $adPath


    # Configure AutoLogin registry settings
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty $RegPath "AutoAdminLogon" -Value "1" -type String
    Set-ItemProperty $RegPath "DefaultUsername" -Value $autoLoginUserName -type String
    Set-ItemProperty $RegPath "DefaultPassword" -Value 'Ru$h1631' -type String
    Set-ItemProperty $RegPath "DefaultDomainName" -Value Rush.edu -type String
    # Disable the CTRL+ALT+DELETE option
    # Define the registry path and the key name
    $keyName = "disablecad"
    $keyValue = 1
    $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $currentValue = Get-ItemProperty -Path $registryPath -Name $keyName -ErrorAction SilentlyContinue
    
        

    # Verify if the key exists and check its current value
    if ($currentValue -and $currentValue.$keyName -eq 0) {
        # If the key is set to 0, change it to 1
        Set-ItemProperty -Path $registryPath -Name $keyName -Value 1 -Type DWord
        Write-Host "The registry key '$keyName' has been changed from 0 to 1."
    } else {
   
        Write-Host "The registry key '$keyName' is already set to 1. No changes made."
    }

    Restart-Computer -Force