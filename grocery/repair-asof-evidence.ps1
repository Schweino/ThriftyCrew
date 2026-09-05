<#
  repair-asof-evidence.ps1 - re-date a published row DOWN to the newest capture that actually holds it, and
  drop it if that honest date falls outside the carry window.

  WHY A REPAIR AND NOT JUST THE BUILDER FIX (2026-08-02). build-fareway-regular.ps1 now stamps each row with
  the date of the extract it came from, which fixed 430 of the 431 laundered rows on the live file. The last
  one is a row the builder never touched: carry-forward-regular.ps1 copies rows out of PRIOR regular files
  and faithfully preserves the as_of it finds there - and every regular file built before the fix carries
  laundered dates. So 'Seedless Watermelon' ($5.99) was carried into 2026-08-01 saying 2026-07-31 when the
  newest capture that has ever held it is 2026-07-15, eighteen days back and three days past the carry cap
  that exists to expire exactly that row.

  Rebuilding the historical files would not fix it either: each of those was itself built from a carry chain
  whose inputs are also laundered, so the correction would have to walk backwards through a week of files.
  The evidence needed is already on disk - every dated capture, including the ones aged out of the build - so
  the honest move is to read it and correct forward.

  WHAT IT WILL NOT DO. It only ever moves a date BACKWARD, never forward: a re-sighting at the same price is
  not a re-verification this script can vouch for, and inventing freshness is the bug it exists to undo.
  Rows whose product appears in NO capture (heal-degraded-sizes output, hand-verified rows, API rows) are
  left completely alone and counted - deleting real verified prices to satisfy a check would trade an honest
  date for a missing cell. Every drop is NAMED.

  Idempotent: a second run finds every row already at or below its evidence date and changes nothing.
  Called by: build-fareway-regular.ps1's tail (after carry-forward and heal-degraded-sizes, because both of
  those write rows this pass has to see). audit-asof-evidence.ps1 is the guard that fails if it stops working.
#>
param(
  [ValidateSet('fareway','aldi')][string]$Store,
  [int]$MaxAgeDays = 0,
  [string]$RegularDir = "",
  [string]$Root = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path $PSScriptRoot 'regular-fileset-lib.ps1')
# 0 = ask. Only build-fareway-regular passes -MaxAgeDays today, so this default was reachable
# by any future caller and would have quietly re-dated rows against a window nothing else uses.
if ($MaxAgeDays -le 0) { $MaxAgeDays = Get-RegularUnionDays }
# -Store is REQUIRED for a real run but must NOT be declared Mandatory (2026-08-08). PowerShell prompts for a
# missing mandatory parameter, so `-SelfTest` alone could never be invoked: it died with
# MissingMandatoryParameter on any non-interactive runner. This file's self-test therefore existed and had
# never once run - the "a fix needs a reachable self-test" class, found the day a change-time gate was added
# and 4 of 80 self-tests turned out to be unreachable for exactly this reason. Enforced explicitly instead.
if (-not $SelfTest -and -not $Store) { throw '-Store is required (fareway|aldi)' }
$root = if ($Root) { $Root } elseif ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }

$SRC = @{
  fareway = @{ glob = 'out\fareway\fareway-shop-*.json'; kind = 'json' }
  aldi    = @{ glob = 'out\captures\aldi-capture-*.csv'; kind = 'csv'; nameIx = 2 }
}

function Get-EvKey([string]$s) {
  # Same fold as audit-asof-evidence.ps1's Get-EvidenceKey, and it has to STAY the same: the guard measures
  # what this repairs, so two different keys would let the repair "fix" rows the guard never counted and
  # leave the ones it did. Collapsing too much only suppresses a repair, which is the safe direction.
  $k = ([string]$s).ToLower().Trim()
  $k = ($k -replace '[^a-z0-9]', ' ')
  return ($k -replace '\s+', ' ').Trim()
}

