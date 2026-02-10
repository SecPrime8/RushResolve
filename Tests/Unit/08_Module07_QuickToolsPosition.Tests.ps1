# Module 7: Quick Tools Button Position Tests
# Verifies quick tools panel is positioned appropriately high in the form

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 7: Quick Tools Panel Position" {
    Context "Panel positioning in layout" {
        It "Should have Quick Tools panel early in the module" {
            $scriptContent = Get-Content "$script:AppPath/Modules/07_Diagnostics.ps1" -Raw

            # Quick Tools should be in Row 1 (second row) of TableLayoutPanel
            # and should have small row index
            $scriptContent | Should -Match '\$quickToolsGroup'
            $scriptContent | Should -Match '\$mainLayout\.Controls\.Add\(\$quickToolsGroup, 0, 1\)'
        }

        It "Should have appropriate row height for Quick Tools" {
            $scriptContent = Get-Content "$script:AppPath/Modules/07_Diagnostics.ps1" -Raw

            # Row 1 should have adequate height (60px or similar)
            # Looking for RowStyle with Absolute sizing around 50-80px
            $scriptContent | Should -Match 'RowStyle.*Absolute.*[56]\d\)'
        }

        It "Should place Quick Tools before large content areas" {
            $scriptContent = Get-Content "$script:AppPath/Modules/07_Diagnostics.ps1" -Raw

            # Verify order: buttonPanel at row 0, quickTools at row 1
            $buttonMatch = $scriptContent -match '\$mainLayout\.Controls\.Add\(\$buttonPanel, 0, 0\)'
            $quickMatch = $scriptContent -match '\$mainLayout\.Controls\.Add\(\$quickToolsGroup, 0, 1\)'

            ($buttonMatch -and $quickMatch) | Should -Be $true
        }
    }

    Context "Quick Tools panel structure" {
        It "Should have GroupBox wrapping the tools" {
            $scriptContent = Get-Content "$script:AppPath/Modules/07_Diagnostics.ps1" -Raw

            # Should have GroupBox for Quick Tools
            $scriptContent | Should -Match '\$quickToolsGroup.*GroupBox'
            $scriptContent | Should -Match 'Text = "Quick Tools"'
        }

        It "Should have FlowLayoutPanel for button arrangement" {
            $scriptContent = Get-Content "$script:AppPath/Modules/07_Diagnostics.ps1" -Raw

            # Should use FlowLayoutPanel for buttons
            $scriptContent | Should -Match '\$quickToolsPanel.*FlowLayoutPanel'
        }

        It "Should have all diagnostic tool buttons" {
            $scriptContent = Get-Content "$script:AppPath/Modules/07_Diagnostics.ps1" -Raw

            # Should have common diagnostic tools
            $scriptContent | Should -Match '\$chkdskBtn'
            $scriptContent | Should -Match '\$sfcBtn'
            $scriptContent | Should -Match '\$dismBtn'
            $scriptContent | Should -Match '\$eventViewerBtn'
        }
    }
}
