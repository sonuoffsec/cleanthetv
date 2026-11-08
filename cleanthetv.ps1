<#
.SYNOPSIS
  CleanTheTV: clean up an Android TV or Google TV over Wi-Fi, from one command.

.DESCRIPTION
  find     Look for Android TVs on this network that accept ADB (port 5555).
  setup    Find the TV, pick the tested debloat list for its model, disable the listed apps (never uninstall),
           install the CleanTheTV launcher and push a theme.
  theme    Push (or switch to) another theme.
  restore  Undo everything: re-enable the disabled apps and bring back the stock launcher.
  report   Free RAM, running processes and disabled apps now, compared with the reading `setup` took before it changed anything.
  privacy  Block ad and tracker domains system-wide with private DNS (no root). `-Dns off` puts the old setting back.
  scan     For a TV with no tested list: write a draft debloat list from the system apps' names, for you to review.

  Nothing is uninstalled. Every step can be undone with `cleanthetv.ps1 restore`.

.EXAMPLE
  .\cleanthetv.ps1 find
  .\cleanthetv.ps1 setup -DryRun            # show what would happen, change nothing
  .\cleanthetv.ps1 setup -Theme terminal-dark
  .\cleanthetv.ps1 theme -Theme aurora-glass
  .\cleanthetv.ps1 report
  .\cleanthetv.ps1 privacy -Dns adguard
  .\cleanthetv.ps1 scan
  .\cleanthetv.ps1 setup -ListFile .\debloat-MyTV.draft.txt -DryRun
  .\cleanthetv.ps1 restore
#>
param(
    [Parameter(Position = 0)][ValidateSet('find', 'setup', 'theme', 'restore', 'report', 'privacy', 'scan')][string]$Command = 'setup',
    [string]$TvHost = $env:TV_HOST,
    [string]$Theme = 'terminal-dark',
    [string]$Apk,
    [string]$ListFile,
    [string]$Dns = 'adguard',
    [string]$Out,
    [switch]$DryRun,
    [switch]$IncludePersonalChoices,
    [string[]]$Keep = @()
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$tools = Join-Path $env:USERPROFILE 'cleanthetv-tools'

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" }
function Warn($m) { Write-Host "    ! $m" -ForegroundColor Yellow }

# ---- adb (Google's official platform-tools), downloaded once into your user profile ----
function Get-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $tools 'platform-tools\adb.exe'
    if (Test-Path $local) { return $local }
    if ($DryRun) { Warn ('adb is not installed; a real run downloads Google platform-tools into ' + $tools); return $null }
    Step 'Downloading Google platform-tools (adb)'
    New-Item -ItemType Directory -Force $tools | Out-Null
    $zip = Join-Path $tools 'platform-tools.zip'
    curl.exe -L --fail -o $zip 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
    if ($LASTEXITCODE -ne 0) { throw 'download failed; install platform-tools yourself and put adb on PATH' }
    Expand-Archive $zip -DestinationPath $tools -Force
    Remove-Item $zip -Force
    return $local
}

# ---- find TVs: every address on this /24 that answers on the ADB port ----
function Find-Tvs {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { throw 'no network connection found' }
    $mine = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.ifIndex | Select-Object -First 1).IPAddress
    $prefix = ($mine -split '\.')[0..2] -join '.'
    Info "Scanning $prefix.0/24 for devices with ADB on (port 5555)..."
    $probes = 1..254 | ForEach-Object {
        $c = New-Object Net.Sockets.TcpClient
        [pscustomobject]@{ Ip = "$prefix.$_"; Client = $c; Ar = $c.BeginConnect("$prefix.$_", 5555, $null, $null) }
    }
    Start-Sleep -Milliseconds 1800
    $hits = @($probes | Where-Object { $_.Ar.IsCompleted -and $_.Client.Connected } | ForEach-Object { $_.Ip })
    $probes | ForEach-Object { try { $_.Client.Close() } catch {} }
    return $hits | Where-Object { $_ -ne $mine }
}

function Resolve-Tv {
    if ($TvHost) { return $TvHost }
    $hits = @(Find-Tvs)
    if ($hits.Count -eq 0) {
        throw 'No TV found. On the TV: Settings > Device Preferences > About, press OK on Build seven times, then Developer options > USB debugging (and Network debugging) on. Keep the TV on and on this Wi-Fi.'
    }
    if ($hits.Count -gt 1) { throw "More than one device answered: $($hits -join ', '). Run again with -TvHost <ip>." }
    return $hits[0]
}

