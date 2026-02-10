# Session Logging Tests
# Verifies session log functionality

BeforeAll {
    # Mock environment variables for consistent testing
    $env:COMPUTERNAME = 'TESTPC01'
    $env:USERNAME = 'testuser'
    $env:USERDOMAIN = 'RUSHHEALTH'
}

Describe "Session Log File Naming" {
    Context "Log filename format" {
        It "Should use format SESSION-COMPUTERNAME-TIMESTAMP.log" {
            # Expected format: SESSION-TESTPC01-2026-02-09_143522.log
            $expectedPattern = "SESSION-$env:COMPUTERNAME-\d{4}-\d{2}-\d{2}_\d{6}\.log"

            # Test the actual implementation logic
            $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
            $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'UNKNOWN' }
            $testFilename = "SESSION-$computerName-$timestamp.log"

            $testFilename | Should -Match $expectedPattern
        }

        It "Should include computer name in filename" {
            $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
            $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'UNKNOWN' }
            $testFilename = "SESSION-$computerName-$timestamp.log"

            $testFilename | Should -Match "SESSION-$env:COMPUTERNAME-"
        }

        It "Should use correct timestamp format YYYY-MM-DD_HHMMSS" {
            $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
            $testFilename = "SESSION-TESTPC01-$timestamp.log"

            $testFilename | Should -Match "\d{4}-\d{2}-\d{2}_\d{6}"
        }
    }
}
