<#
.SYNOPSIS
    Offline pre-flight checks for RushResolve. No test framework required.
.DESCRIPTION
    Every check here corresponds to a bug that actually shipped to field
    hardware. This is deliberately not a unit-test suite - it is a tripwire for
    the specific ways this codebase has broken before.

      1  Parse            - a syntax error anywhere
      2  Symbols          - Set-AppStatus does not exist; as the last statement
                            of Initialize-Module it killed the whole Printers tab
      3  Encoding         - no-BOM + non-ASCII made PS 5.1 (which reads such a
                            file as CP1252) render the recovery message as
                            mojibake
      4  Banned syntax    - .GetNewClosure() nulls $script:, which killed every
                            button in Module 09; a top-level function in a
                            module falls out of scope, which made
                            "Refresh and Install" a silent dead end
      5  Handler scoping  - a local read inside Add_Click is $null when it fires
      6  Manifest drift   - edit a module, forget the hash, module is blocked
      7  Version          - AppVersion must match the newest CHANGELOG heading
      8  Collisions       - modules share one scope; a duplicate $script: name
                            lets the last-loaded tab hijack another's controls
      9  Repo health      - git fsck, so a gutted object store is caught the day
                            it happens rather than six months later
.EXAMPLE
    .\Tests\Invoke-SmokeTest.ps1
.NOTES
    Exit code 0 = pass, 1 = failures found.
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [switch]$SkipGit
)

$ErrorActionPreference = 'Continue'
$script:Failures = @()

# Cmdlets that legitimately do not exist until an optional Windows feature is
# present. They are guarded at their call sites; absence here is not a defect.
# LLDP needs the Data Center Bridging feature (Network Tools > Setup LLDP).
$script:ConditionalCmdlets = @(
    'Get-NetLldpAgent',
    'Enable-NetLldpAgent',
    'Get-NetLldpNeighborInformation'
)

# Script variables every module is REQUIRED to define by the module contract.
# They collide by design; the loader reads them per module before loading.
$script:ContractVariables = @('ModuleName', 'ModuleDescription')

# Closures still to be burned down. These currently work because they only read
# captured locals, but .GetNewClosure() nulls $script:, which is what made the
# LLDP label bug invisible and killed all of Module 09. Shrink this list; never
# add to it.
$script:KnownClosureDebt = @{
    '00_Welcome.ps1'          = 1
    '01_SystemInfo.ps1'       = 1
    '02_SoftwareInstaller.ps1' = 3
}

$script:Debt = @()

function Add-Debt {
    param([string]$Check, [string]$File, [int]$Line, [string]$Message)
    $script:Debt += [PSCustomObject]@{
        Check = $Check; File = $File; Line = $Line; Message = $Message
    }
}

function Remove-PSComments {
    <#
        Strips line comments and block comments so that prose ABOUT a banned
        construct is not itself reported as one. Deliberately simple: it only
        needs to be right enough for the pattern checks below.
    #>
    param([string]$Text)
    $Text = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    $out = New-Object System.Text.StringBuilder
    foreach ($line in ($Text -split "`n")) {
        $inStr = $false; $quote = [char]0; $cut = -1
        for ($i = 0; $i -lt $line.Length; $i++) {
            $c = $line[$i]
            if ($inStr) {
                if ($c -eq $quote) { $inStr = $false }
            }
            elseif ($c -eq "'" -or $c -eq '"') { $inStr = $true; $quote = $c }
            elseif ($c -eq '#') { $cut = $i; break }
        }
        if ($cut -ge 0) { $line = $line.Substring(0, $cut) }
        [void]$out.AppendLine($line)
    }
    return $out.ToString()
}

function Add-Failure {
    param([string]$Check, [string]$File, [int]$Line, [string]$Message)
    $script:Failures += [PSCustomObject]@{
        Check = $Check; File = $File; Line = $Line; Message = $Message
    }
}

function Write-Result {
    param([string]$Name, [int]$Before)
    $new = $script:Failures.Count - $Before
    if ($new -eq 0) { Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green }
    else            { Write-Host ("  [FAIL] {0} ({1})" -f $Name, $new) -ForegroundColor Red }
}

Write-Host ""
Write-Host "RushResolve smoke test" -ForegroundColor Cyan
Write-Host "Root: $Root"
Write-Host ""

