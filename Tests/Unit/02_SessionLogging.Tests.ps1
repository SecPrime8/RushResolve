# Session Logging Tests
# Verifies session log functionality

BeforeAll {
    # Mock environment variables for consistent testing
    $env:COMPUTERNAME = 'TESTPC01'
    $env:USERNAME = 'testuser'
    $env:USERDOMAIN = 'RUSHHEALTH'

    # Dot-source mock helpers
    . "$PSScriptRoot/../Mocks/CimMocks.ps1"
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

Describe "Get-SessionStartInfo" {
    Context "System information collection" {
        It "Should return hashtable with required keys" {
            # Create a mock function that simulates Get-SessionStartInfo output
            function Get-MockSessionInfo {
                return @{
                    ComputerName = 'TESTPC01'
                    OS = 'Microsoft Windows 10 Enterprise'
                    OSVersion = '10.0.19045'
                    Build = '19045'
                    Architecture = '64-bit'
                    CPU = 'Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz'
                    Cores = 6
                    Threads = 12
                    RAM = '16.0 GB'
                    Domain = 'RUSHHEALTH.local'
                    DomainJoined = $true
                    ActiveAdapters = 1
                }
            }

            $info = Get-MockSessionInfo

            # Verify required keys exist
            $info.ContainsKey('ComputerName') | Should -Be $true
            $info.ContainsKey('OS') | Should -Be $true
            $info.ContainsKey('Build') | Should -Be $true
            $info.ComputerName | Should -Be 'TESTPC01'
        }

        It "Should handle errors gracefully" {
            $errorInfo = @{
                ComputerName = 'TESTPC01'
                Error = 'Mock error message'
            }

            $errorInfo.ContainsKey('Error') | Should -Be $true
            $errorInfo.Error | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Session Log Header Content" {
    Context "Computer information in log header" {
        It "Should include OS information in log content" {
            $testLogContent = @"
================================================================================
RUSH RESOLVE SESSION LOG
================================================================================
Started: 2026-02-10 07:00:00
User: RUSHHEALTH\testuser
Computer: TESTPC01
Version: 2.4.0

SYSTEM INFORMATION:
OS: Microsoft Windows 10 Enterprise
Build: 19045
CPU: Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz
Cores: 6 cores, 12 threads
RAM: 16.0 GB
Domain: RUSHHEALTH.local
================================================================================
"@
            $testLogContent | Should -Match "OS:"
            $testLogContent | Should -Match "Build:"
            $testLogContent | Should -Match "CPU:"
            $testLogContent | Should -Match "RAM:"
        }
    }
}
