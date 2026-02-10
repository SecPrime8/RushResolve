# Mock Helper Functions for RushResolve Testing
# Provides reusable mock generators for CIM/WMI objects, network adapters, and disk information

<#
.SYNOPSIS
    Creates a mock CIM instance object with default or custom properties.
.DESCRIPTION
    Generates mock CIM objects to simulate Get-CimInstance results without requiring actual system queries.
.PARAMETER ClassName
    The CIM class name to mock (e.g., 'Win32_ComputerSystem', 'Win32_Processor')
.PARAMETER Properties
    Hashtable of custom properties to override defaults
#>
function New-MockCimInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClassName,

        [Parameter(Mandatory = $false)]
        [hashtable]$Properties = @{}
    )

    # Get computer name with fallback for non-Windows systems
    $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'TESTPC01' }
    $userName = if ($env:USERNAME) { $env:USERNAME } else { 'testuser' }
    $userDomain = if ($env:USERDOMAIN) { $env:USERDOMAIN } else { 'RUSHHEALTH' }

    $defaults = @{
        'Win32_ComputerSystem' = @{
            Name                 = $computerName
            Manufacturer         = 'Dell Inc.'
            Model                = 'OptiPlex 7010'
            TotalPhysicalMemory  = 17179869184  # 16 GB
            Domain               = 'RUSHHEALTH.local'
            PartOfDomain         = $true
            UserName             = "$userDomain\$userName"
            DNSHostName          = "$computerName.rushhealth.local"
            Workgroup            = $null
        }

        'Win32_Processor' = @{
            Name                   = 'Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz'
            Manufacturer           = 'GenuineIntel'
            NumberOfCores          = 6
            NumberOfLogicalProcessors = 12
            MaxClockSpeed          = 3200
            CurrentClockSpeed      = 3200
            ProcessorId            = 'BFEBFBFF000906EA'
        }

        'Win32_OperatingSystem' = @{
            Caption                = 'Microsoft Windows 10 Enterprise'
            Version                = '10.0.19045'
            BuildNumber            = '19045'
            OSArchitecture         = '64-bit'
            LastBootUpTime         = (Get-Date).AddHours(-8)
            LocalDateTime          = Get-Date
            FreePhysicalMemory     = 8388608  # 8 GB
            TotalVisibleMemorySize = 16777216  # 16 GB
            InstallDate            = (Get-Date).AddMonths(-6)
        }

        'Win32_BIOS' = @{
            Manufacturer     = 'Dell Inc.'
            SerialNumber     = 'ABCD1234'
            SMBIOSBIOSVersion = 'A25'
            ReleaseDate      = '20220115000000.000000+000'
        }

        'Win32_LogicalDisk' = @{
            DeviceID          = 'C:'
            DriveType         = 3  # Local Disk
            FileSystem        = 'NTFS'
            Size              = 256060514304  # 256 GB
            FreeSpace         = 128030257152  # 128 GB
            VolumeName        = 'Windows'
            VolumeSerialNumber = '1A2B3C4D'
        }

        'Win32_NetworkAdapter' = @{
            Name               = 'Intel(R) Ethernet Connection'
            AdapterType        = 'Ethernet 802.3'
            MACAddress         = '00:11:22:33:44:55'
            NetConnectionID    = 'Ethernet'
            PhysicalAdapter    = $true
            NetEnabled         = $true
            Speed              = 1000000000  # 1 Gbps
        }
    }

    if ($defaults.ContainsKey($ClassName)) {
        $baseProperties = $defaults[$ClassName].Clone()

        # Override with custom properties
        foreach ($key in $Properties.Keys) {
            $baseProperties[$key] = $Properties[$key]
        }

        return [PSCustomObject]$baseProperties
    } else {
        Write-Warning "No default mock for class '$ClassName'. Returning empty object with custom properties."
        return [PSCustomObject]$Properties
    }
}

<#
.SYNOPSIS
    Creates a mock network adapter object.
.DESCRIPTION
    Generates mock network adapter data to simulate Get-NetAdapter results.
.PARAMETER Name
    The adapter name
.PARAMETER Properties
    Hashtable of custom properties
#>
function New-MockNetAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Name = 'Ethernet',

        [Parameter(Mandatory = $false)]
        [hashtable]$Properties = @{}
    )

    $defaults = @{
        Name                  = $Name
        InterfaceDescription  = 'Intel(R) Ethernet Connection'
        ifIndex               = 12
        Status                = 'Up'
        MacAddress            = '00-11-22-33-44-55'
        LinkSpeed             = '1 Gbps'
        MediaType             = '802.3'
        PhysicalMediaType     = '802.3'
        AdminStatus           = 'Up'
        InterfaceOperationalStatus = 'Up'
        Virtual               = $false
    }

    foreach ($key in $Properties.Keys) {
        $defaults[$key] = $Properties[$key]
    }

    return [PSCustomObject]$defaults
}

<#
.SYNOPSIS
    Creates a mock disk information object.
.DESCRIPTION
    Generates mock disk data for testing disk-related functions.
.PARAMETER DriveLetter
    The drive letter (e.g., 'C:')
.PARAMETER Properties
    Hashtable of custom properties
#>
function New-MockDiskInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$DriveLetter = 'C:',

        [Parameter(Mandatory = $false)]
        [hashtable]$Properties = @{}
    )

    $defaults = @{
        DeviceID          = $DriveLetter
        DriveType         = 3  # Local Disk
        FileSystem        = 'NTFS'
        Size              = 256060514304  # 256 GB
        FreeSpace         = 128030257152  # 128 GB
        UsedSpace         = 128030257152  # 128 GB
        PercentFree       = 50.0
        VolumeName        = 'Windows'
        VolumeSerialNumber = '1A2B3C4D'
    }

    foreach ($key in $Properties.Keys) {
        $defaults[$key] = $Properties[$key]
    }

    return [PSCustomObject]$defaults
}

<#
.SYNOPSIS
    Creates a mock printer object.
.DESCRIPTION
    Generates mock printer data to simulate Get-Printer results.
.PARAMETER Name
    The printer name
.PARAMETER Properties
    Hashtable of custom properties
#>
function New-MockPrinter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Name = 'HP LaserJet Pro',

        [Parameter(Mandatory = $false)]
        [hashtable]$Properties = @{}
    )

    $defaults = @{
        Name            = $Name
        ComputerName    = $env:COMPUTERNAME
        Type            = 'Connection'
        DriverName      = 'HP Universal Printing PCL 6'
        PortName        = 'IP_192.168.1.10'
        Shared          = $false
        Published       = $false
        ShareName       = $null
        Location        = 'Office 101'
        Comment         = 'Department Printer'
        PrinterStatus   = 'Normal'
        JobCount        = 0
    }

    foreach ($key in $Properties.Keys) {
        $defaults[$key] = $Properties[$key]
    }

    return [PSCustomObject]$defaults
}

# Functions are available when dot-sourced
# No Export-ModuleMember needed for script files