$launcher  = Join-Path $Root "RushResolve.ps1"
$moduleDir = Join-Path $Root "Modules"
$modules   = @(Get-ChildItem -Path (Join-Path $moduleDir "*.ps1") -ErrorAction SilentlyContinue | Sort-Object Name)
$allFiles  = @()
if (Test-Path $launcher) { $allFiles += Get-Item $launcher }
$allFiles += $modules

if (-not (Test-Path $launcher)) { Add-Failure "Layout" "RushResolve.ps1" 0 "Launcher not found under $Root" }
if ($modules.Count -eq 0)       { Add-Failure "Layout" "Modules" 0 "No modules found under $moduleDir" }

# ---------------------------------------------------------------- 1. Parse
$before = $script:Failures.Count
foreach ($f in $allFiles) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) {
        Add-Failure "Parse" $f.Name $e.Extent.StartLineNumber $e.Message
    }
}
Write-Result ("Parse ({0} files)" -f $allFiles.Count) $before

# ------------------------------------------------------------- 2. Symbols
# Every command invoked must resolve to a core function, something defined in
# the same module, or a real cmdlet/exe on this machine.
$before = $script:Failures.Count
$coreText = if (Test-Path $launcher) { Get-Content $launcher -Raw } else { "" }
$coreFns  = @([regex]::Matches($coreText, '(?m)^function\s+([\w-]+)') | ForEach-Object { $_.Groups[1].Value })
foreach ($f in $modules) {
    $text   = Get-Content $f.FullName -Raw
    $ownFns = @([regex]::Matches($text, '(?m)^\s*function\s+([\w-]+)') | ForEach-Object { $_.Groups[1].Value })
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if ($name -like '$*') { continue }
        if ($coreFns -contains $name) { continue }
        if ($ownFns  -contains $name) { continue }
        if (Get-Command -Name $name -ErrorAction SilentlyContinue) { continue }
        if ($script:ConditionalCmdlets -contains $name) { continue }
        Add-Failure "Symbols" $f.Name $c.Extent.StartLineNumber "'$name' resolves to nothing - not a core function, not defined in this module, not a cmdlet"
    }
}
Write-Result "Symbols resolve" $before

# ------------------------------------------------------------ 3. Encoding
$before = $script:Failures.Count
foreach ($f in $allFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Add-Failure "Encoding" $f.Name 1 "Has a UTF-8 BOM. The tree is pure ASCII, no BOM - mixed encodings are what produced the mojibake."
    }
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
        $lineNo++
        foreach ($ch in $line.ToCharArray()) {
            if ([int]$ch -gt 127) {
                Add-Failure "Encoding" $f.Name $lineNo ("Non-ASCII U+{0:X4} - PS 5.1 reads a no-BOM file as CP1252 and will mangle it" -f [int]$ch)
                break
            }
        }
    }
}
Write-Result "ASCII / encoding" $before

# ------------------------------------------------------- 4. Banned syntax
$before = $script:Failures.Count
foreach ($f in $allFiles) {
    $lineNo = 0
    $hits = @()
    $clean = (Remove-PSComments -Text (Get-Content $f.FullName -Raw)) -split "`r?`n"
    foreach ($line in $clean) {
        $lineNo++
        if ($line -match '\.GetNewClosure\(\)') { $hits += $lineNo }
    }
    if ($hits.Count -eq 0) { continue }

    $allowed = 0
    if ($script:KnownClosureDebt.ContainsKey($f.Name)) { $allowed = $script:KnownClosureDebt[$f.Name] }

    if ($hits.Count -gt $allowed) {
        foreach ($h in $hits) {
            Add-Failure "Banned" $f.Name $h ".GetNewClosure() rebinds the block to a dynamic module, so every script-scoped reference inside it becomes null"
        }
        if ($allowed -gt 0) {
            Add-Failure "Banned" $f.Name 0 ("Closure count went UP: {0} found, {1} allowed. Never add closures - burn the list down." -f $hits.Count, $allowed)
        }
    }
    else {
        Add-Debt "Banned" $f.Name $hits[0] ("{0} .GetNewClosure() call(s) remaining (allowed: {1}). These read only captured locals so they work today, but they null out script scope." -f $hits.Count, $allowed)
    }
}
foreach ($f in $modules) {
    $lineNo = 0
    foreach ($line in ((Remove-PSComments -Text (Get-Content $f.FullName -Raw)) -split "`r?`n")) {
        $lineNo++
        if ($line -match '^function\s+([\w-]+)') {
            $fn = $Matches[1]
            if ($fn -ne 'Initialize-Module') {
                Add-Failure "Banned" $f.Name $lineNo "Top-level function '$fn' falls out of scope when a handler fires. Use a script-scoped block instead."
            }
        }
    }
}
Write-Result "Banned constructs" $before

