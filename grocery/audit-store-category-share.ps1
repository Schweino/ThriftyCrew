<#
  audit-store-category-share.ps1 - step 9 of design/PLAN-zero-alert-days-remainder-2026-09-24.md, its first bar:
  "First measure what share of each store's rows carries a usable category."

  Per store in stores.json (every store, in its order), over the NEWEST file of each family store-department-map.json
  declares for it (regular or deals rows under 'files', weekly-ad and deals rows under 'ad_files', filtered to the
  store): how many rows were read, how many carry the declared category field at all, and how many carry a USABLE one,
  meaning a value that store-department-lib.ps1 translates into at least one department. A store missing from the map
  is UNDECLARED and counts every row as unusable. Family Fare's flyer-link evidence is reported on its own line, since
  it is the only category source the Weekly Ad lines have.

  Read-only: it prints, and with -OutFile writes one JSON report where it is told. It changes nothing.

  SCOPE OF A CLEAN REPORT: not a detector, a census. The numbers are as sound as the map: a value the map does not
  translate counts as present but not usable, and the top such values are printed so the map can be read against them.
  WHEN THE PRODUCER STOPS: a store whose declared files are all missing reads 0 of 0 and is named BLIND; zero rows over
  every store exits 3.

  Exit: 0 measured; 3 BLIND (no rows at all); 1 threw. Last line is the marker.
  Usage: .\audit-store-category-share.ps1 [-OutFile <json>] [-DataRoot <grocery tree>]
         .\audit-store-category-share.ps1 -SelfTest
