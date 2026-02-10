# Module 1: Installed Apps Button Relocation Tests
# Verifies Installed Apps button is NOT in Module 1 (should be in Module 2)

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 1: Installed Apps Button Removal" {
    Context "Button should not exist in Module 1" {
        It "Should NOT have Installed Apps button in Module 1" {
            $module1Content = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should NOT contain Installed Apps button creation
            # Looking for button with "Installed Apps" text
            $module1Content | Should -Not -Match '\$installedAppsBtn.*Text.*=.*"Installed Apps"'
        }

        It "Should NOT have Installed Apps click handler in Module 1" {
            $module1Content = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should NOT have the large click handler that creates the app form
            $module1Content | Should -Not -Match 'Installed Applications.*New-Object System\.Windows\.Forms\.Form'
        }

        It "Should NOT reference registry uninstall paths in Module 1" {
            $module1Content = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should NOT have the registry scanning code
            $module1Content | Should -Not -Match 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall'
        }
    }
}

Describe "Module 2: Installed Apps Button Presence" {
    Context "Button should exist in Module 2" {
        It "Should have Installed Apps button in Module 2" {
            $module2Content = Get-Content "$script:AppPath/Modules/02_SoftwareInstaller.ps1" -Raw

            # Should contain Installed Apps button creation
            $module2Content | Should -Match '\$installedAppsBtn.*Text.*=.*"Installed Apps"'
        }

        It "Should have Installed Apps functionality in Module 2" {
            $module2Content = Get-Content "$script:AppPath/Modules/02_SoftwareInstaller.ps1" -Raw

            # Should have the app form creation
            $module2Content | Should -Match 'Installed Applications'
        }
    }
}
