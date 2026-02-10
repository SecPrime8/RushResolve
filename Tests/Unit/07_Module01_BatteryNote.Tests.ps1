# Module 1: Battery Report Note Removal Tests
# Verifies obsolete "Battery Report moved to dedicated module" note is removed

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 1: Battery Report Note Removal" {
    Context "Obsolete note should not exist" {
        It "Should NOT have Battery Report note label" {
            $module1Content = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should NOT contain battery report note
            $module1Content | Should -Not -Match 'Battery Report moved to dedicated module'
        }

        It "Should NOT have noteLabel for battery report" {
            $module1Content = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should NOT have $noteLabel variable used for battery message
            $module1Content | Should -Not -Match '\$noteLabel.*Battery'
        }

        It "Should NOT reference battery report relocation" {
            $module1Content = Get-Content "$script:AppPath/Modules/01_SystemInfo.ps1" -Raw

            # Should NOT mention battery report at all
            $module1Content | Should -Not -Match 'battery.*report|Battery.*Report'
        }
    }
}
