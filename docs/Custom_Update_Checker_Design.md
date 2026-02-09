# Custom Update Checker - "Live Off The Land" Design

**Goal:** Build software update detection using ONLY built-in Windows tools (no WinGet, no Chocolatey).

---

## Architecture

### Phase 1: Detection
1. **Scan installed software** - Registry (Uninstall keys)
2. **Get current versions** - File version info or registry
3. **Query latest versions** - Vendor APIs/websites
4. **Compare** - Show outdated apps

### Phase 2: Updates (Future)
5. **Download** - Invoke-WebRequest (built-in)
6. **Install** - Start-Process with silent flags

---

## Technical Approach

### 1. Scan Installed Software

**Registry locations:**
```powershell
$paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$installed = foreach ($path in $paths) {
    Get-ItemProperty $path -ErrorAction SilentlyContinue
}

# Filter to useful apps
$apps = $installed | Where-Object {
    $_.DisplayName -and
    $_.DisplayVersion -and
    $_.DisplayName -notlike "KB*"  # Skip Windows updates
} | Select-Object DisplayName, DisplayVersion, InstallLocation, UninstallString
```

**Output example:**
- Adobe Acrobat Reader DC - 23.006.20360
- Google Chrome - 120.0.6099.109
- Microsoft Edge - 120.0.2210.121
- 7-Zip - 23.01

---

### 2. Version Comparison System

**Common apps we can check:**

| App | How to Get Latest Version | API Available? |
|-----|---------------------------|----------------|
| **Google Chrome** | File API or scrape download page | Yes - JSON |
| **Adobe Acrobat Reader** | FTP server version file | Yes - TXT file |
| **7-Zip** | SourceForge API | Yes - JSON |
| **VLC** | Website scrape | Partial |
| **Firefox** | Mozilla API | Yes - JSON |
| **Notepad++** | GitHub API | Yes - JSON |
| **VS Code** | Microsoft API | Yes - JSON |

---

### 3. Example: Chrome Version Check

**Chrome has a JSON API:**
```powershell
# Get installed Chrome version
$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (Test-Path $chromePath) {
    $currentVersion = (Get-Item $chromePath).VersionInfo.FileVersion

    # Query latest version from Google API
    $url = "https://omahaproxy.appspot.com/all.json?os=win&channel=stable"
    $response = Invoke-RestMethod -Uri $url
    $latestVersion = $response.versions[0].current_version

    if ($currentVersion -ne $latestVersion) {
        Write-Host "Chrome outdated: $currentVersion → $latestVersion"
    }
}
```

**This works with NO external tools!**

---

### 4. Example: Adobe Acrobat Version Check

**Adobe publishes version info on FTP:**
```powershell
# Get installed Acrobat version from registry
$adobeReg = Get-ItemProperty "HKLM:\SOFTWARE\Adobe\Acrobat Reader\*\Installer" -ErrorAction SilentlyContinue
$currentVersion = $adobeReg.PSChildName  # e.g., "DC", "2023"

# Query latest version
$url = "https://armmf.adobe.com/arm-manifests/mac/AcrobatDC/reader/current_version.txt"
try {
    $latestVersion = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content.Trim()
    Write-Host "Acrobat current: $currentVersion, latest: $latestVersion"
}
catch {
    Write-Host "Could not check Adobe version"
}
```

---

### 5. Scalable Pattern

**Create a "version checker" library:**

