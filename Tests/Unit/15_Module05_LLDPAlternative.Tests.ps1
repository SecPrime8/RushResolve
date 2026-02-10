# Module 5: LLDP Alternative Method Tests
# Verifies fallback methods when LLDP is unavailable

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 5: LLDP Alternative Methods" {
    Context "LLDP availability check" {
        It "Should have function to test LLDP availability" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have function or check for LLDP availability (DCB feature)
            $scriptContent | Should -Match 'DataCenterBridging|Test.*LLDP|LLDP.*Available'
        }

        It "Should check for DCB feature before attempting LLDP" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should check Windows optional feature for DCB
            $scriptContent | Should -Match 'Get-WindowsOptionalFeature.*DataCenterBridging'
        }
    }

    Context "Fallback methods when LLDP unavailable" {
        It "Should provide gateway info as fallback" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have method to get gateway/network info
            $scriptContent | Should -Match 'Get-NetRoute|gateway|DefaultGateway'
        }

        It "Should show helpful message when LLDP not available" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have error/info message about LLDP setup
            $scriptContent | Should -Match 'Setup LLDP|LLDP.*not.*enabled|DCB.*required'
        }

        It "Should handle LLDP errors gracefully" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have try-catch or error handling for LLDP operations
            # Pattern matches: Get-NetLldpAgent ... -ErrorAction Stop
            $scriptContent | Should -Match '[Ll][Ll][Dd][Pp].*-ErrorAction|try.*\{[\s\S]{0,500}Get-NetLldpAgent'
        }
    }

    Context "Network info without LLDP" {
        It "Should display basic network info when LLDP fails" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have basic network adapter info display
            $scriptContent | Should -Match 'Get-NetAdapter|Get-NetIPConfiguration'
        }

        It "Should show connected switch/gateway IP" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should extract or display gateway information
            $scriptContent | Should -Match 'NextHop|Gateway|0\.0\.0\.0/0'
        }

        It "Should have LLDP info display labels" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have UI labels for switch info
            $scriptContent | Should -Match 'Switch|Port.*Desc|VLAN|lldpLabel'
        }
    }

    Context "Alternative discovery methods" {
        It "Should support ARP table query as fallback" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have capability to query ARP or neighbors
            # Using Get-NetNeighbor or arp command
            $scriptContent | Should -Match 'Get-NetNeighbor|Get-NetRoute|arp|neighbor'
        }

        It "Should provide link to setup instructions" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have setup button or instructions
            $scriptContent | Should -Match 'Setup.*LLDP|setupLldp|Install.*DCB'
        }
    }
}
