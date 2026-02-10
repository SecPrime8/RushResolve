# Module 3: Printer Backup/Restore Tests
# Verifies backup and restore functionality for printer configurations

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 3: Printer Backup/Restore" {
    Context "Backup functionality" {
        It "Should have backup button defined" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have backup button
            $scriptContent | Should -Match '\$\w*[Bb]ackupBtn|\$\w*[Bb]ackup.*Button'
        }

        It "Should have backup function or script block" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have function or logic to backup printers
            # Looking for Get-Printer, Export-Clixml, ConvertTo-Json, etc.
            $scriptContent | Should -Match 'Export-Clixml|ConvertTo-Json|Export.*Printer'
        }

        It "Should backup to file with SaveFileDialog or fixed location" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should use SaveFileDialog or specify backup path
            $scriptContent | Should -Match 'SaveFileDialog|backup.*path|export.*path'
        }
    }

    Context "Restore functionality" {
        It "Should have restore button defined" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have restore button
            $scriptContent | Should -Match '\$\w*[Rr]estoreBtn|\$\w*[Rr]estore.*Button'
        }

        It "Should have restore function or script block" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have function or logic to restore printers
            # Looking for Import-Clixml, ConvertFrom-Json, Add-Printer, etc.
            $scriptContent | Should -Match 'Import-Clixml|ConvertFrom-Json|Add-Printer|Import.*Printer'
        }

        It "Should restore from file with OpenFileDialog or fixed location" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should use OpenFileDialog or specify restore path
            $scriptContent | Should -Match 'OpenFileDialog|restore.*path|import.*path'
        }
    }

    Context "Printer configuration data" {
        It "Should capture printer properties for backup" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should get printer details (name, port, driver, etc.)
            $scriptContent | Should -Match 'Get-Printer|Win32_Printer'
        }

        It "Should handle printer ports in backup" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should include port information (IP, path, etc.)
            $scriptContent | Should -Match 'PortName|printer.*port|Get-PrinterPort'
        }
    }
}
