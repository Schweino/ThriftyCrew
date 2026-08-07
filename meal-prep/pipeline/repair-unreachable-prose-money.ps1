<#
  repair-unreachable-prose-money.ps1 - fix a prose dollar figure that reanchor-moved-prose CANNOT reach.

  WHY THIS EXISTS (2026-08-07). reanchor-moved-prose.ps1 works by diff: it finds the PREVIOUS manifest value
  in the sentence and rewrites it to the new one. That is a deliberately conservative design - it only edits
  a number it can prove it put there. The consequence is a blind spot the script itself documents: "a figure
  that was already wrong before the move is unreachable by it and needs a hand fix." Nothing owned that hand
  fix, so 15 slow-cooker specs sat quoting a per-serving price their own stat abandoned - understating cost
  by up to $1.75 a bowl on live pages, while the gate reported them every single day and nothing acted.

  It is not a stale-price problem, it is a CONTRADICTION problem. Each of these pages says both

      portion_html       "...at roughly $2.00 a bowl."
      cost_closing_html  "About $3.58 a bowl (at everyday cost)..."

  in the same reader's-eye view. Whatever basis you believe, one of those two sentences is false, and the
  estate already decided which is authoritative: reanchor-all's invariant is that every dollar figure in a
  spec's reader-facing money fields equals that spec's own stat.cost_ps. This script enforces exactly that
  and nothing more.

  THE GATE, which is the whole design. A dollar figure is rewritten ONLY when its sentence is making a
  PER-SERVING claim - the number sits within a short window of "a bowl", "a burrito", "per serving", "each
  serving" or "a serving". Any other figure is left untouched, because these fields also legitimately carry
  batch totals and pantry one-offs ("about $23.20 one time"), and those are a different basis, not a defect.
  A spec whose figures are all outside that window is reported as UNREACHABLE and left completely alone: it
  needs a human, which is the honest outcome, not a guess.

  NO STAT, COST FIELD, GRAM FIGURE OR MACRO MOVES. Only the sentence, and only the dollar amount inside it.

  EDITS ARE KEY-SCOPED TEXT EDITS ON THE RAW FILE, never a parse-and-re-serialize. The prose carries \uXXXX
  escapes and re-serializing rewrites all of them (engine\README.md). Every write is verified two ways before
  it lands: the file must still parse, and every field except the ones named must be byte-identical.

  Read-only unless -Apply.
  Usage: .\repair-unreachable-prose-money.ps1 [-Slugs a,b] [-Apply] | -SelfTest