function Get-Evidence([string]$glob, [string]$kind, [int]$nameIx, [string]$base) {
  $seen = @{}
  $files = @(Get-ChildItem (Join-Path $base $glob) -ErrorAction SilentlyContinue |
             Where-Object { $_.BaseName -match '\d{4}-\d{2}-\d{2}$' } | Sort-Object Name)
  foreach ($f in $files) {
    $dt = [regex]::Match($f.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value
    if ($kind -eq 'json') {
      $rows = $null
      try { $rows = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
      foreach ($r in @($rows)) {
        if (-not $r.PSObject.Properties['name']) { continue }
        $k = Get-EvKey ([string]$r.name); if ($k) { $seen[$k] = $dt }
      }
    } else {
      foreach ($line in (Get-Content $f.FullName -Encoding UTF8)) {
        $p = $line -split '\|'; if ($p.Count -le $nameIx) { continue }
        $k = Get-EvKey $p[$nameIx]; if ($k) { $seen[$k] = $dt }
      }
    }
  }
  return @{ seen = $seen; files = $files.Count }
}

function Invoke-AsOfRepair([string]$store, [string]$base, [string]$regDir, [int]$maxAge) {
  $s = $SRC[$store]
  $files = @(Get-ChildItem (Join-Path $regDir ($store + '-regular-*.json')) -ErrorAction SilentlyContinue |
             Where-Object { $_.BaseName -match ('^' + [regex]::Escape($store) + '-regular-\d{4}-\d{2}-\d{2}$') } |
             Sort-Object Name -Descending | Select-Object -First 1)
  if ($files.Count -eq 0) { return "asof-repair [$store]: no dated regular file - nothing to repair" }
  $f = $files[0]
  $fileDate = [datetime]([regex]::Match($f.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
  $doc = Read-JsonFile $f.FullName
  $nameIx = if ($s.ContainsKey('nameIx')) { [int]$s.nameIx } else { 0 }
  $ev = Get-Evidence $s.glob $s.kind $nameIx $base
  # NO CAPTURES = NO EVIDENCE = NO REPAIR. Running with an empty evidence map would silently "find" nothing
  # wrong and print a clean line, which is the shape of a check that can never fire.
  if ($ev.files -eq 0) { return "asof-repair [$store]: NO dated capture files matched $($s.glob) - there is no evidence to repair against, so nothing was changed (this is a blind run, not a clean one)" }

  $redated = 0; $dropped = New-Object System.Collections.Generic.List[string]; $unbacked = 0
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($r in @($doc.deals)) {
    $ao = ''
    if ($r.PSObject.Properties['as_of']) { $ao = [string]$r.as_of }
    $k = Get-EvKey ([string]$r.item)
    if (-not $ao -or ($ao -notmatch '^\d{4}-\d{2}-\d{2}$') -or -not $k -or -not $ev.seen.ContainsKey($k)) {
      if ($ao -and $k -and -not $ev.seen.ContainsKey($k)) { $unbacked++ }
      $out.Add($r); continue
    }
    $trueDate = $ev.seen[$k]
    if ($ao -gt $trueDate) { $r.as_of = $trueDate; $redated++; $ao = $trueDate }   # backward only, never forward
    if (([int]($fileDate - [datetime]$ao).TotalDays) -gt $maxAge) {
      $dropped.Add(("{0} ({1}, last captured {2}, {3} days) " -f [string]$r.item, [string]$r.ad_price, $ao, [int]($fileDate - [datetime]$ao).TotalDays))
      continue
    }
    $out.Add($r)
  }
  if ($redated -eq 0 -and $dropped.Count -eq 0) {
    return "asof-repair [$store]: every dated row is at or below its capture evidence - nothing to repair ($unbacked row(s) have no capture evidence either way and were left alone)"
  }
  $doc.deals = $out
  $note = ("asof-repair: re-dated {0} row(s) down to their capture evidence, dropped {1} row(s) past the {2}-day window, left {3} unbacked row(s) alone" -f $redated, $dropped.Count, $maxAge, $unbacked)
  if ($doc.PSObject.Properties['asof_repair_note']) { $doc.asof_repair_note = $note } else { $doc | Add-Member -NotePropertyName asof_repair_note -NotePropertyValue $note }
  $doc | ConvertTo-Json -Depth 6 | Set-Content $f.FullName -Encoding UTF8
  $msg = "asof-repair [$store]: $note -> $($f.Name)"
  if ($dropped.Count -gt 0) { $msg += ("`n  DROPPED (absent by decision, not by accident): " + (($dropped.ToArray()) -join ', ')) }
  return $msg
}

if ($SelfTest) {
  $fail = 0
  $T = Join-Path $env:TEMP ('asofrep-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path (Join-Path $T 'out\regular') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $T 'out\fareway') -Force | Out-Null
  try {
    function Chk([string]$label, [bool]$cond, [string]$got) {
      if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    # FROZEN FIXTURE - the live 2026-08-02 case verbatim. 'Seedless Watermelon' was carried into the 08-01
    # file saying 2026-07-31 because the file it came from was built before the dating fix; the newest
    # capture that has ever held it is 2026-07-15, which is 17 days back and 3 days past the carry cap.
    (@(
      @{ id = 'watermelon'; name = 'Seedless Watermelon'; price = '5.99'; size = 'each' },
      @{ id = 'tomatoes';   name = 'NatureSweet Cherubs Tomatoes'; price = '3.99'; size = '10 oz' }
    ) | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $T 'out\fareway\fareway-shop-2026-07-15.json') -Encoding UTF8
    (@(
      @{ id = 'ranch-dressing'; name = 'Fareway Ranch Dressing'; price = '0.99'; size = '16 fl oz' },
      @{ id = 'tomatoes';       name = 'NatureSweet Cherubs Tomatoes'; price = '3.99'; size = '10 oz' }
    ) | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $T 'out\fareway\fareway-shop-2026-07-23.json') -Encoding UTF8
    $mk = {
      @{ store = 'Fareway'; price_type = 'everyday'; price_mode = 'in-store'; mode_verified = '2026-08-01'; deals = @(
        # (a) MUST FIRE: laundered AND past the window once honest -> re-dated to 07-15, then dropped
        @{ store = 'Fareway'; item = 'Seedless Watermelon'; ad_price = '$5.99'; size = 'each'; as_of = '2026-07-31' },
        # (b) MUST FIRE: laundered but still INSIDE the window once honest -> re-dated to 07-23, KEPT
        @{ store = 'Fareway'; item = 'Fareway Ranch Dressing'; ad_price = '$0.99'; size = '16 fl oz'; as_of = '2026-08-01' },
        # (c) CLEAN TWIN: already honest, untouched
        @{ store = 'Fareway'; item = 'NatureSweet Cherubs Tomatoes'; ad_price = '$3.99'; size = '10 oz'; as_of = '2026-07-23' },
        # (d) CLEAN TWIN: no capture has ever held it -> left completely alone even though it is 30 days old
        @{ store = 'Fareway'; item = 'Hand Verified Mystery Item'; ad_price = '$1.00'; size = '1 ct'; as_of = '2026-07-02' }
      ) }
    }
    (& $mk) | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'out\regular\fareway-regular-2026-08-01.json') -Encoding UTF8
    $msg = Invoke-AsOfRepair 'fareway' $T (Join-Path $T 'out\regular') 14
    Write-Output ("      " + ($msg -replace "`r?`n", ' '))
    $d = Read-JsonFile (Join-Path $T 'out\regular\fareway-regular-2026-08-01.json')
    $by = @{}; foreach ($x in @($d.deals)) { $by[[string]$x.item] = $x }
    Chk '(a) MUST FIRE laundered + past the window -> dropped' (-not $by.ContainsKey('Seedless Watermelon')) 'row survived'
    Chk '(a) the drop is NAMED with its real capture date' ($msg -match 'Seedless Watermelon' -and $msg -match '2026-07-15') ($msg -replace "`r?`n", ' ')
    Chk '(b) MUST FIRE laundered but inside the window -> re-dated, KEPT' ($by.ContainsKey('Fareway Ranch Dressing') -and $by['Fareway Ranch Dressing'].as_of -eq '2026-07-23') ("as_of=" + $by['Fareway Ranch Dressing'].as_of)
    Chk '(c) CLEAN TWIN an already-honest date is untouched' ($by.ContainsKey('NatureSweet Cherubs Tomatoes') -and $by['NatureSweet Cherubs Tomatoes'].as_of -eq '2026-07-23') ("as_of=" + $by['NatureSweet Cherubs Tomatoes'].as_of)
    Chk '(d) CLEAN TWIN an UNBACKED row is never re-dated nor dropped' ($by.ContainsKey('Hand Verified Mystery Item') -and $by['Hand Verified Mystery Item'].as_of -eq '2026-07-02') ("present=" + $by.ContainsKey('Hand Verified Mystery Item'))
    Chk 'envelope survives (price_mode / mode_verified)' ($d.price_mode -eq 'in-store' -and $d.mode_verified -eq '2026-08-01') "price_mode=$($d.price_mode)"
    $msg2 = Invoke-AsOfRepair 'fareway' $T (Join-Path $T 'out\regular') 14
    $d2 = Read-JsonFile (Join-Path $T 'out\regular\fareway-regular-2026-08-01.json')
    Chk 'idempotent - a second run changes nothing' ((@($d2.deals).Count -eq 3) -and ($msg2 -match 'nothing to repair')) ("rows=$(@($d2.deals).Count) msg=$msg2")
    # NEVER FORWARD: a row dated BEFORE its newest sighting must keep its own older date. 2026-07-20 is
    # chosen deliberately - older than the 07-23 sighting (so a forward move would show) but still inside
    # the 14-day window from 08-01 (so the cap cannot drop the row and hide the answer, which is what the
    # first version of this case did: it used 07-15, the row was lawfully dropped, and the assertion read
    # an empty date rather than a preserved one).
    $doc3 = & $mk
    $doc3.deals = @(@{ store = 'Fareway'; item = 'NatureSweet Cherubs Tomatoes'; ad_price = '$3.99'; size = '10 oz'; as_of = '2026-07-20' })
    $doc3 | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'out\regular\fareway-regular-2026-08-01.json') -Encoding UTF8
    $null = Invoke-AsOfRepair 'fareway' $T (Join-Path $T 'out\regular') 14
    $d3 = Read-JsonFile (Join-Path $T 'out\regular\fareway-regular-2026-08-01.json')
    Chk 'dates move BACKWARD only - a re-sighting never re-verifies a row' ((@($d3.deals).Count -eq 1) -and (@($d3.deals)[0].as_of -eq '2026-07-20')) ("rows=$(@($d3.deals).Count) as_of=" + @($d3.deals)[0].as_of)
    # BLIND: no captures at all must NOT read as a clean run.
    Remove-Item (Join-Path $T 'out\fareway') -Recurse -Force
    $msg4 = Invoke-AsOfRepair 'fareway' $T (Join-Path $T 'out\regular') 14
    Chk 'no captures -> reported BLIND, not clean' ($msg4 -match 'blind run, not a clean one') $msg4
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$regDir = if ($RegularDir) { $RegularDir } else { Join-Path $root 'out\regular' }
Write-Output (Invoke-AsOfRepair $Store $root $regDir $MaxAgeDays)
