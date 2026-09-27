<#
  audit-category-coverage.ps1 - INVARIANT guard: every commodity in commodities.json must belong to EXACTLY ONE
  category in categories.json. A commodity with NO category is matched/priced by the engine but NEVER RENDERS on
  the board (build-deals-page walks categories -> their commodity lists), so it would be silently invisible and in
  no filter. A commodity in >1 category renders twice. Both are bugs. This also flags category entries that point
  at a commodity id that no longer exists.

  So that "add a new item" can never forget to file it into a department/filter: this is a HARD publish gate
  (exit 2 -> publish HELD) and a daily alert. The automated daily pipeline never ADDS commodities, so it only
  ever trips right after a human adds one without categorizing it - exactly when it should.

  Modes: (default) report + exit 2 if any uncategorized / multi-category / orphan-ref, else 0
         -Alert   send-alert.ps1 once per NEW issue-set (signature de-dup) - for the daily pipeline
         -Source  the PUSH-TIME form (ops\run-gates.ps1 static list, 2026-09-26, queue 2026-09-26-f73dc7): reads the two
                  tracked files only, writes no report and sends no alert, so it runs on a bare checkout. Commit
                  4880ebc98 added lo-mein-noodles, sweet-potato-glass-noodles and blackened-seasoning with no category
                  and nothing refused the push: the first thing to notice was publish-deals-page holding the 2026-09-26
                  republish. A source defect is refused where the source changes.
         -SourceDir the directory holding commodities.json and categories.json (default: this script's own); the
                  self-test points it at a fixture tree.

  SCOPE OF A CLEAN REPORT: SOUND and COMPLETE over the two files it reads - every commodity id is counted against every
  category list, so a clean report means each id is in exactly one category, and a finding is the defect itself.
#>
# The -SelfTest re-runs this script over fixtures it writes under %TEMP% (-SourceDir, -OutDir, -Source); the child loads alert-lib, so it is declared (M3, design\PLAN-push-gate-diet-2026-09-27.md).
# gate-inputs: lib\guard-contract.ps1, grocery\alert-lib.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$Alert, [string]$OutDir = "", [switch]$Source, [string]$SourceDir = "", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ($SelfTest) {
  # Each case runs THIS script as a child with -Root at a per-run fixture tree, the way run-gates runs it (-Source).
  $script:ccBad = 0; $script:ccN = 0
  function Ccc([string]$label, [bool]$ok, [string]$got) { $script:ccN++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:ccBad++ } }
  $ccTmp = Join-Path ([IO.Path]::GetTempPath()) ('ccov-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $ccUtf8 = New-Object Text.UTF8Encoding($false)
  function Invoke-CcCase([string]$name, [string]$commodities, [string]$categories) {
    $d = Join-Path $ccTmp $name
    New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText((Join-Path $d 'commodities.json'), $commodities, $ccUtf8)
    [IO.File]::WriteAllText((Join-Path $d 'categories.json'), $categories, $ccUtf8)
    New-Item -ItemType Directory -Path (Join-Path $d 'out') -Force -ErrorAction Stop | Out-Null
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -SourceDir $d -OutDir (Join-Path $d 'out') -Source)
    return [pscustomobject]@{ rc = $LASTEXITCODE; out = $o; text = ($o -join ' / '); dir = $d }
  }
  try {
    New-Item -ItemType Directory -Path $ccTmp -ErrorAction Stop | Out-Null
    # FROZEN FIXTURE, the founding push (4880ebc98, 2026-09-26): three new ids, none filed in categories.json.
    $cm = '[{"id":"egg-noodles"},{"id":"lo-mein-noodles"},{"id":"sweet-potato-glass-noodles"},{"id":"blackened-seasoning"},{"id":"paprika"}]'
    $catsBad = '{"categories":[{"key":"grains","commodities":["egg-noodles"]},{"key":"baking","commodities":["paprika"]}]}'
    $r = Invoke-CcCase 'fire' $cm $catsBad
    Ccc 'MUST FIRE  -Source over the 4880ebc98 push (3 commodities in no category) exits 2 and names all three' (($r.rc -eq 2) -and ($r.text -match 'uncategorized=3') -and ($r.text -match 'lo-mein-noodles') -and ($r.text -match 'sweet-potato-glass-noodles') -and ($r.text -match 'blackened-seasoning')) ('rc=' + $r.rc + ' ' + $r.text)
    Ccc 'MUST FIRE  -Source writes no category-coverage-report.json into the -OutDir it is handed (push time writes nothing)' (-not (Test-Path -LiteralPath (Join-Path (Join-Path $r.dir 'out') 'category-coverage-report.json'))) ('a report was written under ' + $r.dir)
    # MUST NOT FIRE: the same commodities, each filed exactly once (the e0d5cf repair), exits 0.
    $catsGood = '{"categories":[{"key":"grains","commodities":["egg-noodles","lo-mein-noodles","sweet-potato-glass-noodles"]},{"key":"baking","commodities":["paprika","blackened-seasoning"]}]}'
    $r = Invoke-CcCase 'clean' $cm $catsGood
    Ccc 'MUST NOT FIRE  -Source with every commodity in exactly one category exits 0 and says examined=5' (($r.rc -eq 0) -and ($r.text -match 'examined=5 ')) ('rc=' + $r.rc + ' ' + $r.text)
    # CLEAN TWIN: the other two defects still fire in the push-time form - a commodity filed twice, and a category
    # that points at an id commodities.json no longer has.
    $catsTwice = '{"categories":[{"key":"grains","commodities":["egg-noodles","lo-mein-noodles","sweet-potato-glass-noodles","ghost-id"]},{"key":"baking","commodities":["paprika","blackened-seasoning","egg-noodles"]}]}'
    $r = Invoke-CcCase 'twice' $cm $catsTwice
    Ccc 'CLEAN TWIN  -Source still fails a commodity in two categories and a category naming a missing id (multi-category=1, orphan-refs=1)' (($r.rc -eq 2) -and ($r.text -match 'multi-category=1') -and ($r.text -match 'orphan-refs=1')) ('rc=' + $r.rc + ' ' + $r.text)
  } catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:ccBad++ }
  finally { if (Test-Path -LiteralPath $ccTmp) { Remove-Item -LiteralPath $ccTmp -Recurse -Force -ErrorAction SilentlyContinue } }
  $ccOk = ($script:ccBad -eq 0 -and $script:ccN -eq 4)
  Write-Output ('audit-category-coverage self-test ' + $(if ($ccOk) { 'pass' } else { 'FAIL' }) + ': ' + ($script:ccN - $script:ccBad) + ' of ' + $script:ccN + ' case(s) passed (4 expected)')
  exit $(if ($ccOk) { 0 } else { 1 })
}
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$srcDir = if ($SourceDir) { $SourceDir } else { $root }

