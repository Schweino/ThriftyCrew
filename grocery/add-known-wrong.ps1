<#
  add-known-wrong.ps1 - the ONE COMMAND that moves a finding out of prose and into the publish path.

  The corpus's most damning fact is that audit findings lived as PROSE in .md files: honeydew was written up
  on 2026-07-29 with the store's own arithmetic and was STILL the published crown the next morning. A memory
  the pipeline cannot read is not a memory. This script is the intake: an auditor or an agent that has just
  adjudicated a (commodity, store, product) wrong runs one line, the ruling lands in known-wrong.json, and
  audit-known-wrong.ps1 - which guards.ps1 delegates to - refuses to publish that cell ever again.

  ADD (the normal case; -Name is optional, it is read off the current board):
    .\add-known-wrong.ps1 -Commodity salmon -Store Walmart -RuledBy "accuracy-agent" `
        -Evidence "Dry cat food. Held the salmon crown at 4.10/lb, 20.8% under the runner-up."

  ADD a product that is in a store FEED but has not reached a board yet:
    .\add-known-wrong.ps1 -Commodity coffee -Store Walmart -RuledBy me `
        -Name "Onyx Coffee Lab Salted Mocha Oat Milk Latte, 11 fl oz Can" -Evidence "RTD latte, not coffee."

  REVERSE a ruling that turns out to be wrong (the ONLY way an entry stops being enforced):
    .\add-known-wrong.ps1 -Reverse -Key "salmon|Walmart|blue-buffalo-cat-food" -RuledBy me `
        -Evidence "Walmart reused the id for a real salmon fillet; verified in store 2026-08-02."

  DELIBERATELY NOT SUPPORTED: deleting an entry, and editing a stored product name. Both are how a gate gets
  quietly made green. An entry leaves enforcement only by being REVERSED, on the record, with a named
  reviewer and a reason - and it stays in the file so the reversal itself is auditable.

  A typo'd commodity id or store name makes an entry PERMANENTLY UNFIRABLE, which is exactly the allowlist
  bug found 2026-07-30 (two entries justified by "the store does not carry the item" while the store carried
  it). So both are validated against commodities.json / stores.json before anything is written.

  After writing, this runs audit-known-wrong.ps1 and prints the verdict. A NEW finding is EXPECTED to turn
  the gate red: that is the point. Fix the commodity rule, re-run, and it goes green - and stays green.
#>
param(
  [string]$Commodity,
  [string]$Store,
  [string[]]$Name,
  [string]$ProductId,
  [string]$Evidence,
  [string]$RuledBy,
  [string]$Key,
  [string]$Verdict = 'wrong-product',
  [switch]$Reverse,
  [switch]$DryRun,
  [string]$Root,
  [string]$ListFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
if (-not $ListFile) { $ListFile = Join-Path $Root 'known-wrong.json' }
$outDir = Join-Path $Root 'out'

function Die([string]$m) { Write-Output ('add-known-wrong: ' + $m); exit 1 }

if (-not (Test-Path $ListFile)) { Die ("blocklist file not found: " + $ListFile) }
$raw = ((Get-Content $ListFile -Raw -Encoding UTF8) + '').Trim()
if ($raw.Length -eq 0) { Die ("blocklist file is empty: " + $ListFile + " - restore it from git before adding to it") }
$doc = $raw | ConvertFrom-Json
if ($null -eq $doc) { Die "blocklist file parsed to null" }
$entries = @()
if ($doc.PSObject.Properties.Name -contains 'entries') { $entries = @($doc.entries) }

if (-not $Evidence -or $Evidence.Trim().Length -lt 20) { Die "-Evidence is required and must actually say why (>= 20 chars). An entry without evidence is a rule nobody can review." }
if (-not $RuledBy) { Die "-RuledBy is required: every ruling names who made it." }

# ---------------------------------------------------------------- reverse
if ($Reverse) {
  if (-not $Key) { Die "-Reverse needs -Key (the exact key of the entry to reverse; run audit-known-wrong.ps1 to list them)" }
  $hit = $null
  foreach ($e in $entries) { if ([string]$e.key -eq $Key) { $hit = $e; break } }
  if ($null -eq $hit) { Die ("no entry with key '" + $Key + "'") }
  if ($hit.PSObject.Properties.Name -contains 'reversed_on' -and ([string]$hit.reversed_on).Trim()) { Die ("entry '" + $Key + "' is already reversed on " + [string]$hit.reversed_on) }
  $today = (Get-Date -Format 'yyyy-MM-dd')
  foreach ($p in @(@('reversed_on', $today), @('reversed_by', $RuledBy), @('reversal_reason', $Evidence.Trim()))) {
    if ($hit.PSObject.Properties.Name -contains $p[0]) { $hit.($p[0]) = $p[1] }
    else { Add-Member -InputObject $hit -MemberType NoteProperty -Name $p[0] -Value $p[1] }
  }
  Write-Output ("REVERSING " + $Key + " (by " + $RuledBy + ", " + $today + ")")
} else {
  # ---------------------------------------------------------------- add
  if (-not $Commodity) { Die "-Commodity is required" }
  if (-not $Store) { Die "-Store is required (exact name from stores.json, e.g. \"Baker's\", \"Sam's Club\", \"Family Fare\")" }

  # A typo here makes the entry permanently unfirable. Validate, do not guess.
  $cmF = Join-Path $Root 'commodities.json'
  if (Test-Path $cmF) {
    # assign FIRST: `@(Get-Content | ConvertFrom-Json)` does not unroll a bare top-level JSON array in PS 5.1
    $cmAll = Read-JsonFile $cmF
    $ids = @{}; foreach ($c in $cmAll) { if ($c -and $c.id) { $ids[[string]$c.id] = $true } }
    if ($ids.Count -ge 2 -and -not $ids.ContainsKey($Commodity)) { Die ("'" + $Commodity + "' is not a commodity id in commodities.json. An entry on a non-existent commodity can never fire.") }
  }
  $stF = Join-Path $Root 'stores.json'
  if (Test-Path $stF) {
    $names = @{}; foreach ($s in @((Read-JsonFile $stF).stores)) { if ($s -and $s.name) { $names[[string]$s.name] = [string]$s.regular_prefix } }
    if ($names.Count -ge 2 -and -not $names.ContainsKey($Store)) { Die ("'" + $Store + "' is not a store name in stores.json (" + (($names.Keys | Sort-Object) -join ', ') + ")") }
  }

  # -Name omitted: read the product the board is CURRENTLY publishing in that cell, so the ruling is
  # recorded against the exact spelling the pipeline produced rather than one a human retyped.
  $useNames = @($Name | Where-Object { ($_ + '').Trim() })
  $foundPid = ''
  $cmpF = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
  $boardItem = ''
  foreach ($f in $cmpF) {
    foreach ($r in @((Read-JsonFile $f.FullName).comparison)) {
      if ([string]$r.id -ne $Commodity) { continue }
      foreach ($s in $r.stores) {
        if ([string]$s.store -ne $Store) { continue }
        if ([string]$s.item) { $boardItem = [string]$s.item }
      }
    }
  }
  if ($useNames.Count -eq 0) {
    if (-not $boardItem) { Die ("no product name given and the newest board has no named " + $Store + " cell for '" + $Commodity + "'. Pass -Name with the exact product name from the store feed.") }
    $useNames = @($boardItem)
    Write-Output ("reading the product name off the current board: '" + $boardItem + "'")
  }

  # product_id, when the store publishes one: it lets the gate re-derive today's spelling after the
  # pipeline mangles the name (it has shipped one product three ways in four days)
  if (-not $ProductId) {
    $prefix = ''
    if (Test-Path $stF) { foreach ($s in @((Read-JsonFile $stF).stores)) { if ([string]$s.name -eq $Store) { $prefix = [string]$s.regular_prefix } } }
    if ($prefix) {
      $want = @{}; foreach ($n in $useNames) { $want[(($n + '') -replace '[^a-zA-Z0-9]', '').ToLower()] = $true }
      $rf = @(Get-ChildItem (Join-Path $outDir ('regular\' + $prefix + '-regular-*.json')) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
      foreach ($f in $rf) {
        foreach ($d in @((Read-JsonFile $f.FullName).deals)) {
          $k = (([string]$d.item) -replace '[^a-zA-Z0-9]', '').ToLower()
          if (-not $want.ContainsKey($k)) { continue }
          $p = @($d.PSObject.Properties.Name)
          if ($p -contains 'item_id' -and [string]$d.item_id) { $foundPid = [string]$d.item_id; break }
          if ($p -contains 'product_id' -and [string]$d.product_id) { $foundPid = [string]$d.product_id; break }
        }
      }
      if ($foundPid) { Write-Output ("resolved product id from the " + $Store + " feed: " + $foundPid) }
      else { Write-Output ("no product id available for this product at " + $Store + " - the normalized name is the only key (expected at Aldi, Sam's Club and Fareway)") }
    }
  } else { $foundPid = $ProductId }

  if (-not $Key) {
    $slug = ((($useNames[0] + '') -replace "'", '') -replace '[^a-zA-Z0-9]+', '-').ToLower().Trim('-')
    if ($slug.Length -gt 48) { $slug = $slug.Substring(0, 48).Trim('-') }
    $storeSlug = (($Store -replace "'", '') -replace '[^a-zA-Z0-9]+', '')
    $Key = $Commodity + '|' + $storeSlug + '|' + $slug
  }
  foreach ($e in $entries) { if ([string]$e.key -eq $Key) { Die ("an entry with key '" + $Key + "' already exists - pass a different -Key, or -Reverse it if the old ruling was wrong") } }

  $new = [ordered]@{
    key = $Key; commodity = $Commodity; store = $Store
    names = @($useNames); product_id = $foundPid
    verdict = $Verdict; evidence = $Evidence.Trim()
    seen_on_board = $(if ($boardItem) { 'yes - on the newest board when this ruling was made' } else { 'not on the newest board when this ruling was made' })
    ruled_on = (Get-Date -Format 'yyyy-MM-dd'); ruled_by = $RuledBy
    retire_when = 'ruling-reversed'
  }
  $entries = @(@($entries) + @([pscustomobject]$new))
  Write-Output ("ADDING " + $Key)
}

$doc.entries = @($entries)
$json = ($doc | ConvertTo-Json -Depth 12)
if ($DryRun) { Write-Output '--- DRY RUN, nothing written ---'; Write-Output $json; exit 0 }
# no-BOM UTF8: the file is pure ASCII by policy and several readers in this tree are BOM-sensitive
[IO.File]::WriteAllText($ListFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("wrote " + $ListFile + " (" + @($entries).Count + " entries)")

$auditor = Join-Path $Root 'audit-known-wrong.ps1'
if (-not (Test-Path $auditor)) { Write-Output 'audit-known-wrong.ps1 not found next to the list - run it manually'; exit 0 }
Write-Output ''
Write-Output '--- audit-known-wrong.ps1 ---'
& powershell -NoProfile -ExecutionPolicy Bypass -File $auditor -Root $Root -ListFile $ListFile
$rc = $LASTEXITCODE
Write-Output ''
if ($rc -eq 2) { Write-Output 'RED, as expected for a live finding: the wrong product is still on the board. Fix the commodity rule in commodities.json, re-run compare-deals, and this goes green - and stays green.' }
elseif ($rc -eq 3) { Write-Output 'BLIND: the blocklist could not be evaluated. The entry is recorded but nothing was proven - fix the blindness before trusting the result.' }
else { Write-Output 'GREEN: the ruling is recorded and the board does not price it. It is now a regression test.' }
exit 0

