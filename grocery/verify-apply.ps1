<#
  verify-apply.ps1 - Stage 3 of the semantic verify pass.
  Reads comparison-<date>.json + verify-verdicts-<date>.json (the LLM judgment) and writes
  verified-<date>.json: each commodity keeps only entries the judge CONFIRMED, re-ranks them,
  attaches annotations (e.g. "premium variety"), and drops a commodity that falls below -MinStores
  confirmed stores. Prints a change report (winners that moved, items dropped, annotations added).

  Verdict file shape:
    { week_of, verdicts: [ { id, entries: [ { store, keep: bool, annotation: string|null, reason: string,
                                              item: string (RECOMMENDED - the exact judged item name; without
                                              it a drop can only be applied blind, see the drift gate below) } ] } ] }

  VERDICT PERSISTENCE (2026-07-30). A confirmed DROP now outlives its week: it is recorded in
  verdict-suppressions.json keyed (id, store, normalised item) and re-applied on EVERY future run. Before
  this, only the current week's verdict file was read, so the same wrong products returned as soon as their
  week rolled over - 18 previously-dropped cells were live again on 2026-07-29, three as CROWNS (a pork loin
  filet as bacon, a frozen mixed-veg blend as broccoli, a 12-lb dry bag as canned pinto beans), each of which
  an LLM had already judged wrong in up to three separate weeks. A judgment that has to be re-made weekly is
  not a judgment, it is a tax - and any unattended week publishes the thing it already rejected.

  THE DRIFT GATE, equally important: this script used to drop by (id|store) BLIND. The board is rebuilt
  between judgment and apply routinely, so it dropped whatever occupied the cell at apply time - judged or
  not. A drop is now applied only when the verdict's item identity (its `item` field, or the name quoted in
  its reason) matches the cell; a mismatch WARNS and leaves the cell alone, because deleting a product nobody
  judged is the same bug promote-verdicts nearly shipped as permanent excludes. A verdict with NO recoverable
  identity still drops blind (legacy files), which dies out as verdict files start carrying `item`.

  A human overturn wins: a keep=true verdict whose identity matches a suppressed item REMOVES the suppression.