#>
# gate-inputs: grocery\audit-store-category-share.ps1, grocery\store-department-lib.ps1, grocery\aisle-lib.ps1
param([string]$OutFile = '', [string]$DataRoot = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$data = if ($DataRoot) { $DataRoot } else { $root }
. (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')   # Read-JsonFile, named here though the lib loads it too
. (Join-Path $root 'store-department-lib.ps1')

function Measure-StoreCategoryShare([string]$Root) {
  $map = Read-StoreDeptMap $Root
  $reg = Read-JsonFile (Join-Path $Root 'stores.json')
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($st in @($reg.stores | Sort-Object { [int]$_.order })) {
    $name = [string]$st.name
    $cfg = $map.stores.$name
    $m = [ordered]@{ store = $name; field = ''; declared = [bool]$cfg; files = @(); rows = 0; present = 0; usable = 0; ad_rows = 0; unmapped = @{} }
    if ($cfg) {
      $m.field = $(if ($cfg.field) { [string]$cfg.field } elseif ($cfg.url_field) { [string]$cfg.url_field } else { '(none captured)' })
      foreach ($fam in 'files', 'ad_files') {
        $c2 = [pscustomobject]@{ files = @($cfg.$fam) }
        $fs = Get-StoreDeptFiles $Root $c2   # assign, then wrap
        foreach ($f in @($fs)) {
          $m.files += $f.Name
          foreach ($r in @((Read-JsonFile $f.FullName).deals)) {
            if ($null -eq $r) { continue }
            if ($fam -eq 'ad_files' -and $r.store -and [string]$r.store -ne $name) { continue }
            $m.rows++; if ($fam -eq 'ad_files') { $m.ad_rows++ }
            $sig = Get-RowStoreDepts $cfg $r
            if (-not $sig.raw) { continue }
            $m.present++
            if (@($sig.depts).Count -gt 0) { $m.usable++ } else { $m.unmapped[$sig.raw] = 1 + [int]$m.unmapped[$sig.raw] }
          }
        }
      }
    }
    $out.Add([pscustomobject]$m)
  }
  $ev = $null
  $ff = $map.stores.'Family Fare'
  if ($ff -and $ff.evidence) {
    $evf = Get-ChildItem (Join-Path $Root ([string]$ff.evidence)) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($evf) {
      $ev = [ordered]@{ file = $evf.Name; lines = 0; resolved = 0; with_dept = 0 }
      foreach ($ln in [IO.File]::ReadAllLines($evf.FullName, [Text.Encoding]::UTF8)) {
        if (-not $ln.Trim()) { continue }
        $r = $ln | ConvertFrom-Json; $ev.lines++
        if ([string]$r.kind -ne 'candidate') { continue }
        $ev.resolved++; if (Get-AisleDept ([string]$r.canonical_url)) { $ev.with_dept++ }
      }
    }
  }
  return [pscustomobject]@{ stores = $out.ToArray(); evidence = $ev }
}

function Format-Share([int]$n, [int]$d) { if ($d -eq 0) { return "0 of 0 (BLIND)" }; return ('{0} of {1} ({2:N1}%)' -f $n, $d, (100.0 * $n / $d)) }

if ($SelfTest) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('scs-st-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  $pass = 0; $fail = 0; $ran = 0; $EXPECTED = 4
  function Check([string]$label, [bool]$ok) { $script:ran++; if ($ok) { $script:pass++; Write-Output ('  ok    ' + $label) } else { $script:fail++; Write-Output ('  FAIL  ' + $label) } }
  function Put([string]$rel, [string]$text) { $p = Join-Path $tmp $rel; New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null; [IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding($false))) }
  try {
    Put 'stores.json' '{"stores":[{"name":"Hy-Vee","order":1},{"name":"Walmart","order":2},{"name":"Nowhere Mart","order":3}]}'
    Put 'store-department-map.json' '{"stores":{"Hy-Vee":{"files":["out/regular/hyvee-regular-*.json"],"ad_files":["out/ads-*.json"],"field":"store_department","map":{"Produce":"fresh_fruits_vegetables"}},"Walmart":{"files":["out/regular/walmart-regular-*.json"],"field":""}}}'
    Put 'out/regular/hyvee-regular-2026-01-01.json' '{"deals":[{"item":"OLD","store_department":"Produce"},{"item":"OLD2","store_department":"Produce"}]}'
    Put 'out/regular/hyvee-regular-2026-01-02.json' '{"deals":[{"item":"Lemons","store_department":"Produce"},{"item":"Mystery","store_department":"Grilling"},{"item":"Carried"}]}'
    Put 'out/ads-2026-01-02.json' '{"deals":[{"item":"Ad Lemons","store":"Hy-Vee"},{"item":"FF line","store":"Family Fare"}]}'
    Put 'out/regular/walmart-regular-2026-01-02.json' '{"deals":[{"item":"Great Value Rice"}]}'
    $r = Measure-StoreCategoryShare $tmp
    $h = @($r.stores | Where-Object { $_.store -eq 'Hy-Vee' })[0]; $w = @($r.stores | Where-Object { $_.store -eq 'Walmart' })[0]; $u = @($r.stores | Where-Object { $_.store -eq 'Nowhere Mart' })[0]
    Check 'Hy-Vee: newest regular file only, plus its OWN ad rows: 4 rows, 2 present, 1 usable, 1 ad row' ($h.rows -eq 4 -and $h.present -eq 2 -and $h.usable -eq 1 -and $h.ad_rows -eq 1)
    Check 'a value the map does not translate is present but not usable, and is named (Grilling)' ($h.unmapped.ContainsKey('Grilling'))
    Check 'CLEAN TWIN: a store that captures no category reads 0 usable of its rows, counted, never skipped' ($w.rows -eq 1 -and $w.usable -eq 0 -and $w.field -eq '(none captured)')
    Check 'a store in stores.json but not in the map is UNDECLARED, not dropped' ($null -ne $u -and -not $u.declared -and $u.rows -eq 0)
  } catch {
    $fail++; Write-Output ('  FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($ran -ne $EXPECTED) { $fail++; Write-Output ("  FAIL  ran $ran of $EXPECTED cases - a case did not run") }
  if ($fail -eq 0) { Write-Output ("audit-store-category-share self-test PASS ($pass of $EXPECTED cases)"); exit 0 }
  Write-Output ("audit-store-category-share self-test FAIL ($fail failure(s), $pass of $EXPECTED passed)"); exit 1
}

try {
  $res = Measure-StoreCategoryShare $data
  $tot = 0; $totU = 0
  Write-Output 'store category share (step 9 coverage): usable = the value maps to a department in store-department-map.json'
  foreach ($s in @($res.stores)) {
    $tot += $s.rows; $totU += $s.usable
    if (-not $s.declared) { Write-Output ("  {0,-12} UNDECLARED in store-department-map.json - no category is read for it" -f $s.store); continue }
    Write-Output ("  {0,-12} field {1,-17} usable {2}; present {3}; ad rows {4}; files {5}" -f $s.store, $s.field, (Format-Share $s.usable $s.rows), $s.present, $s.ad_rows, ($s.files -join ', '))
    $top = @($s.unmapped.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)
    if ($top.Count -gt 0) { Write-Output ('               present but unmapped, top: ' + (($top | ForEach-Object { "'" + $_.Key + "' " + $_.Value }) -join '; ')) }
  }
  if ($res.evidence) { Write-Output ("  Family Fare Weekly Ad lines, flyer-link evidence {0}: department on {1} resolved; {2} of {3} lines resolved" -f $res.evidence.file, (Format-Share $res.evidence.with_dept $res.evidence.resolved), $res.evidence.resolved, $res.evidence.lines) }
  Write-Output ('  ALL          usable ' + (Format-Share $totU $tot))
  if ($OutFile) {
    $rep = [ordered]@{ measured_at = (Get-Date).ToString('s'); stores = @($res.stores | ForEach-Object { [ordered]@{ store = $_.store; field = $_.field; rows = $_.rows; present = $_.present; usable = $_.usable; ad_rows = $_.ad_rows; files = $_.files } }); evidence = $res.evidence }
    [IO.File]::WriteAllText($OutFile, ($rep | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Write-Output ('  wrote ' + $OutFile)
  }
  if ($tot -eq 0) { Write-Output 'STORE-CATEGORY-SHARE BLIND: zero rows read across every store. Nothing was measured.'; Write-Output 'STORE-CATEGORY-SHARE-COMPLETE rows=0 blind=no-rows'; exit 3 }
  Write-Output ("STORE-CATEGORY-SHARE-COMPLETE rows={0} usable={1} stores={2}" -f $tot, $totU, @($res.stores).Count)
  exit 0
} catch {
  Write-Output ('STORE-CATEGORY-SHARE threw: ' + $_.Exception.Message)
  Write-Output 'STORE-CATEGORY-SHARE-COMPLETE rows=0 blind=threw'; exit 1
}
