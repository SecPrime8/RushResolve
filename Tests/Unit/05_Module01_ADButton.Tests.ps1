# Module 1: AD Tools Button Tests
# Verifies AD button checks for RSAT installation before launching

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 1: Active Directory Button" {
    Context "RSAT Installation Check" {
        It "Should check if dsa.msc exists before launching" {
            $scriptContent = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should construct path to dsa.msc and use Test-Path
            $scriptContent | Should -Match 'dsa\.msc'
            $scriptContent | Should -Match 'Test-Path.*\$dsaPath'
        }

        It "Should show error message if RSAT not installed" {
            $scriptContent = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should have error handling for missing RSAT
            $scriptContent | Should -Match 'RSAT|Remote Server Administration Tools'
        }

        It "Should check system32 directory for dsa.msc" {
            $scriptContent = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should construct path to system32\dsa.msc
            $scriptContent | Should -Match '\$env:SystemRoot.*dsa\.msc|\$env:windir.*dsa\.msc|system32.*dsa\.msc'
        }
    }

    Context "AD Launch Functionality" {
        It "Should use Start-ElevatedProcess for AD launch" {
            $scriptContent = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should still use elevated process wrapper
            $scriptContent | Should -Match 'Start-ElevatedProcess.*dsa\.msc'
        }

        It "Should provide helpful error message with RSAT install instructions" {
            $scriptContent = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should mention how to install RSAT
            $scriptContent | Should -Match 'Add-WindowsCapability|Install RSAT|download RSAT'
        }
    }
}
