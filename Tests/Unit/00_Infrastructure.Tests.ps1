# Infrastructure Verification Tests
# These tests ensure the test framework itself is properly set up

Describe "Pester Installation" {
    It "Should have Pester 5.4.0 or higher" {
        $pester = Get-Module -Name Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        $pester.Version.Major | Should -BeGreaterOrEqual 5
        $pester.Version.Minor | Should -BeGreaterOrEqual 4
    }
}

Describe "Test Directory Structure" {
    It "Should have Tests/Unit folder" {
        Test-Path "$PSScriptRoot/../Unit" | Should -Be $true
    }

    It "Should have Tests/Integration folder" {
        Test-Path "$PSScriptRoot/../Integration" | Should -Be $true
    }

    It "Should have Tests/Mocks folder" {
        Test-Path "$PSScriptRoot/../Mocks" | Should -Be $true
    }
}
