# Module 5: Network Scan Copy Button Tests
# Verifies copy button exists and copies scan results to clipboard

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 5: Network Scan Copy Button" {
    Context "Copy button existence" {
        It "Should have copy button in network scan section" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have copy button near scan button
            $scriptContent | Should -Match '\$\w*[Cc]opy.*Button|\$\w*copyBtn'
        }

        It "Should have copy button text label" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Copy button should have descriptive text
            $scriptContent | Should -Match '\.Text\s*=\s*["\x27].*Copy.*["\x27]'
        }

        It "Should add copy button to networks button panel" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should add copy button to networksBtnPanel
            $scriptContent | Should -Match 'networksBtnPanel\.Controls\.Add.*copy'
        }
    }

    Context "Copy button functionality" {
        It "Should have click handler for copy button" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Copy button should have Add_Click event
            # Look for pattern near copy button definition
            $scriptContent | Should -Match 'copy.*Add_Click|Add_Click.*copy'
        }

        It "Should use Set-Clipboard or clipboard API" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should use clipboard functionality
            $scriptContent | Should -Match 'Set-Clipboard|\[System\.Windows\.Forms\.Clipboard\]'
        }

        It "Should access networks ListView for copy data" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Copy should read from networksListView
            $scriptContent | Should -Match 'networksListView.*Items|Items.*networksListView'
        }
    }

    Context "Copy button UI properties" {
        It "Should have appropriate width for button" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Find copy button width assignment (should be >= 75px)
            # This is a simple check that button has width property
            $scriptContent | Should -Match 'copy.*Width\s*=|Width\s*=.*\d+.*copy'
        }

        It "Should position copy button in same panel as scan button" {
            $modulePath = "$script:AppPath/Modules/05_NetworkTools.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Both scan and copy buttons should be in networksBtnPanel
            $scriptContent | Should -Match 'scanBtn.*networksBtnPanel|networksBtnPanel.*scanBtn'
            $scriptContent | Should -Match 'copy.*networksBtnPanel|networksBtnPanel.*copy'
        }
    }
}