function Connect-Tv($adb, $ip) {
    & $adb connect "${ip}:5555" | Out-Null
    $state = ''
    for ($i = 0; $i -lt 10; $i++) {
        $state = (& $adb -s "${ip}:5555" get-state 2>&1 | Out-String).Trim()
        if ($state -eq 'device') { return }
        Start-Sleep 1
    }
    throw "TV found at $ip but not authorised ($state). Look at the TV screen: accept 'Allow USB debugging?' (tick Always allow), then run this again."
}

function Get-TvInfo($adb, $ip) {
    $p = { param($k) (& $adb -s "${ip}:5555" shell getprop $k | Out-String).Trim() }
    [pscustomobject]@{
        Maker   = & $p 'ro.product.manufacturer'
        Model   = & $p 'ro.product.model'
        Android = & $p 'ro.build.version.release'
    }
}

# ---- pick the tested debloat list for this model from examples/*/tv.json ----
function Find-List($info) {
    foreach ($d in Get-ChildItem (Join-Path $root 'examples') -Directory) {
        $json = Join-Path $d.FullName 'tv.json'
        $list = Join-Path $d.FullName 'debloat.txt'
        if (-not (Test-Path $json) -or -not (Test-Path $list)) { continue }
        $tv = (Get-Content $json -Raw | ConvertFrom-Json).tv
        if ($tv -and $info.Model -and $tv -match [regex]::Escape($info.Model)) { return $list }
    }
    return $null
}

# Upstream lists carry sections headed "# Personal choice" (voice assistant, casting, unused apps) that the
# contributor turned off for themselves. They are skipped unless -IncludePersonalChoices, so casting and voice keep working.
function Get-FilteredList($list) {
    $out = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in Get-Content $list) {
        if ($line -match '^\s*$') { $skip = $false; $out.Add($line); continue }
        if ($line -match '^\s*#') { if ($line -match '^\s*#\s*Personal choice') { $skip = $true }; $out.Add($line); continue }
        $pkg = ($line -replace '#.*$', '').Trim()
        # Kept unless -IncludePersonalChoices: a section marked "Personal choice", and anything about firmware updates.
        $byChoice = (-not $IncludePersonalChoices) -and ($skip -or $line -match '#.*firmware update')
        if ($byChoice -or ($Keep -contains $pkg)) { $skipped.Add($pkg); $out.Add('# skipped by cleanthetv.ps1: ' + $line.Trim()); continue }
        $out.Add($line)
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cleanthetv-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    Set-Content $tmp $out -Encoding UTF8
    return [pscustomobject]@{ Path = $tmp; Skipped = $skipped }
}

function Ensure-Venv {
    $py = Join-Path $root 'tools\venv\Scripts\python.exe'
    if (Test-Path $py) { return }
    Step 'Setting up the Python helper (one time)'
    python -m venv (Join-Path $root 'tools\venv')
    & $py -m pip install -q -r (Join-Path $root 'tools\requirements.txt')
}