```powershell
$versionCheckers = @{
    "Google Chrome" = {
        $exePath = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
        if (-not (Test-Path $exePath)) {
            $exePath = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        }
        if (Test-Path $exePath) {
            $current = (Get-Item $exePath).VersionInfo.FileVersion

            $url = "https://omahaproxy.appspot.com/all.json?os=win&channel=stable"
            $latest = (Invoke-RestMethod $url | Where-Object {$_.os -eq 'win'})[0].versions[0].current_version

            return @{
                Installed = $current
                Latest = $latest
                Outdated = $current -ne $latest
            }
        }
    }

    "Mozilla Firefox" = {
        $exePath = "${env:ProgramFiles}\Mozilla Firefox\firefox.exe"
        if (Test-Path $exePath) {
            $current = (Get-Item $exePath).VersionInfo.FileVersion

            $url = "https://product-details.mozilla.org/1.0/firefox_versions.json"
            $latest = (Invoke-RestMethod $url).LATEST_FIREFOX_VERSION

            return @{
                Installed = $current
                Latest = $latest
                Outdated = $current -ne $latest
            }
        }
    }

    "7-Zip" = {
        $exePath = "${env:ProgramFiles}\7-Zip\7z.exe"
        if (Test-Path $exePath) {
            $current = (Get-Item $exePath).VersionInfo.FileVersion

            # 7-Zip posts releases on SourceForge RSS
            $url = "https://sourceforge.net/projects/sevenzip/rss"
            $rss = [xml](Invoke-WebRequest $url -UseBasicParsing).Content
            $latestTitle = $rss.rss.channel.item[0].title
            if ($latestTitle -match "(\d+\.\d+)") {
                $latest = $matches[1]
            }

            return @{
                Installed = $current
                Latest = $latest
                Outdated = $current -ne $latest
            }
        }
    }
}

# Run checkers
foreach ($app in $versionCheckers.Keys) {
    try {
        $result = & $versionCheckers[$app]
        if ($result -and $result.Outdated) {
            Write-Host "$app is outdated: $($result.Installed) → $($result.Latest)"
        }
    }
    catch {
        Write-Host "Could not check $app"
    }
}
```

---

## Pros vs WinGet

### **Our Custom Checker:**
✅ No external dependencies (live off the land)
✅ No installation required
✅ Works even if Microsoft Store blocked
✅ Can customize for RUSH-specific apps
✅ Lightweight and fast
✅ Full control over what we check

### **WinGet:**
✅ Checks 1000+ apps automatically
✅ Maintained by Microsoft
✅ Can install updates automatically
❌ Requires installation
❌ May be blocked by Group Policy
❌ Dependency on external tool

---

## Implementation Plan

### **Module 02 Update Tab - Custom Version:**

1. **Hardcode 10-15 common apps** that RUSH techs care about:
   - Google Chrome
   - Mozilla Firefox
   - Adobe Acrobat Reader
   - 7-Zip
   - VLC Media Player
   - Notepad++
   - Microsoft Teams (if not managed by IT)
   - Zoom (if allowed)
   - VS Code
   - Git

2. **For each app:**
   - Check if installed (registry + file path)
   - Get current version (file version info)
   - Query vendor API for latest version
   - Show in ListView with status (Up-to-date / Outdated)

3. **UI:**
   ```
   [Check for Updates] button

   ListView:
   ┌─────────────────────────────────────────────────────────┐
   │ Application         | Current   | Latest    | Status    │
   ├─────────────────────────────────────────────────────────┤
   │ Google Chrome       | 120.0.1   | 121.0.5   | Outdated  │
   │ Adobe Acrobat       | 23.006    | 24.001    | Outdated  │
   │ 7-Zip               | 23.01     | 23.01     | Current   │
   │ Firefox             | Not installed         |           │
   └─────────────────────────────────────────────────────────┘

   [Download Link] button (opens vendor download page)
   ```

4. **Future:** Add auto-download + silent install capability

---

## Version API Resources

### **Confirmed Working APIs (as of 2026):**

**Chrome:**
```
https://omahaproxy.appspot.com/all.json?os=win&channel=stable
```

**Firefox:**
```
https://product-details.mozilla.org/1.0/firefox_versions.json
```

**VS Code:**
```
https://code.visualstudio.com/sha?build=stable
```

**Notepad++:**
```
https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest
```

**Git for Windows:**
```
https://api.github.com/repos/git-for-windows/git/releases/latest
```

---

## Decision

**Recommendation:**
Build custom version checker with 10-15 common apps. Completely "live off the land" - no WinGet dependency.

**Effort:** ~4-6 hours development
**Benefit:** Works in locked-down RUSH environment
**Limitation:** Only checks apps we explicitly code for (vs WinGet's 1000+)

**Trade-off is worth it** to maintain zero-dependency principle.
