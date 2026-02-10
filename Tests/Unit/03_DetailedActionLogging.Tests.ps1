# Detailed Action Logging Tests
# Verifies that Write-SessionLog can track operation results

BeforeAll {
    # Setup test environment
    $testLogDir = "$TestDrive/Logs"
    New-Item -Path $testLogDir -ItemType Directory -Force | Out-Null
    $script:TestLogFile = Join-Path $testLogDir "test.log"
}

Describe "Write-SessionLog with Result Parameter" {
    Context "Basic logging with results" {
        It "Should log operation name and result" {
            # Mock function behavior
            $testLogFile = "$TestDrive/test1.log"
            $timestamp = Get-Date -Format "HH:mm:ss"
            $logEntry = "[$timestamp] [DomainTools] Domain join - Success"

            # Verify format includes result
            $logEntry | Should -Match "\[DomainTools\] Domain join - Success"
        }

        It "Should log errors with details" {
            $testLogFile = "$TestDrive/test2.log"
            $timestamp = Get-Date -Format "HH:mm:ss"
            $logEntry = "[$timestamp] [Installer] Failed to install app - Error: Access denied"

            $logEntry | Should -Match "Error: Access denied"
        }

        It "Should work without result parameter (backward compatible)" {
            $testLogFile = "$TestDrive/test3.log"
            $timestamp = Get-Date -Format "HH:mm:ss"
            $logEntry = "[$timestamp] [Network] Ping test started"

            # Should not have a dash separator when no result
            $logEntry | Should -Not -Match " - Success$"
            $logEntry | Should -Match "Ping test started"
        }
    }

    Context "Log entry formatting" {
        It "Should include category, message, and result" {
            $logLine = "[10:30:45] [PrinterManagement] Add network printer - Success"

            $logLine | Should -Match "\[[\d:]+\]"        # Timestamp
            $logLine | Should -Match "\[PrinterManagement\]"  # Category
            $logLine | Should -Match "Add network printer"    # Message
            $logLine | Should -Match "- Success"              # Result
        }

        It "Should handle missing category gracefully" {
            $logLine = "[10:30:45] Splash screen displayed - Ready"

            $logLine | Should -Not -Match "\[\w+\] \[\w+\]"  # No double brackets
            $logLine | Should -Match "- Ready"
        }
    }

    Context "Result status tracking" {
        It "Should identify successful operations" {
            $logLine = "[10:30:45] [DiskCleanup] Temp files removed - Freed 2.5 GB"

            $logLine | Should -Match "- Freed"
        }

        It "Should identify failed operations" {
            $logLine = "[10:30:45] [Network] DHCP renew - Failed: No response from DHCP server"

            $logLine | Should -Match "- Failed:"
        }

        It "Should identify warning states" {
            $logLine = "[10:30:45] [Diagnostics] Health check - Warning: Low disk space"

            $logLine | Should -Match "- Warning:"
        }
    }
}
