# Mock Helper Function Tests
# Verifies that mock generators work correctly

BeforeAll {
    # Dot-source mock helpers
    . "$PSScriptRoot/../Mocks/CimMocks.ps1"
}

Describe "Mock Helper Functions" {
    Context "New-MockCimInstance" {
        It "Should create mock Win32_ComputerSystem" {
            $mock = New-MockCimInstance -ClassName 'Win32_ComputerSystem'
            $mock.Name | Should -Not -BeNullOrEmpty
            $mock.Manufacturer | Should -Not -BeNullOrEmpty
            $mock.TotalPhysicalMemory | Should -BeGreaterThan 0
        }

        It "Should create mock Win32_Processor" {
            $mock = New-MockCimInstance -ClassName 'Win32_Processor'
            $mock.Name | Should -Not -BeNullOrEmpty
            $mock.NumberOfCores | Should -BeGreaterThan 0
        }

        It "Should allow custom properties" {
            $mock = New-MockCimInstance -ClassName 'Win32_ComputerSystem' -Properties @{
                Name = 'CustomPC'
                Manufacturer = 'CustomManufacturer'
            }
            $mock.Name | Should -Be 'CustomPC'
            $mock.Manufacturer | Should -Be 'CustomManufacturer'
        }

        It "Should handle unknown class names gracefully" {
            $mock = New-MockCimInstance -ClassName 'UnknownClass' -Properties @{
                CustomProp = 'TestValue'
            } -WarningAction SilentlyContinue
            $mock.CustomProp | Should -Be 'TestValue'
        }
    }

    Context "New-MockNetAdapter" {
        It "Should create mock network adapter" {
            $mock = New-MockNetAdapter
            $mock.Name | Should -Be 'Ethernet'
            $mock.Status | Should -Be 'Up'
            $mock.MacAddress | Should -Not -BeNullOrEmpty
        }

        It "Should allow custom adapter name" {
            $mock = New-MockNetAdapter -Name 'WiFi'
            $mock.Name | Should -Be 'WiFi'
        }

        It "Should allow custom properties" {
            $mock = New-MockNetAdapter -Properties @{ Status = 'Down' }
            $mock.Status | Should -Be 'Down'
        }
    }

    Context "New-MockDiskInfo" {
        It "Should create mock disk info" {
            $mock = New-MockDiskInfo
            $mock.DeviceID | Should -Be 'C:'
            $mock.FileSystem | Should -Be 'NTFS'
            $mock.Size | Should -BeGreaterThan 0
        }

        It "Should allow custom drive letter" {
            $mock = New-MockDiskInfo -DriveLetter 'D:'
            $mock.DeviceID | Should -Be 'D:'
        }
    }

    Context "New-MockPrinter" {
        It "Should create mock printer" {
            $mock = New-MockPrinter
            $mock.Name | Should -Not -BeNullOrEmpty
            $mock.DriverName | Should -Not -BeNullOrEmpty
            $mock.PortName | Should -Not -BeNullOrEmpty
        }

        It "Should allow custom printer name" {
            $mock = New-MockPrinter -Name 'TestPrinter'
            $mock.Name | Should -Be 'TestPrinter'
        }
    }
}
