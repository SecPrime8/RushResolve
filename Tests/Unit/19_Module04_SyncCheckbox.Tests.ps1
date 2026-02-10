# Module 4: Sync Checkbox Clarification Tests
# Verifies the Sync checkbox has clear purpose explanation

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 4: Sync Checkbox Purpose" {
    Context "Checkbox existence and purpose" {
        It "Should have Sync checkbox control" {
            $modulePath = "$script:AppPath/Modules/04_DomainTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have the checkbox defined (with or without namespace)
            $scriptContent | Should -Match '\$[\w:]*[Ss]yncCheckbox.*=.*New-Object.*(System\.Windows\.Forms\.)?CheckBox'
        }

        It "Should have GPUpdate function that uses Sync parameter" {
            $modulePath = "$script:AppPath/Modules/04_DomainTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have GPUpdate function with -Sync parameter
            $scriptContent | Should -Match 'param.*\[bool\]\$Sync'
            $scriptContent | Should -Match 'gpupdate|/sync'
        }

        It "Should pass Sync checkbox value to GPUpdate function" {
            $modulePath = "$script:AppPath/Modules/04_DomainTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should pass checkbox value to function
            $scriptContent | Should -Match 'syncCheckbox.*Checked|Checked.*syncCheckbox'
        }
    }

    Context "Tooltip documentation" {
        It "Should have tooltip explaining Sync checkbox purpose" {
            $modulePath = "$script:AppPath/Modules/04_DomainTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have ToolTipText property set
            # Tooltip should explain synchronous processing or /sync flag
            $hasTooltip = $scriptContent -match 'syncCheckbox\.\s*Add_MouseHover|ToolTip.*syncCheckbox|syncCheckbox\.Text.*=.*"Sync"[\s\S]{0,200}#.*sync'

            # Alternative: Check if there's a comment explaining it near the checkbox (before or after)
            $hasCommentAfter = $scriptContent -match '\$[\w:]*syncCheckbox[\s\S]{0,100}#.*(synchronous|wait|gpupdate.*sync)'
            $hasCommentBefore = $scriptContent -match '#.*(synchronous|wait|gpupdate.*sync)[\s\S]{0,300}\$[\w:]*syncCheckbox'
            $hasComment = $hasCommentAfter -or $hasCommentBefore

            ($hasTooltip -or $hasComment) | Should -Be $true
        }

        It "Should explain that Sync forces synchronous Group Policy processing" {
            $modulePath = "$script:AppPath/Modules/04_DomainTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have documentation mentioning:
            # - Synchronous processing
            # - Waiting for completion
            # - /sync flag
            # - GPUpdate behavior
            $hasDoc = $scriptContent -match '(?i)(synchronous.*policy|gpupdate.*sync|wait.*complet|force.*foreground)'

            $hasDoc | Should -Be $true
        }
    }

    Context "User experience improvements" {
        It "Should have clear checkbox text label" {
            $modulePath = "$script:AppPath/Modules/04_DomainTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Checkbox text should be clear
            # Current: "Sync" - could be improved to "Sync (Wait for completion)"
            $scriptContent | Should -Match 'syncCheckbox\.Text\s*=\s*"[^"]+'
        }

        It "Should be positioned near GPUpdate button" {
            $modulePath = "$script:AppPath/Modules/04_DomainTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Sync checkbox should be defined near gpupdateBtn for context
            # They should be in same panel/section
            $gpupdatePos = $scriptContent.IndexOf('gpupdateBtn')
            $syncPos = $scriptContent.IndexOf('syncCheckbox')

            # Should be within 600 characters (allows for documentation comments)
            [Math]::Abs($gpupdatePos - $syncPos) | Should -BeLessThan 600
        }
    }
}
