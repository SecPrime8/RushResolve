# Splash Screen Tests
# Verifies splash screen displays Rush logo and proper styling

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Splash Screen Logo" {
    Context "Logo asset file" {
        It "Should have Rush-logo.png in Assets folder" {
            $logoPath = Join-Path $script:AppPath "Assets/Rush-logo.png"
            Test-Path $logoPath | Should -Be $true
        }

        It "Logo file should not be empty" {
            $logoPath = Join-Path $script:AppPath "Assets/Rush-logo.png"
            $fileInfo = Get-Item $logoPath -ErrorAction SilentlyContinue
            $fileInfo.Length | Should -BeGreaterThan 0
        }
    }

    Context "Splash screen logo implementation" {
        It "Should have code to load logo from Assets folder" {
            $scriptContent = Get-Content "$script:AppPath/RushResolve.ps1" -Raw
            $scriptContent | Should -Match "Assets.*Rush-logo\.png"
        }

        It "Should create PictureBox for logo display" {
            $scriptContent = Get-Content "$script:AppPath/RushResolve.ps1" -Raw
            # Check for PictureBox creation in splash screen
            $scriptContent | Should -Match "PictureBox"
        }

        It "Should handle missing logo file gracefully" {
            # Implementation should check if file exists before loading
            $scriptContent = Get-Content "$script:AppPath/RushResolve.ps1" -Raw
            $scriptContent | Should -Match "Test-Path.*logo"
        }
    }
}

Describe "Splash Screen Animation" {
    Context "Pulse animation timer" {
        It "Should have Timer component in splash screen code" {
            $scriptContent = Get-Content "$script:AppPath/RushResolve.ps1" -Raw
            # Timer should be created for pulse effect
            $scriptContent | Should -Match "System\.Windows\.Forms\.Timer"
        }
    }
}
