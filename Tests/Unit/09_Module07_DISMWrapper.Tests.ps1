# Module 7: DISM Credential Wrapper Tests
# Verifies DISM uses Start-ElevatedProcess credential wrapper

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 7: DISM Credential Wrapper" {
    Context "DISM button implementation" {
        It "Should use Start-ElevatedProcess for DISM" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should use standard Start-ElevatedProcess wrapper
            $scriptContent | Should -Match '\$dismBtn.*Add_Click'
            # Looking for Start-ElevatedProcess in DISM button handler
            $scriptContent | Should -Match 'Start-ElevatedProcess.*-FilePath.*powershell'
        }

        It "Should run DISM through PowerShell wrapper" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # DISM runs via PowerShell for visible progress window
            $scriptContent | Should -Match 'FilePath.*powershell\.exe'
            $scriptContent | Should -Match 'dismCommand'
        }

        It "Should include proper DISM arguments" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have DISM RestoreHealth arguments
            $scriptContent | Should -Match '/Online'
            $scriptContent | Should -Match '/Cleanup-Image'
            $scriptContent | Should -Match '/RestoreHealth'
        }

        It "Should have operation name for logging" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have OperationName parameter with DISM reference
            $scriptContent | Should -Match 'OperationName.*run DISM'
        }

        It "Should NOT use Invoke-Elevated for DISM" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should use Start-ElevatedProcess, not Invoke-Elevated
            # Check that DISM-related code doesn't use Invoke-Elevated
            if ($scriptContent -match 'DISM.*Invoke-Elevated|Invoke-Elevated.*DISM') {
                # Found Invoke-Elevated being used with DISM - fail
                $true | Should -Be $false
            }
        }
    }

    Context "SFC button for comparison" {
        It "Should also use Start-ElevatedProcess for SFC" {
            $modulePath = "$script:AppPath/Modules/07_Diagnostics.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # SFC should also be updated to use consistent wrapper
            $scriptContent | Should -Match '\$sfcBtn.*Add_Click'
            # Check if using Start-ElevatedProcess
            $scriptContent | Should -Match 'Start-ElevatedProcess.*sfc'
        }
    }
}
