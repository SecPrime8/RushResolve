# Module 2: WinGet Removal Tests
# Verifies WinGet functionality removed from stable branch

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 2: WinGet Removed from Stable" {
    Context "WinGet references removed" {
        It "Should not have active WinGet scan function" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Remove all comment blocks first (multi-line comments)
            $activeCode = $scriptContent -replace '(?s)<#.*?#>', ''

            # Should not have actual winget command calls (not just messages)
            # Look for: winget upgrade, winget install, Get-Command winget (active calls)
            $activeWinGetCalls = $activeCode -split "`n" | Where-Object {
                $_ -match 'winget\s+(upgrade|install|list|search)' -and $_ -notmatch '^\s*#'
            }
            $activeWinGetCalls | Should -BeNullOrEmpty
        }

        It "Should not reference WinGet in UI labels" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # UI labels should not mention WinGet (unless in comments)
            # Check for .Text = "...WinGet..." that's not commented
            $wingetLabels = $scriptContent -split "`n" | Where-Object {
                $_ -match '\.Text\s*=.*[Ww]in[Gg]et' -and $_ -notmatch '^\s*#'
            }
            $wingetLabels | Should -BeNullOrEmpty
        }

        It "Should not have Get-Command winget checks" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Remove all comment blocks first (multi-line comments)
            $activeCode = $scriptContent -replace '(?s)<#.*?#>', ''

            # Should not have active WinGet availability checks (outside comments)
            $wingetChecks = $activeCode -split "`n" | Where-Object {
                $_ -match 'Get-Command.*winget' -and $_ -notmatch '^\s*#'
            }
            $wingetChecks | Should -BeNullOrEmpty
        }
    }

    Context "WinGet code commented out" {
        It "Should have commented WinGet note explaining removal" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have comment explaining WinGet removed/moved
            $scriptContent | Should -Match '#.*[Ww]in[Gg]et.*(removed|moved|disabled|blocked|dev branch|development)'
        }

        It "Should preserve WinGet code in comments for reference" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Original WinGet code should exist but commented
            $scriptContent | Should -Match '#.*winget.*upgrade'
        }
    }

    Context "Alternative update methods available" {
        It "Should still have manual installer scanning" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have folder scanning using Get-ChildItem
            $scriptContent | Should -Match 'Get-ChildItem.*-Path.*-File'
        }

        It "Should have software installation functionality" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should still support installing software using Start-ElevatedProcess
            $scriptContent | Should -Match 'Start-ElevatedProcess.*-FilePath'
        }
    }
}
