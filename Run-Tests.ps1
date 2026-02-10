<#
.SYNOPSIS
    RushResolve Test Runner Script

.DESCRIPTION
    Executes Pester tests with various configurations:
    - Unit tests (fast, isolated tests)
    - Integration tests (slower, system-dependent tests)
    - All tests (complete test suite)
    - Coverage reports (code coverage analysis)

.PARAMETER Type
    The type of tests to run: Unit, Integration, All, or Coverage

.PARAMETER Output
    Output detail level: None, Normal, Detailed, Diagnostic

.PARAMETER CI
    Run in CI mode with strict failure handling

.EXAMPLE
    .\Run-Tests.ps1 -Type Unit
    Runs only unit tests with normal output

.EXAMPLE
    .\Run-Tests.ps1 -Type Coverage
    Runs all tests with code coverage analysis

.EXAMPLE
    .\Run-Tests.ps1 -Type All -Output Detailed
    Runs all tests with detailed output
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Unit', 'Integration', 'All', 'Coverage')]
    [string]$Type = 'Unit',

    [Parameter(Mandatory = $false)]
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Normal',

    [Parameter(Mandatory = $false)]
    [switch]$CI
)

# Ensure we're in the project root
$ProjectRoot = $PSScriptRoot
Set-Location $ProjectRoot

# Import Pester
Import-Module Pester -MinimumVersion 5.4.0 -ErrorAction Stop

Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RushResolve Test Runner" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "Type:       $Type" -ForegroundColor White
Write-Host "Output:     $Output" -ForegroundColor White
Write-Host "CI Mode:    $CI" -ForegroundColor White
Write-Host "Root:       $ProjectRoot" -ForegroundColor White
Write-Host "───────────────────────────────────────────────────────────" -ForegroundColor Cyan

# Configure Pester
$pesterConfig = New-PesterConfiguration

# Set output verbosity
$pesterConfig.Output.Verbosity = $Output

# Determine test paths based on type
switch ($Type) {
    'Unit' {
        $pesterConfig.Run.Path = @("$ProjectRoot/Tests/Unit")
        Write-Host "Running Unit Tests..." -ForegroundColor Green
    }
    'Integration' {
        $pesterConfig.Run.Path = @("$ProjectRoot/Tests/Integration")
        Write-Host "Running Integration Tests..." -ForegroundColor Green
    }
    'All' {
        $pesterConfig.Run.Path = @("$ProjectRoot/Tests/Unit", "$ProjectRoot/Tests/Integration")
        Write-Host "Running All Tests..." -ForegroundColor Green
    }
    'Coverage' {
        $pesterConfig.Run.Path = @("$ProjectRoot/Tests/Unit", "$ProjectRoot/Tests/Integration")

        # Enable code coverage
        $pesterConfig.CodeCoverage.Enabled = $true
        $pesterConfig.CodeCoverage.Path = @(
            "$ProjectRoot/RushResolve.ps1",
            "$ProjectRoot/Modules/*.ps1"
        )
        $pesterConfig.CodeCoverage.OutputFormat = 'JaCoCo'
        $pesterConfig.CodeCoverage.OutputPath = "$ProjectRoot/coverage.xml"

        Write-Host "Running Tests with Coverage Analysis..." -ForegroundColor Green
    }
}

# CI mode settings
if ($CI) {
    $pesterConfig.Run.Exit = $true
    $pesterConfig.TestResult.Enabled = $true
    $pesterConfig.TestResult.OutputPath = "$ProjectRoot/testResults.xml"
    $pesterConfig.TestResult.OutputFormat = 'NUnitXml'
}

# Run tests
Write-Host ""
$result = Invoke-Pester -Configuration $pesterConfig

# Display summary
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Test Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "Total:      $($result.TotalCount)" -ForegroundColor White
Write-Host "Passed:     $($result.PassedCount)" -ForegroundColor Green
Write-Host "Failed:     $($result.FailedCount)" -ForegroundColor $(if ($result.FailedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "Skipped:    $($result.SkippedCount)" -ForegroundColor Yellow
Write-Host "Duration:   $($result.Duration)" -ForegroundColor White

if ($Type -eq 'Coverage' -and $result.CodeCoverage) {
    $coverage = $result.CodeCoverage
    $coveragePercent = [math]::Round(($coverage.CommandsExecuted / $coverage.CommandsAnalyzed) * 100, 2)

    Write-Host "───────────────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  Code Coverage" -ForegroundColor Cyan
    Write-Host "───────────────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "Commands Analyzed:  $($coverage.CommandsAnalyzed)" -ForegroundColor White
    Write-Host "Commands Executed:  $($coverage.CommandsExecuted)" -ForegroundColor White
    Write-Host "Coverage:           $coveragePercent%" -ForegroundColor $(if ($coveragePercent -ge 70) { 'Green' } elseif ($coveragePercent -ge 50) { 'Yellow' } else { 'Red' })
    Write-Host "Report:             $ProjectRoot/coverage.xml" -ForegroundColor White
}

Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan

# Exit with appropriate code
if ($result.FailedCount -gt 0) {
    Write-Host "FAILED: $($result.FailedCount) test(s) failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "SUCCESS: All tests passed" -ForegroundColor Green
    exit 0
}
