# Module 2: GPO Package Removal Tests
# Verifies GPO deployment functionality removed from stable branch

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 2: GPO Packages Removed from Stable" {
    Context "GPO references removed" {
        It "Should not have active GPO deployment functions" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Remove all comment blocks first (multi-line comments)
            $activeCode = $scriptContent -replace '(?s)<#.*?#>', ''

            # Should not have Group Policy deployment commands (not just messages)
            # Look for: Install-MSI via GPO, Deploy-GPOPackage, Group Policy Object operations
            $activeGPOCalls = $activeCode -split "`n" | Where-Object {
                $_ -match 'GPO|Group.*Policy|msiexec.*\/gp|Deploy.*Package' -and
                $_ -notmatch '^\s*#' -and
                $_ -notmatch 'Text\s*=' -and  # Exclude UI label assignments
                $_ -notmatch 'AppendText'      # Exclude log messages
            }
            $activeGPOCalls | Should -BeNullOrEmpty
        }

        It "Should not reference GPO in UI labels" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # UI labels should not mention GPO deployment (unless in comments)
            # Check for .Text = "...GPO..." or "...Group Policy..." that's not commented
            $gpoLabels = $scriptContent -split "`n" | Where-Object {
                $_ -match '\\.Text\\s*=.*(GPO|Group.*Policy.*Deploy)' -and
                $_ -notmatch '^\s*#' -and
                $_ -notmatch 'disabled|removed|moved|not available'  # Allow explanatory messages
            }
            $gpoLabels | Should -BeNullOrEmpty
        }

        It "Should not have New-GPO or Get-GPO cmdlets" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Remove all comment blocks first (multi-line comments)
            $activeCode = $scriptContent -replace '(?s)<#.*?#>', ''

            # Should not have active Group Policy cmdlets (outside comments)
            $gpoCommands = $activeCode -split "`n" | Where-Object {
                $_ -match '(New|Get|Set|Remove)-GPO' -and $_ -notmatch '^\s*#'
            }
            $gpoCommands | Should -BeNullOrEmpty
        }

        It "Should not have GPMC (Group Policy Management Console) references" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Remove all comment blocks first
            $activeCode = $scriptContent -replace '(?s)<#.*?#>', ''

            # Should not reference GPMC module or console
            $gpmcRefs = $activeCode -split "`n" | Where-Object {
                $_ -match 'Import-Module.*GroupPolicy|gpmc\.msc|GroupPolicy.*Module' -and
                $_ -notmatch '^\s*#'
            }
            $gpmcRefs | Should -BeNullOrEmpty
        }
    }

    Context "GPO code commented out" {
        It "Should have commented GPO note explaining removal" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have comment explaining GPO removed/moved
            $scriptContent | Should -Match '#.*(GPO|Group.*Policy).*(removed|moved|disabled|blocked|dev branch|development|not available)'
        }

        It "Should preserve GPO code in comments for reference" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Original GPO code should exist but commented (if there was any)
            # This test is more lenient - just checks for GPO mention in comments
            $hasGPOComment = $scriptContent -match '#.*GPO|<#[\s\S]*?GPO[\s\S]*?#>'

            # Either has GPO in comments OR never had GPO functionality
            $hasGPOComment | Should -BeTrue
        }
    }

    Context "Alternative deployment methods available" {
        It "Should still have manual installer functionality" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have manual installation using Start-ElevatedProcess
            $scriptContent | Should -Match 'Start-ElevatedProcess.*-FilePath'
        }

        It "Should have folder scanning for installers" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should still support folder scanning
            $scriptContent | Should -Match 'Get-ChildItem.*-Path.*-File'
        }
    }
}