#>
param([string]$CompareFile = "", [string]$VerdictFile = "", [string]$OutDir = "", [int]$MinStores = 2,
      # Write somewhere other than verified-<week>.json. Used to build a SECOND, MinStores-1 verified board
      # purely as the price-history input: history must bank verified numbers, but it must also keep tracking
      # the ~24 single-store long-tail commodities that MinStores 2 legitimately keeps off the published page.
      [string]$OutFile = "",
      [string]$SuppressionsFile = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json
$week = [string]$doc.week_of
if (-not $VerdictFile) { $VerdictFile = Join-Path $OutDir ("verify-verdicts-"+$week+".json") }
$verdicts = Get-Content $VerdictFile -Raw | ConvertFrom-Json

# flat lookup "<id>|<store>" -> verdict entry (avoids nested-hashtable indexing quirks)
$vlook = @{}
foreach ($c in $verdicts.verdicts) { foreach ($e in $c.entries) { $vlook[("$($c.id)|$($e.store)")] = $e } }

# ---- durable suppressions: every confirmed DROP ever made, keyed (id, store, normalised item) ----
. (Join-Path $root 'verdict-lib.ps1')   # Get-VerdictNorm / Get-VerdictQuotedItem - SHARED with the -Accept gate
if (-not $SuppressionsFile) { $SuppressionsFile = Join-Path $root 'verdict-suppressions.json' }
$supp = @{}          # "id|store|item_norm" -> entry object
$suppDirty = $false
if (Test-Path $SuppressionsFile) {
  try { foreach ($se in @((Get-Content $SuppressionsFile -Raw | ConvertFrom-Json).suppressions)) {
          $supp[(([string]$se.id) + '|' + ([string]$se.store) + '|' + ([string]$se.item_norm))] = $se } }
  catch { Write-Warning ("verdict-suppressions.json unreadable - persistence is OFF this run: " + $_.Exception.Message) }
}
# Get-VerdictIdentity used to be re-defined right here, AFTER the dot-source above, so this local copy
# shadowed the lib and the rule had three homes. Hoisted into verdict-lib.ps1 on 2026-08-16 so the -Accept
# gate shares it (queue 2026-08-07-79b768); the dot-source on line 51 is where it comes from now.
$suppApplied = 0; $suppAdded = 0; $suppRemoved = 0; $driftSkipped = 0

$verified = New-Object System.Collections.Generic.List[object]
$changes  = New-Object System.Collections.Generic.List[object]
foreach ($row in $doc.comparison) {
  $kept = New-Object System.Collections.Generic.List[object]
  $ord = 0
  foreach ($s in $row.stores) {
    $v = $vlook[("$($row.id)|$($s.store)")]
    $cellNorm = Get-VerdictNorm ([string]$s.item)
    $suppKey = ([string]$row.id) + '|' + ([string]$s.store) + '|' + $cellNorm
    if ($v -and ($v.keep -eq $false)) {
      $judged = Get-VerdictIdentity $v
      if ($judged -and ((Get-VerdictNorm $judged) -ne $cellNorm)) {
        # THE DRIFT GATE. The verdict names a product and the cell no longer holds it - the board was rebuilt
        # between judgment and apply. Dropping the current occupant would delete a product NOBODY judged.
        $driftSkipped++
        $changes.Add("DRIFT   $($row.commodity): $($s.store) verdict judged `"$judged`" but the cell now holds `"$($s.item)`" - NOT dropped (re-judge if the new item is also wrong)")
      } else {
        if ($judged) {
          # identity confirmed -> this drop is PERMANENT from now on
          if (-not $supp.ContainsKey($suppKey)) {
            $supp[$suppKey] = [pscustomobject]@{ id = [string]$row.id; store = [string]$s.store; item_norm = $cellNorm; item = [string]$s.item; week = $week; reason = [string]$v.reason; source = 'apply-confirmed' }
            $suppDirty = $true; $suppAdded++
          }
        }
        $changes.Add("DROP    $($row.commodity): $($s.store) `"$($s.item)`" - $($v.reason)")
        continue
      }
    }
    if ($v -and ($v.keep -ne $false)) {
      # a human overturn beats persistence: an explicit KEEP for this exact item removes its suppression
      $judged = Get-VerdictIdentity $v
      if ($judged -and ((Get-VerdictNorm $judged) -eq $cellNorm) -and $supp.ContainsKey($suppKey)) {
        $supp.Remove($suppKey); $suppDirty = $true; $suppRemoved++
        $changes.Add("UNSUPPRESS $($row.commodity): $($s.store) `"$($s.item)`" - keep verdict overturns the standing suppression")
      }
    }
    if ($supp.ContainsKey($suppKey)) {
      # VERDICT PERSISTENCE: judged wrong in some past week, still the same product -> still wrong.
      $suppApplied++
      $changes.Add("SUPPRESS $($row.commodity): $($s.store) `"$($s.item)`" - standing DROP from $($supp[$suppKey].week): $($supp[$suppKey].reason)")
      continue
    }
    $ann = if ($v) { $v.annotation } else { $null }
    if ($ann) { $changes.Add("NOTE    $($row.commodity): $($s.store) - $ann") }
    # keep ad + note: SaleBadge's flash-window parser reads them, and publish PREFERS this verified board -
    # dropping them silently killed flash-date badges whenever the verified board was the build input.
    $kept.Add([pscustomobject]@{ store=$s.store; per_unit=[double]$s.per_unit; unit=$s.unit; type=$s.type; bulk=[bool]$s.bulk; membership=[bool]$s.membership; item=$s.item; ad=$s.ad; note=$s.note; size=$s.size; annotation=$ann; ord=$ord }); $ord++
  }
  if ($kept.Count -lt $MinStores) { $changes.Add("REMOVE  $($row.commodity): only $($kept.Count) confirmed store(s) left"); continue }
  $ranked = @($kept.ToArray() | Sort-Object per_unit, ord)   # stable: ties keep original ranking order
  if ($ranked[0].store -ne $row.cheapest_store) { $changes.Add("WINNER  $($row.commodity): $($row.cheapest_store) `$$('{0:N2}' -f $row.cheapest_price) -> $($ranked[0].store) `$$('{0:N2}' -f $ranked[0].per_unit)") }
  $nm = @($ranked | Where-Object { -not $_.membership } | Select-Object -First 1)
  $verified.Add([pscustomobject]@{
    commodity=$row.commodity; id=$row.id; unit=$row.unit
    cheapest_store=$ranked[0].store; cheapest_price=$ranked[0].per_unit; cheapest_type=$ranked[0].type; cheapest_annotation=$ranked[0].annotation
    nomem_store=$(if($nm.Count){$nm[0].store}else{$null}); nomem_price=$(if($nm.Count){$nm[0].per_unit}else{$null}); nomem_annotation=$(if($nm.Count){$nm[0].annotation}else{$null})
    stores=$ranked
  })
}

$out = [ordered]@{ built_at=(Get-Date).ToString('s'); week_of=$week; verified_from=$CompareFile; commodities=$verified.Count; comparison=$verified.ToArray() }
$file = if ($OutFile) { if ([IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path $OutDir $OutFile } } else { Join-Path $OutDir ("verified-"+$week+".json") }
($out | ConvertTo-Json -Depth 8) | Set-Content $file -Encoding UTF8

# persist suppression changes atomically (tmp + move): verify-apply runs 2-3x per publish cycle and the
# dedupe by key makes re-runs no-ops, so the file only churns when a judgment actually changed.
if ($suppDirty) {
  $sObj = [ordered]@{
    readme = "Every confirmed DROP verdict ever made, keyed (id, store, normalised item), applied by verify-apply on EVERY run regardless of which week produced it. Exists because only the current week's verdict file used to be read, so the same wrong products returned as soon as their week rolled over - 18 previously-dropped cells were live again on 2026-07-29, three as crowns. Entries are added automatically when a drop's item identity is CONFIRMED (verdict item field or reason quote matches the cell), and removed automatically when a later keep verdict overturns one. Do not hand-edit item_norm; it is Get-VerdictNorm's output (verdict-lib.ps1)."
    updated = (Get-Date).ToString('s')
    suppressions = @($supp.Values | Sort-Object id, store, item_norm)
  }
  $tmpS = $SuppressionsFile + '.tmp'
  ($sObj | ConvertTo-Json -Depth 5) | Set-Content $tmpS -Encoding UTF8
  Move-Item $tmpS $SuppressionsFile -Force
}

Write-Output ("VERIFIED  week $week   commodities kept: " + $verified.Count + " / " + @($doc.comparison).Count)
Write-Output ("suppressions: " + $suppApplied + " standing drop(s) applied, " + $suppAdded + " newly recorded, " + $suppRemoved + " overturned by keep verdicts, " + $driftSkipped + " drifted verdict(s) NOT applied (cell holds a different product than was judged)")
Write-Output ("=" * 70)
if ($changes.Count -gt 0) { foreach ($c in $changes.ToArray()) { Write-Output $c } } else { Write-Output "no changes - every published winner passed semantic verification" }
Write-Output ""
Write-Output ("Saved: " + $file)
# No exit statement anywhere in this script - it falls off the end on its only path, so the marker goes here.
Write-GuardComplete -Name 'verify-apply'
