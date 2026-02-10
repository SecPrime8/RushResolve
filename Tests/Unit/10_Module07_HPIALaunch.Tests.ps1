# Module 7: HPIA Launch Tests
# Verifies HP Image Assistant launches correctly or shows helpful error

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 7: HPIA Launch" {
    Context "HP button and menu structure" {
        It "Should have HP button in diagnostics module" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have HP button defined (not hpiaBtn, just hpBtn)
            $scriptContent | Should -Match '\$hpBtn'
            $scriptContent | Should -Match 'HP Drivers'
        }

        It "Should have menu with driver check option" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have HP menu with check option
            $scriptContent | Should -Match '\$hpMenu'
            $scriptContent | Should -Match 'Check Drivers'
        }
    }

    Context "HPIA path detection" {
        It "Should have GetHPIAPath function" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have path detection function
            $scriptContent | Should -Match '\$script:GetHPIAPath'
        }

        It "Should check multiple installation paths" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should check common HPIA paths
            $scriptContent | Should -Match 'ProgramFiles.*HP\\HPIA'
            $scriptContent | Should -Match 'C:\\HPIA'
            $scriptContent | Should -Match 'HPImageAssistant\.exe'
        }

        It "Should check repo Tools folder first" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should check repo location first
            $scriptContent | Should -Match 'Tools\\HPIA'
        }
    }

    Context "HPIA error handling" {
        It "Should show error message if HPIA not found" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have user-friendly error message with download link
            $scriptContent | Should -Match 'HPIA not installed|HPIA Not Found'
            $scriptContent | Should -Match 'https://ftp.hp.com/pub/caps-softpaq/cmit/HPIA.html'
        }

        It "Should check if machine is HP before running" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have HP detection logic
            $scriptContent | Should -Match '\$script:DetectHP'
        }
    }

    Context "HPIA execution" {
        It "Should have RunHPIAAnalysis function" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have analysis function
            $scriptContent | Should -Match '\$script:RunHPIAAnalysis'
        }

        It "Should use ProcessStartInfo to launch HPIA" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should use proper process launching
            $scriptContent | Should -Match 'System\.Diagnostics\.ProcessStartInfo'
            $scriptContent | Should -Match 'FileName.*=.*hpiaPath'
        }

        It "Should run HPIA with proper arguments" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have HPIA command-line arguments
            $scriptContent | Should -Match '/Operation:Analyze'
            $scriptContent | Should -Match '/Action:List'
            $scriptContent | Should -Match '/Category:Drivers'
        }
    }
}