# ---- talking to the TV over the connected adb session ----
function Adb-Shell($cmd) { (& $adb -s "${ip}:5555" shell $cmd | Out-String).Trim() }
function Lines($text) { @($text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# ---- report: a reading of the TV's memory, storage, processes and disabled apps ----
function Get-Snapshot {
    $mem = Adb-Shell 'cat /proc/meminfo'
    $cols = (Lines (Adb-Shell 'df /data') | Select-Object -Last 1) -split '\s+'
    [pscustomobject]@{
        When          = (Get-Date).ToString('s')
        Tv            = "$($info.Maker) $($info.Model)"
        MemTotalMb    = [int]([int64][regex]::Match($mem, 'MemTotal:\s+(\d+)').Groups[1].Value / 1024)
        MemFreeMb     = [int]([int64][regex]::Match($mem, 'MemAvailable:\s+(\d+)').Groups[1].Value / 1024)
        StorageFreeMb = $(if ($cols.Count -ge 4) { [int]([int64]$cols[3] / 1024) } else { 0 })
        Processes     = (Lines (Adb-Shell 'ps -A')).Count - 1
        Packages      = @(Lines (Adb-Shell 'pm list packages') | Where-Object { $_ -like 'package:*' }).Count
        Disabled      = @(Lines (Adb-Shell 'pm list packages -d') | Where-Object { $_ -like 'package:*' }).Count
    }
}

function Save-Snapshot($label) {
    $dir = Join-Path $tools 'reports'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $s = Get-Snapshot
    $s | ConvertTo-Json | Set-Content (Join-Path $dir ("snapshot-$label-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')) -Encoding UTF8
    return $s
}

function Get-Baseline {
    $dir = Join-Path $tools 'reports'
    if (-not (Test-Path $dir)) { return $null }
    Get-ChildItem $dir -Filter 'snapshot-before-*.json' | Sort-Object LastWriteTime -Descending |
        ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
        Where-Object { $_.Tv -eq "$($info.Maker) $($info.Model)" } | Select-Object -First 1
}

function Show-Report($now, $base) {
    $row = { param($name, $b, $n, $higherIsBetter)
        $delta = if ($null -ne $b) { $n - $b } else { $null }
        $d = if ($null -ne $delta) { ('{0:+#;-#;0}' -f $delta) } else { '' }
        '    {0,-24}{1,10}{2,10}{3,10}' -f $name, $(if ($null -ne $b) { $b } else { '-' }), $n, $d }
    Info ('{0,-24}{1,10}{2,10}{3,10}' -f '', 'Before', 'Now', 'Change')
    Info (& $row 'Free RAM (MB)' $base.MemFreeMb $now.MemFreeMb $true).Trim()
    Info (& $row 'Running processes' $base.Processes $now.Processes $false).Trim()
    Info (& $row 'Disabled apps' $base.Disabled $now.Disabled $true).Trim()
    Info (& $row 'Free storage (MB)' $base.StorageFreeMb $now.StorageFreeMb $true).Trim()
    Info "Total RAM: $($now.MemTotalMb) MB, installed packages: $($now.Packages)"
}

# ---- privacy: system-wide ad and tracker blocking through Android's private DNS ----
# 'null' means the setting was unset, so it is deleted rather than written.
function Restore-DnsSetting($key, $value) {
    if (-not $value -or $value -eq 'null') { Adb-Shell "settings delete global $key" | Out-Null }
    else { Adb-Shell "settings put global $key $value" | Out-Null }
}

function Invoke-Privacy {
    $presets = @{ 'adguard' = 'dns.adguard-dns.com'; 'quad9' = 'dns.quad9.net'; 'cloudflare' = 'one.one.one.one' }
    $saved = Join-Path $tools 'privacy-previous.json'
    if ($Dns -eq 'off') {
        $mode = 'null'; $spec = 'null'
        if (Test-Path $saved) {
            $prev = Get-Content $saved -Raw | ConvertFrom-Json
            if ($prev.Mode) { $mode = $prev.Mode }
            if ($prev.Specifier) { $spec = $prev.Specifier }
        }
        Step "Putting private DNS back ($(if ($mode -eq 'null') { 'to the TV default' } else { $mode }))"
        if ($DryRun) { Warn 'Dry run: nothing was changed.'; return }
        Restore-DnsSetting 'private_dns_mode' $mode
        Restore-DnsSetting 'private_dns_specifier' $spec
        Remove-Item $saved -Force -ErrorAction SilentlyContinue
        Info 'Done. The TV uses the network DNS again.'
        return
    }
    $dnsHost = if ($presets.ContainsKey($Dns)) { $presets[$Dns] } else { $Dns }
    if ($dnsHost -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' -or $dnsHost -notmatch '\.') {
        throw "'$Dns' is not a preset (adguard, quad9, cloudflare, off) or a DNS hostname."
    }
    Step "Private DNS: $dnsHost"
    $mode0 = Adb-Shell 'settings get global private_dns_mode'
    $spec0 = Adb-Shell 'settings get global private_dns_specifier'
    Info "Current setting: mode=$mode0 specifier=$spec0"
    Info 'Every DNS lookup the TV makes will go to that provider, which can see the site names (not the pages). Undo: .\cleanthetv.ps1 privacy -Dns off'
    if ($DryRun) { Warn "Dry run: would set private DNS to $dnsHost and test it."; return }
    if (-not (Test-Path $saved)) {
        New-Item -ItemType Directory -Force $tools | Out-Null
        [pscustomobject]@{ Mode = $mode0; Specifier = $spec0 } | ConvertTo-Json | Set-Content $saved -Encoding UTF8
    }
    Adb-Shell 'settings put global private_dns_mode hostname' | Out-Null
    Adb-Shell "settings put global private_dns_specifier $dnsHost" | Out-Null
    Start-Sleep 4
    $works = (Adb-Shell 'ping -c 1 -W 4 example.com') -match '\b1 (packets )?received'
    if (-not $works) {
        Warn 'The TV could not resolve names through that server (some networks block it). Putting the old setting back.'
        Restore-DnsSetting 'private_dns_mode' $mode0
        Restore-DnsSetting 'private_dns_specifier' $spec0
        Remove-Item $saved -Force -ErrorAction SilentlyContinue
        throw 'Private DNS was not kept. Nothing else changed.'
    }
    $ad = Adb-Shell 'ping -c 1 -W 3 doubleclick.net'
    # A blocked name resolves to a dead address (0.0.0.0 or 127.0.0.1, depending on the provider) or to nothing.
    $blocked = ($ad -match '\((0\.0\.0\.0|127\.0\.0\.1)\)') -or ($ad -match 'unknown host') -or ($ad -match 'Name or service not known')
    Info "Names resolve through $dnsHost."
    if ($Dns -eq 'adguard') { Info ("Ad-domain test (doubleclick.net): " + $(if ($blocked) { 'blocked' } else { 'not blocked, so the list may not cover it on this network' })) }
    Info 'This blocks ad and tracker domains, not ads served from the same domain as the video (such as YouTube).'
}

# ---- scan: a draft debloat list for a TV that has no tested one ----
function Invoke-Scan {
    $protected = '^(android|com\.android\..*|com\.gathin\.tvhome|com\.google\.android\.(gms|gsf|webview|packageinstaller|inputmethod\..*|tvlauncher|tts|syncadapters\..*|ext\..*|backuptransport|marvin\..*|partnersetup|apps\.mediashell|youtube\..*|katniss|speech\..*|tungsten\..*|leanbacklauncher|sss\..*))$'
    $rules = @(
        @{ Re = 'analytics|statistic|telemetry|metrics|crash|bugreport|feedback'; Why = 'analytics or telemetry' },
        @{ Re = '(^|\.)ads?(\.|$)|adservice|advert|adsdk'; Why = 'advertising' },
        @{ Re = 'sponsor|promo|recommend|glance|webcontent|newsfeed|contentfeed|discover'; Why = 'sponsored or recommended content' },
        @{ Re = 'autoinstall|partnercustomizer|preload'; Why = 'silent partner app installs' }
    )
    Step 'Scanning the system apps'
    $disabled = @(Lines (Adb-Shell 'pm list packages -d') | ForEach-Object { $_ -replace '^package:', '' })
    $found = foreach ($pkg in (Lines (Adb-Shell 'pm list packages -s') | ForEach-Object { $_ -replace '^package:', '' } | Sort-Object)) {
        if ($pkg -match $protected) { continue }
        foreach ($r in $rules) { if ($pkg -match $r.Re) { [pscustomobject]@{ Package = $pkg; Why = $r.Why; Disabled = ($disabled -contains $pkg) }; break } }
    }
    $found = @($found)
    if (-not $found.Count) { Warn 'No system app looked like ads or telemetry by name.'; return }
    $found | ForEach-Object { Info ('{0,-58} {1}{2}' -f $_.Package, $_.Why, $(if ($_.Disabled) { '  (already disabled)' } else { '' })) }
    $safeModel = ($info.Model -replace '[^A-Za-z0-9_-]', '-')
    $path = if ($Out) { $Out } else { Join-Path (Get-Location) "debloat-$safeModel.draft.txt" }
    $header = @(
        "# DRAFT debloat list for $($info.Maker) $($info.Model), Android $($info.Android), written by cleanthetv.ps1 scan on $((Get-Date).ToString('yyyy-MM-dd')).",
        '# These are guesses from package names, NOT a tested list. Read every line and delete what you want to keep.',
        '# Everything is disabled, not uninstalled; .\cleanthetv.ps1 restore -ListFile <this file> undoes it.',
        ''
    )
    $body = $found | Where-Object { -not $_.Disabled } | ForEach-Object { '{0,-58} # {1}' -f $_.Package, $_.Why }
    Set-Content $path ($header + $body) -Encoding UTF8
    Step "Draft written: $path"
    Info 'Review it, then:  .\cleanthetv.ps1 setup -ListFile <that file> -DryRun   (and without -DryRun when happy)'
    Info 'A list that works well on your TV is worth sharing: copy it to examples\<model>\debloat.txt with a tv.json and open a pull request.'
}

function Run-Tool($script, $arguments) {
    # The tools open their own ADB session: drop ours first, two at once makes some TVs refuse one.
    $null = & $adb disconnect "${ip}:5555" 2>&1
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script @arguments
    if ($LASTEXITCODE -ne 0) { throw "$(Split-Path $script -Leaf) failed (exit $LASTEXITCODE)" }
}

# ================================================================== commands ==================================================================
if ($Command -eq 'find') {
    Step 'Looking for TVs'
    $hits = @(Find-Tvs)
    if ($hits.Count) { $hits | ForEach-Object { Info "ADB answers at $_" } } else { Warn 'No TV answered. Is debugging on and is the TV on this Wi-Fi?' }
    return
}

$adb = Get-Adb
Step 'Finding your TV'
$ip = Resolve-Tv
Info "TV at $ip"
if (-not $adb) { Warn 'Dry run stops here without adb.'; return }
Connect-Tv $adb $ip
$info = Get-TvInfo $adb $ip
Info "$($info.Maker) $($info.Model), Android $($info.Android)"
if ($Command -in 'setup', 'theme', 'restore') {
    $list = if ($ListFile) { (Resolve-Path $ListFile).Path } else { Find-List $info }
    if ($list) { Info "Debloat list: $($list.Replace($root + '\', ''))" } else { Warn "No tested list for '$($info.Model)'. Try '.\cleanthetv.ps1 scan' for a draft. The launcher and theme still work; the debloat step is skipped." }
    if ($list) {
        $filtered = Get-FilteredList $list
        $list = $filtered.Path
        if ($filtered.Skipped.Count) { Info "Keeping $($filtered.Skipped.Count) app(s) enabled (voice, casting, firmware updates, anything in -Keep): $($filtered.Skipped -join ', '). Use -IncludePersonalChoices to disable the optional ones too." }
    }
}

switch ($Command) {
    'report' {
        Step 'Health report'
        $now = Save-Snapshot 'now'
        $base = Get-Baseline
        Show-Report $now $base
        if (-not $base) { Warn 'No "before" reading for this TV. setup takes one automatically before it changes anything.' }
        Info 'RAM and process counts move around: reboot the TV and wait a minute before each reading for a fair comparison.'
    }
    'privacy' { Invoke-Privacy }
    'scan' { Invoke-Scan }
    'setup' {
        $apk = $Apk
        if (-not $apk) { $apk = @('dist\cleanthetv-launcher.apk', 'launcher\app\build\outputs\apk\release\app-release.apk') | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1 }
        $themeDir = Join-Path $root "themes\$Theme"
        if (-not (Test-Path (Join-Path $themeDir 'config.json'))) { throw "No theme called '$Theme'. See the themes folder." }
        Step 'Plan'
        if ($list) { Info "1. Disable the apps in that list (nothing is uninstalled)" }
        Info "2. Install the CleanTheTV launcher and make it Home$(if (-not $apk) { ' (NO APK FOUND: pass -Apk or build it)' })"
        Info "3. Push the '$Theme' theme"
        if ($DryRun) { Warn 'Dry run: nothing was changed.'; return }
        if (-not $apk) { throw 'No launcher APK. Download one from the releases page, or build launcher\ with Gradle, then pass -Apk <file>.' }
        Ensure-Venv
        Step 'Taking a "before" reading (for .\cleanthetv.ps1 report)'
        $null = Save-Snapshot 'before'
        if ($list) { Step 'Disabling apps'; Run-Tool (Join-Path $root 'tools\disable.ps1') @('-TvHost', $ip, $list) }
        Step 'Installing the launcher'
        $built = Join-Path $root 'launcher\app\build\outputs\apk\release\app-release.apk'
        if ((Resolve-Path $apk).Path -ne $built) { New-Item -ItemType Directory -Force (Split-Path $built) | Out-Null; Copy-Item $apk $built -Force }
        $env:SKIP_BUILD = '1'
        Run-Tool (Join-Path $root 'launcher\build-and-install.ps1') @('-TvHost', $ip)
        Step "Applying the '$Theme' theme"
        Run-Tool (Join-Path $root 'tools\theme.ps1') @('-TvHost', $ip, $themeDir)
        Step 'Done. Press Home on the remote. To undo everything: .\cleanthetv.ps1 restore'
    }
    'theme' {
        $themeDir = Join-Path $root "themes\$Theme"
        if (-not (Test-Path (Join-Path $themeDir 'config.json'))) { throw "No theme called '$Theme'." }
        if ($DryRun) { Warn "Dry run: would push '$Theme'."; return }
        Ensure-Venv
        Run-Tool (Join-Path $root 'tools\theme.ps1') @('-TvHost', $ip, $themeDir)
    }
    'restore' {
        if ($DryRun) { Warn 'Dry run: would re-enable the listed apps and bring back the stock launcher.'; return }
        Ensure-Venv
        Step 'Resetting the theme'
        Run-Tool (Join-Path $root 'tools\theme.ps1') @('-TvHost', $ip, '-Reset')
        if ($list) { Step 'Restoring apps and the stock launcher'; Run-Tool (Join-Path $root 'tools\restore.ps1') @('-TvHost', $ip, $list) }
        else { Warn 'No list for this model; restore with tools\restore.ps1 <the list you used>.' }
    }
}