$tmp = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $srcDir 'commodities.json'))); $commods = @($tmp)
$ids = @($commods | ForEach-Object { [string]$_.id })
$idset = @{}; foreach ($id in $ids) { $idset[$id] = $true }
$cats = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $srcDir 'categories.json')))).categories

# how many categories claim each commodity, and any category ref to a non-existent id
$catCount = @{}; foreach ($id in $ids) { $catCount[$id] = 0 }
$orphanRefs = New-Object System.Collections.Generic.List[string]
foreach ($c in $cats) {
  foreach ($cid in $c.commodities) {
    $s = [string]$cid
    if ($idset.ContainsKey($s)) { $catCount[$s]++ } else { $orphanRefs.Add($c.key + ' -> ' + $s) }
  }
}
$uncategorized = @($ids | Where-Object { $catCount[$_] -eq 0 } | Sort-Object)
$multi = @($ids | Where-Object { $catCount[$_] -gt 1 } | Sort-Object)

$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); commodities = $ids.Count; categories = @($cats).Count; uncategorized = $uncategorized; multi_category = $multi; orphan_category_refs = @($orphanRefs) }
if (-not $Source) { Set-Content (Join-Path $OutDir 'category-coverage-report.json') -Value ($report | ConvertTo-Json -Depth 4) -Encoding UTF8 }
$ccSum = 'examined=' + $ids.Count + ' categories=' + @($cats).Count + ' findings=' + ($uncategorized.Count + $multi.Count + $orphanRefs.Count)

$bad = $uncategorized.Count + $multi.Count + $orphanRefs.Count
if ($bad -eq 0) {
  Write-Output ("category-coverage: OK  all " + $ids.Count + " commodities are in exactly one of " + @($cats).Count + " categories")
  Exit-Guard -Name 'category-coverage' -Summary $ccSum -Code 0
}
Write-Output ("category-coverage: FAIL  uncategorized=" + $uncategorized.Count + "  multi-category=" + $multi.Count + "  orphan-refs=" + $orphanRefs.Count)
if ($uncategorized.Count) { Write-Output ("  NOT IN ANY CATEGORY (would be invisible / in no filter): " + ($uncategorized -join ', ')) }
if ($multi.Count) { Write-Output ("  IN MULTIPLE CATEGORIES (renders twice): " + ($multi -join ', ')) }
if ($orphanRefs.Count) { Write-Output ("  CATEGORY POINTS AT MISSING COMMODITY: " + ($orphanRefs -join ', ')) }

if ($Alert -and -not $Source) {
  $sig = ($uncategorized -join ';') + '|' + ($multi -join ';') + '|' + (($orphanRefs) -join ';')
  $sigHash = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))).Replace('-', '').Substring(0, 16)
  $sigF = Join-Path $OutDir 'category-coverage-alert.sig'
  $last = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  if ($sigHash -ne $last) {
    $body = "Category coverage problem (a new commodity is not filed into a department, so it renders in NO filter):`n" +
      $(if ($uncategorized.Count) { "UNCATEGORIZED: " + ($uncategorized -join ', ') + "`n" } else { '' }) +
      $(if ($multi.Count) { "MULTI-CATEGORY: " + ($multi -join ', ') + "`n" } else { '' }) +
      $(if ($orphanRefs.Count) { "ORPHAN REFS: " + ($orphanRefs -join ', ') + "`n" } else { '' }) +
      "Fix: add each commodity id to exactly one category's commodities[] in categories.json. Publish is HELD until then."
    try { Send-Alert -Subject "Grocery: a commodity is in no category (no filter) - review" -Body $body | Out-Null; Set-Content $sigF -Value $sigHash -Encoding UTF8 } catch {}
  }
}
Exit-Guard -Name 'category-coverage' -Summary $ccSum -Code 2