#>
param([string[]]$Slugs, [switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if ($Root) { $Root } else { Split-Path -Parent $here }

$script:FIELDS = @('intro_html','portion_html','cost_closing_html','upsell_html')

# A per-serving claim binds the money to the noun that FOLLOWS it: "$3.58 a bowl", "$2.98 per serving",
# "$1.87 a burrito". Looking forward and close is what makes this safe. The first draft searched a window on
# both sides for any serving noun, which its own fixture caught immediately: "Batch total: about $45.63
# across 14 servings" contains "servings", so the batch total qualified as a per-serving claim and the script
# would have rewritten $45.63 to $3.26 - inventing a fourteen-serving batch that costs the same as one bowl.
# The nouns are the ones the catalog actually uses (cost-render-lib derives 'burrito' for wrap recipes and
# 'bowl' otherwise). Written in this order so 'per serving' is reachable without 'a|each' in front of it.
$script:RX_SERVING_AFTER = '(?i)^[^.]{0,24}?\b(?:a|an|each|per)\s+(?:bowl|burrito|serving)\b'

function Test-PerServingClaim {
  param([string]$Text, [int]$MatchIndex, [int]$MatchLength)
  $tailStart = $MatchIndex + $MatchLength
  if ($tailStart -ge $Text.Length) { return $false }
  $tail = $Text.Substring($tailStart, [Math]::Min(40, $Text.Length - $tailStart))
  return ([regex]::IsMatch($tail, $script:RX_SERVING_AFTER))
}

# Rewrite every per-serving dollar figure in one field to $Target. Returns the new string (unchanged if the
# field holds no per-serving figure). Pure - takes and returns text, touches no file.
function Repair-FieldMoney {
  param([string]$Text, [string]$Target)
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $out = New-Object System.Text.StringBuilder
  $last = 0
  foreach ($m in [regex]::Matches($Text, '\$(\d+\.\d{2})')) {
    if ($m.Groups[1].Value -eq $Target) { continue }
    if (-not (Test-PerServingClaim -Text $Text -MatchIndex $m.Index -MatchLength $m.Length)) { continue }
    [void]$out.Append($Text.Substring($last, $m.Index - $last))
    [void]$out.Append('$' + $Target)
    $last = $m.Index + $m.Length
  }
  if ($last -eq 0) { return $Text }
  [void]$out.Append($Text.Substring($last))
  return $out.ToString()
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }

  # FROZEN FIXTURE: slow-cooker-butter-chicken-rice-bowls exactly as it shipped - the founding defect. The
  # page said $2.00 in one sentence and $3.58 in the next, and understated the true cost by $1.58 a bowl.
  $portion = 'Each of the 14 servings lands around 57g protein for about 610 calories, at roughly $2.00 a bowl.'
  $r = Repair-FieldMoney $portion '3.58'
  T 'MUST FIRE  the founding defect: a per-serving figure the prose-mover could not reach' `
    ($r -eq 'Each of the 14 servings lands around 57g protein for about 610 calories, at roughly $3.58 a bowl.') $r

  # CLEAN TWIN: the same sentence already correct. Must be returned byte-identical, not rebuilt.
  $ok = 'Each of the 14 servings lands around 57g protein for about 610 calories, at roughly $3.58 a bowl.'
  T 'CLEAN TWIN a sentence already quoting stat.cost_ps is untouched' ((Repair-FieldMoney $ok '3.58') -eq $ok) 'rewritten'

  # MUST NOT FIRE: a batch total is a different basis, not a defect. This is the gate that stops the script
  # from "fixing" $45.63 into $3.26 and inventing a batch that costs the same as one serving.
  $batch = 'Batch total: about $45.63 across 14 servings, so roughly $3.26 per bowl.'
  $rb = Repair-FieldMoney $batch '3.26'
  T 'MUST NOT FIRE a batch total is left alone even though it is not stat.cost_ps' `
    ($rb -eq $batch) $rb

  # MUST NOT FIRE: the empty-pantry one-off carries no serving noun near it.
  $pantry = 'Starting with an empty pantry? Add about $23.20 one time.'
  T 'MUST NOT FIRE a pantry one-off with no per-serving claim is left alone' ((Repair-FieldMoney $pantry '3.58') -eq $pantry) 'rewritten'

  # The burrito serving noun, since cost-render-lib derives it separately and a bowl-only regex would miss
  # all 29 burrito pages.
  $bur = 'That is about $1.87 a burrito.'
  T 'the burrito serving noun is recognised, not just bowl' ((Repair-FieldMoney $bur '2.05') -eq 'That is about $2.05 a burrito.') 'missed'

  # Two figures, one per-serving and one not, in a single field: only the per-serving one moves.
  $mixed = 'Batch total: about $45.63 across 14 servings. That is $2.00 a bowl.'
  $rm = Repair-FieldMoney $mixed '3.26'
  T 'a mixed field moves ONLY the per-serving figure' ($rm -eq 'Batch total: about $45.63 across 14 servings. That is $3.26 a bowl.') $rm

  # An empty field must not throw - turkey-pozole-rojo shipped five of them.
  T 'an empty field is returned unchanged, not thrown on' ((Repair-FieldMoney '' '3.58') -eq '') 'threw or changed'

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---- live run -------------------------------------------------------------------------------------------
$specDir = Join-Path $mp 'db\recipes'
$files = @(Get-ChildItem (Join-Path $specDir '*.json'))
if ($Slugs) { $files = @($files | Where-Object { $Slugs -contains $_.BaseName }) }

$changed = 0; $unreachable = @(); $rows = @()
foreach ($file in $files) {
  $raw = [IO.File]::ReadAllText($file.FullName)
  $spec = $raw | ConvertFrom-Json
  $target = [string]$spec.stat.cost_ps
  if (-not $target) { continue }

  # what disagrees at all, and of that, what this script is allowed to touch
  $edits = @()
  $stubborn = @()
  foreach ($fld in $script:FIELDS) {
    $cur = [string]$spec.$fld
    $new = Repair-FieldMoney $cur $target
    if ($new -ne $cur) { $edits += [pscustomobject]@{ field = $fld; old = $cur; new = $new } }
    else {
      foreach ($m in [regex]::Matches($cur, '\$(\d+\.\d{2})')) {
        if ($m.Groups[1].Value -ne $target) { $stubborn += ("{0} `${1}" -f $fld, $m.Groups[1].Value) }
      }
    }
  }
  if ($stubborn.Count) { $unreachable += [pscustomobject]@{ slug = $file.BaseName; detail = ($stubborn -join ', ') } }
  if (-not $edits.Count) { continue }

  $changed++
  foreach ($e in $edits) { $rows += [pscustomobject]@{ slug = $file.BaseName; field = $e.field; target = $target } }
  Write-Output ("{0}" -f $file.BaseName)
  foreach ($e in $edits) {
    Write-Output ("    {0}" -f $e.field)
    Write-Output ("      - {0}" -f $e.old)
    Write-Output ("      + {0}" -f $e.new)
  }

  if ($Apply) {
    # KEY-SCOPED TEXT EDIT. Locate this field's JSON string value in the RAW text and replace only the dollar
    # amounts inside it. Everything else in the file - including every \uXXXX escape the prose carries - is
    # copied through untouched, which a ConvertTo-Json round-trip would not do.
    $newRaw = $raw
    foreach ($e in $edits) {
      $esc = [regex]::Escape($e.field)
      $rx  = '("' + $esc + '"\s*:\s*")((?:[^"\\]|\\.)*)(")'
      $mm  = [regex]::Match($newRaw, $rx)
      if (-not $mm.Success) { throw ("could not locate key '{0}' in {1} - refusing to write" -f $e.field, $file.Name) }
      # operate on the ENCODED value: decode, repair, re-encode, so a < in the sentence is never split
      $encoded = $mm.Groups[2].Value
      $decoded = ($('"' + $encoded + '"') | ConvertFrom-Json)
      $repaired = Repair-FieldMoney $decoded $target
      $reencoded = (ConvertTo-Json $repaired -Compress)
      $reencoded = $reencoded.Substring(1, $reencoded.Length - 2)
      # Prove the RE-ENCODE is lossless by decoding it again and comparing to what we meant to write. (An
      # earlier draft compared the decode to itself, which is a tautology that would have passed on anything.)
      # This is the rule the 2026-08-07 prose disaster was missing: it rewrote 11 specs by regexing the raw
      # escaped text, where > put a letter in front of the number and broke every word boundary.
      $verify = $('"' + $reencoded + '"') | ConvertFrom-Json
      if ($verify -ne $repaired) { throw ("escape round-trip failed on {0}/{1} - refusing to write" -f $file.Name, $e.field) }
      $newRaw = $newRaw.Substring(0, $mm.Groups[2].Index) + $reencoded + $newRaw.Substring($mm.Groups[2].Index + $mm.Groups[2].Length)
    }
    # VERIFY BEFORE LANDING: still parses, and nothing except the named fields moved.
    $after = $null
    try { $after = $newRaw | ConvertFrom-Json } catch { throw ("write would produce unparseable JSON for {0} - aborted" -f $file.Name) }
    $touched = @($edits | ForEach-Object { $_.field })
    foreach ($prop in $spec.PSObject.Properties) {
      if ($touched -contains $prop.Name) { continue }
      $b = ($spec.$($prop.Name) | ConvertTo-Json -Depth 12 -Compress)
      $a = ($after.$($prop.Name) | ConvertTo-Json -Depth 12 -Compress)
      if ($b -ne $a) { throw ("collateral change in '{0}' of {1} - aborted" -f $prop.Name, $file.Name) }
    }
    [IO.File]::WriteAllText($file.FullName, $newRaw)
  }
}

Write-Output ''
Write-Output ("{0} spec(s) with a reachable per-serving contradiction{1}" -f $changed, $(if ($Apply) { ' - APPLIED' } else { ' (dry run, pass -Apply to write)' }))
if ($unreachable.Count) {
  Write-Output ("{0} spec(s) hold a disagreeing figure this script will NOT touch - no per-serving claim near it, so a human decides:" -f $unreachable.Count)
  $unreachable | Select-Object -First 20 | ForEach-Object { Write-Output ("    {0}  {1}" -f $_.slug, $_.detail) }
}
exit 0
