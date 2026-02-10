# Module 3: Printer ListView Sortable Tests
# Verifies printer list columns are sortable and auto-sized

BeforeAll {
    # Mock environment
    $script:AppPath = $PSScriptRoot + "/../.."
}

Describe "Module 3: Printer ListView Sortable" {
    Context "ListView sorting capability" {
        It "Should set ListView Sorting property" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should set Sorting property (Ascending, Descending, or None)
            # Looking for .Sorting = [System.Windows.Forms.SortOrder]::Something
            $scriptContent | Should -Match 'Sorting\s*=\s*\[System\.Windows\.Forms\.SortOrder\]::'
        }

        It "Should have ColumnClick event handler for sorting" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have ColumnClick event that sorts by clicked column
            $scriptContent | Should -Match '\.Add_ColumnClick\('
        }

        It "Should have printer ListView defined" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have ListView for displaying printers
            $scriptContent | Should -Match 'ListView|ListViewItem'
        }
    }

    Context "Column auto-sizing" {
        It "Should auto-size columns to content" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should set column width to -1 (auto-size to content) or -2 (auto-size to header)
            # Looking for: .Width = -1 or AutoResizeColumns
            $scriptContent | Should -Match 'Width\s*=\s*-[12]|AutoResizeColumns'
        }

        It "Should have multiple columns defined" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have column definitions via Columns.Add()
            $scriptContent | Should -Match 'Columns\.Add\('
        }
    }

    Context "ListView configuration" {
        It "Should use View = Details for column display" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should set View to Details mode
            $scriptContent | Should -Match 'View\s*=\s*\[System\.Windows\.Forms\.View\]::Details'
        }

        It "Should enable FullRowSelect for better UX" {
            $modulePath = "$script:AppPath/Modules/03_PrinterManagement.ps1"
            $scriptContent = Get-Content $modulePath -Raw

            # Should have FullRowSelect enabled
            $scriptContent | Should -Match 'FullRowSelect\s*=\s*\$true'
        }
    }
}
