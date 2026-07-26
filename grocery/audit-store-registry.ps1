<#
  audit-store-registry.ps1 - drift guard for the canonical store registry (stores.json).

  THE BUG CLASS THIS CATCHES: a store is added to the board but a script's hardcoded store list is
  missed, so that store silently drops out of ONE surface while every other surface carries it.
  Real instances: build-store-guide excluded Fareway 07-12..07-26; publish-store-guide's and
  publish-deals-page's coverage GATES never checked Fareway; build-trend-pages' visible footer
  named only 6 stores.

  CHECKS
    1. stores.json parses; names + orders + regular_prefixes unique.
    2. The newest out\comparison-*.json store set EQUALS the registry set (both directions).
    3. Every out\regular\<prefix>-regular-*.json prefix is a registered regular_prefix.
    4. Every store in ad-schedule.json is registered.
    5. CODE SCAN: every non-comment line in a live grocery .ps1 that names >= 3 registry stores
       must name ALL of them, unless the line matches an entry in stores.json allowed_subsets.
       (Names are matched with both ' and the &#39; entity so site-copy strings are scanned too.)

  Exit 0 = clean, 2 = drift found (advisory in the daily pipeline: alert, don't block).
  Params: -Alert (send-alert on drift, de-duped by signature)
#>
param([switch]$Alert)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
$issues = New-Object System.Collections.Generic.List[string]

# ---- 1. registry sanity ----
$reg = Get-Content (Join-Path $root 'stores.json') -Raw | ConvertFrom-Json
$names = @($reg.stores | Sort-Object { [int]$_.order } | ForEach-Object { [string]$_.name })
foreach ($grp in @('name','order','regular_prefix')) {
  $dup = @($reg.stores | Group-Object $grp | Where-Object { $_.Count -gt 1 })
  foreach ($d in $dup) { $issues.Add("registry: duplicate $grp '" + $d.Name + "'") }
}

# ---- 2. newest comparison vs registry ----
$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($cmpF) {
  $doc = Get-Content $cmpF.FullName -Raw | ConvertFrom-Json
  $seen = @{}
  foreach ($r in $doc.comparison) { foreach ($st in $r.stores) { $seen[[string]$st.store] = $true } }
  foreach ($s in $seen.Keys)  { if ($names -notcontains $s) { $issues.Add("board: store '$s' is on the board but NOT in stores.json") } }
  foreach ($s in $names)      { if (-not $seen.ContainsKey($s)) { $issues.Add("board: registered store '$s' has ZERO cells on the newest board ($($cmpF.Name))") } }
}

# ---- 3. out\regular prefixes ----
$prefixes = @($reg.stores | ForEach-Object { [string]$_.regular_prefix })
foreach ($f in (Get-ChildItem (Join-Path $OutDir 'regular\*-regular-*.json') -EA SilentlyContinue)) {
  $p = $f.BaseName -replace '-regular-.*$',''
  if ($prefixes -notcontains $p) { $issues.Add("out\regular: file prefix '$p' ($($f.Name)) is not a registered regular_prefix") }
}

# ---- 4. ad-schedule ----
$schedF = Join-Path $root 'ad-schedule.json'
if (Test-Path $schedF) {
  $sched = Get-Content $schedF -Raw | ConvertFrom-Json
  foreach ($s in $sched.stores) { $sn = [string]$s.store; if ($sn -and ($names -notcontains $sn)) { $issues.Add("ad-schedule.json: store '$sn' is not in stores.json") } }
}

# ---- 5. code scan (live scripts only; archive/, out/, brands/ excluded) ----
$subsets = @($reg.allowed_subsets)
$scanFiles = Get-ChildItem (Join-Path $root '*.ps1') | Where-Object { $_.Name -ne 'audit-store-registry.ps1' }
foreach ($f in $scanFiles) {
  $ln = 0; $inBlock = $false
  foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
    $ln++
    $t = $line.TrimStart()
    if ($inBlock) { if ($t -match '#>') { $inBlock = $false }; continue }   # block-comment prose
    if ($t.StartsWith('<#')) { if ($t -notmatch '#>') { $inBlock = $true }; continue }
    if ($t.StartsWith('#')) { continue }                       # pure comment lines are prose, not behavior
    $idx = $line.IndexOf(' # '); $code = if ($idx -ge 0) { $line.Substring(0, $idx) } else { $line }
    $hit = 0; $missing = @()
    foreach ($n in $names) {
      $variants = @($n, ($n -replace "'", '&#39;'), ($n -replace "'", '&rsquo;'))
      $found = $false; foreach ($v in $variants) { if ($code.IndexOf($v, [StringComparison]::Ordinal) -ge 0) { $found = $true; break } }
      if ($found) { $hit++ } else { $missing += $n }
    }
    if ($hit -ge 3 -and $missing.Count -gt 0) {
      $allowed = $false
      foreach ($as in $subsets) { if (($f.Name -eq [string]$as.file) -and ($line.IndexOf([string]$as.contains, [StringComparison]::Ordinal) -ge 0)) { $allowed = $true; break } }
      if (-not $allowed) { $issues.Add(("code: {0}:{1} names {2} store(s) but is missing {3}" -f $f.Name, $ln, $hit, ($missing -join ', '))) }
    }
  }
}

# ---- report ----
if ($issues.Count -eq 0) { Write-Output ("store-registry: OK  " + $names.Count + " stores; board, files, schedule and live scripts all agree"); exit 0 }
Write-Output ("store-registry: " + $issues.Count + " drift issue(s):")
$issues | ForEach-Object { Write-Output ("  " + $_) }
if ($Alert) {
  $sig = (($issues | Sort-Object) -join ';')
  $sigF = Join-Path $OutDir 'store-registry-alert.sig'
  $prev = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  $sigH = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))) -replace '-',''
  if ($sigH -ne $prev) {
    try {
      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject ("Grocery: store-registry drift - " + $issues.Count + " issue(s)") -Body ("audit-store-registry.ps1 found hardcoded store lists or data out of lockstep with stores.json: " + (($issues | Select-Object -First 12) -join ' | ') + ". Fix the listed script/data or document a legitimate subset in stores.json allowed_subsets.") | Out-Null
      if ($LASTEXITCODE -eq 0) { Set-Content $sigF -Value $sigH -Encoding ASCII }
    } catch {}
  }
}
exit 2
