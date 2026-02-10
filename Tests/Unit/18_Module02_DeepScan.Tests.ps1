# Module 2: Deep Subdirectory Scan Tests
# Verifies installer scanning reaches nested folders beyond 2 levels

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 2: Deep Subdirectory Scanning" {
    Context "Recursive scanning capability" {
        It "Should use Get-ChildItem with recursive flag" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have Get-ChildItem with -Recurse parameter
            # Looking for installer scanning specifically
            $scriptContent | Should -Match 'Get-ChildItem.*-Recurse'
        }

        It "Should have depth control parameter" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should either have -Depth parameter or explicit depth logic
            # -Depth 5 is reasonable (up to 5 levels deep)
            $hasDepthParam = $scriptContent -match 'Get-ChildItem.*-Depth'
            $hasDepthLogic = $scriptContent -match '\$depth|level.*\d+'

            ($hasDepthParam -or $hasDepthLogic) | Should -Be $true
        }

        It "Should scan beyond 2 levels deep" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Check if depth is set to more than 2
            # Either -Depth 3+ or recursive without depth limit
            $hasRecurse = $scriptContent -match 'Get-ChildItem.*-Recurse'

            # If has -Depth, should be 3 or higher
            if ($scriptContent -match '-Depth\s+(\d+)') {
                $depthValue = [int]$matches[1]
                $depthValue | Should -BeGreaterOrEqual 3
            }
            else {
                # No depth limit - fully recursive
                $hasRecurse | Should -Be $true
            }
        }
    }

    Context "Installer file detection" {
        It "Should search for .exe and .msi files" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should filter for installer file types
            $scriptContent | Should -Match '\.exe|\.msi|\$_.Extension.*\.exe|Extension.*-in.*\.exe'
        }

        It "Should use file filter to limit results" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should use -File or -Filter to get only files (not directories)
            $scriptContent | Should -Match 'Get-ChildItem.*-File|-Filter.*\.(exe|msi)'
        }
    }

    Context "Performance considerations" {
        It "Should have error handling for large directory structures" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have -ErrorAction to handle permission denied, etc.
            $scriptContent | Should -Match 'Get-ChildItem.*-ErrorAction'
        }

        It "Should provide progress feedback during scan" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should log scanning progress
            $scriptContent | Should -Match 'Scanning|AppendText.*Scan|logMsg'
        }
    }

    Context "Backward compatibility" {
        It "Should still support existing 2-level scanning logic" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have the ScanForApps scriptblock or function
            $scriptContent | Should -Match '\$script:ScanForApps|function.*Scan.*App'
        }

        It "Should preserve folder-by-folder processing for config files" {
            $modulePath = "$script:AppPath/Modules/02_SoftwareInstaller.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should still process install.json config files
            $scriptContent | Should -Match 'install\.json|config.*json'
        }
    }
}