# ---------------------------------------------------- 5. Handler scoping
# A variable read inside Add_*({...}) that is neither script-scoped nor assigned
# in the same handler is null once the handler actually fires.
$before = $script:Failures.Count
$ignore = @('sender','e','Matches','LASTEXITCODE','PSScriptRoot','PWD','Error','Host','env','using','_','this','args','true','false','null','PSItem','PSCmdlet')
foreach ($f in $modules) {
    $text = Remove-PSComments -Text (Get-Content $f.FullName -Raw)
    foreach ($m in [regex]::Matches($text, 'Add_\w+\(\s*\{')) {
        $start = $text.IndexOf('{', $m.Index)
        $depth = 0; $i = $start
        while ($i -lt $text.Length) {
            if ($text[$i] -eq '{') { $depth++ }
            elseif ($text[$i] -eq '}') { $depth--; if ($depth -eq 0) { break } }
            $i++
        }
        if ($i -ge $text.Length) { continue }
        $body = $text.Substring($start, $i - $start + 1)
        $line = ($text.Substring(0, $m.Index) -split "`n").Count
        $assigned = @([regex]::Matches($body, '\$(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value })
        $flagged  = @()
        foreach ($u in [regex]::Matches($body, '\$(\w+)')) {
            $v = $u.Groups[1].Value
            if ($ignore -contains $v)   { continue }
            if ($assigned -contains $v) { continue }
            if ($flagged  -contains $v) { continue }
            if ($body -match ('\$script:' + [regex]::Escape($v) + '\b')) { continue }
            # only flag names this module creates at Initialize-Module level
            if ($text -match ('(?m)^    \$' + [regex]::Escape($v) + '\s*=')) {
                $flagged += $v
                if ($script:KnownClosureDebt.ContainsKey($f.Name)) {
                    Add-Debt "Scoping" $f.Name $line "Handler reads local '$v'. Safe only because this handler is a GetNewClosure - see closure debt."
                }
                else {
                    Add-Failure "Scoping" $f.Name $line "Handler reads local '$v', which is null when the handler fires. Use a script-scoped variable."
                }
            }
        }
    }
}
Write-Result "Handler scoping" $before

# ---------------------------------------------------------- 5b. JSON config
# A single unescaped backslash in settings.json makes Load-Settings throw. It
# then falls back to defaults, and Save-Settings overwrites the file on exit -
# so one bad character silently destroys a tech's configuration. This check
# exists because exactly that shipped.
$before = $script:Failures.Count
foreach ($rel in @("Config\settings.json", "Configavorites.json",
                   "Security\module-manifest.json", "Security\integrity-manifest.json")) {
    $path = Join-Path $Root $rel
    if (-not (Test-Path $path)) { continue }
    try {
        $parsed = Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Add-Failure "Json" $rel 0 ("Does not parse: {0}" -f $_.Exception.Message)
        continue
    }
    # UNC defaults must survive the round trip as \server\share
    if ($rel -like "*settings.json") {
        $unc = $parsed.modules.SoftwareInstaller.networkPathUNCDefault
        if ($unc -and -not $unc.StartsWith("\\")) {
            Add-Failure "Json" $rel 0 ("networkPathUNCDefault is not a UNC path after parsing ('{0}') - check backslash escaping" -f $unc)
        }
    }
}
Write-Result "JSON config parses" $before

# ------------------------------------------------------- 6. Manifest drift
$before = $script:Failures.Count
$manifestPath = Join-Path $Root "Security\module-manifest.json"
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $sha = [System.Security.Cryptography.SHA256]::Create()
    foreach ($f in $modules) {
        $hash  = [Convert]::ToBase64String($sha.ComputeHash([System.IO.File]::ReadAllBytes($f.FullName)))
        $entry = $manifest.modules | Where-Object { $_.name -eq $f.Name }
        if (-not $entry) {
            Add-Failure "Manifest" $f.Name 0 "Not listed in module-manifest.json - blocked at launch in Enforced mode"
        }
        elseif ($entry.hash -ne $hash) {
            Add-Failure "Manifest" $f.Name 0 "Hash drift - regenerate via Tools > Security Options > Update Security Manifests"
        }
    }
}
else {
    Add-Failure "Manifest" "module-manifest.json" 0 "Not found under Security\"
}
Write-Result "Manifest matches modules" $before

# ------------------------------------------------------------ 7. Version
$before = $script:Failures.Count
$changelog = Join-Path $Root "CHANGELOG.md"
if ((Test-Path $launcher) -and (Test-Path $changelog)) {
    $verMatch = [regex]::Match($coreText, '(?m)^\$script:AppVersion\s*=\s*"([^"]+)"')
    $clMatch  = [regex]::Match((Get-Content $changelog -Raw), '(?m)^##\s*\[?v?([0-9]+\.[0-9]+\.[0-9]+)')
    if (-not $verMatch.Success) {
        Add-Failure "Version" "RushResolve.ps1" 0 "Could not find the AppVersion assignment"
    }
    elseif (-not $clMatch.Success) {
        Add-Failure "Version" "CHANGELOG.md" 0 "Could not find a version heading"
    }
    elseif ($verMatch.Groups[1].Value -ne $clMatch.Groups[1].Value) {
        Add-Failure "Version" "CHANGELOG.md" 0 ("AppVersion {0} does not match the newest CHANGELOG entry {1}" -f $verMatch.Groups[1].Value, $clMatch.Groups[1].Value)
    }
}
Write-Result "Version coherence" $before

# --------------------------------------------------- 8. Name collisions
$before = $script:Failures.Count
$owners = @{}
foreach ($f in $modules) {
    $names = [regex]::Matches((Get-Content $f.FullName -Raw), '(?m)^\s*\$script:(\w+)\s*=') |
             ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    foreach ($n in $names) {
        if (-not $owners.ContainsKey($n)) { $owners[$n] = @() }
        $owners[$n] += $f.Name
    }
}
foreach ($n in ($owners.Keys | Sort-Object)) {
    if ($script:ContractVariables -contains $n) { continue }
    if ($owners[$n].Count -gt 1) {
        Add-Failure "Collision" ($owners[$n] -join ', ') 0 ("Script variable '{0}' is declared by more than one module. All modules share one scope, so the last one loaded wins." -f $n)
    }
}
Write-Result "No cross-module name collisions" $before

# ------------------------------------------------------- 9. Repo health
if (-not $SkipGit) {
    $before = $script:Failures.Count
    if (Test-Path (Join-Path $Root ".git")) {
        Push-Location $Root
        $fsck = & git fsck --no-progress --connectivity-only 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-Failure "Repo" ".git" 0 ("git fsck reported problems: {0}" -f ($fsck -join '; '))
        }
        Pop-Location
    }
    else {
        Add-Failure "Repo" $Root 0 "No .git here. An unversioned working copy is how the USB build lost roughly 6.5 months of history."
    }
    Write-Result "Repository health" $before
}

# ----------------------------------------------------------------- Report
Write-Host ""
if ($script:Debt.Count -gt 0) {
    Write-Host ("Known debt ({0}) - tracked, not failing:" -f $script:Debt.Count) -ForegroundColor DarkYellow
    foreach ($d in $script:Debt) {
        Write-Host ("   {0}:{1}  {2}" -f $d.File, $d.Line, $d.Message) -ForegroundColor DarkGray
    }
    Write-Host ""
}

if ($script:Failures.Count -eq 0) {
    Write-Host "PASS - no issues found." -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Host ("FAIL - {0} issue(s):" -f $script:Failures.Count) -ForegroundColor Red
Write-Host ""
foreach ($grp in ($script:Failures | Group-Object Check)) {
    Write-Host ("{0} ({1})" -f $grp.Name, $grp.Count) -ForegroundColor Yellow
    foreach ($x in $grp.Group) {
        $loc = if ($x.Line -gt 0) { "{0}:{1}" -f $x.File, $x.Line } else { $x.File }
        Write-Host ("   {0}" -f $loc) -ForegroundColor Gray
        Write-Host ("      {0}" -f $x.Message)
    }
    Write-Host ""
}
exit 1
