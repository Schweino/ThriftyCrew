<#
  new-commodity.ps1 - add ONE new commodity to commodities.json by cloning a sibling's exclude boilerplate.

  WHY CLONE THE EXCLUDES. Every commodity carries an 80-to-170 pattern exclude list that is almost entirely
  shared boilerplate: pet food, baby food, cleaning products, candy, supplements. That list is the thing
  standing between a commodity and the cat-food-as-salmon class. Hand-writing a short one for a new commodity
  is how a new row arrives already defenceless, so this script refuses to create an entry without naming an
  existing commodity to inherit that armour from.

  Same safety contract as add-commodity-rule.ps1: text surgery, not a whole-file reserialize, and after
  writing it re-parses and proves every PRE-EXISTING entry is byte-identical. Entry count must go up by
  exactly one. Anything else is a hard failure and nothing is written.

  Placement matters: matching is FIRST-MATCH-WINS, so a broad new commodity inserted early can silently
  steal cells from a narrower one that used to win them (that is the documented board-match-collision).
  New entries therefore go immediately AFTER the clone source, which keeps canned-* and frozen-* grouped
  below the fresh produce rows where they belong.

  Usage:
    new-commodity.ps1 -Id canned-asparagus -Label "Canned Asparagus" -Unit oz -BandMin 0.06 -BandMax 0.7 `
      -CloneExcludeFrom canned-peaches -Include 'asparagus\s+cut\s+spears','cut\s+asparagus\s+spears'

  Exit 0 = written. Exit 1 = refused, nothing written.
#>
param(
  [Parameter(Mandatory = $true)][string]$Id,
  [Parameter(Mandatory = $true)][string]$Label,
  [Parameter(Mandatory = $true)][string]$Unit,
  [Parameter(Mandatory = $true)][string[]]$Include,
  [Parameter(Mandatory = $true)][string]$CloneExcludeFrom,
  [double]$BandMin = 0,
  [double]$BandMax = 0,
  [string[]]$ExtraExclude = @(),
  [string]$File = '',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $File) { $File = Join-Path $root 'commodities.json' }
function Say([string]$s) { Write-Output $s }
function Die([string]$s) { Write-Output ('new-commodity: ' + $s); exit 1 }

if (-not (Test-Path $File)) { Die ('file not found: ' + $File) }
foreach ($p in ($Include + $ExtraExclude)) {
  try { [void][regex]::new($p) } catch { Die ('not a valid regex, refusing: ' + $p) }
}

$raw = [IO.File]::ReadAllText($File)
$before = $raw | ConvertFrom-Json
# TWO FILE SHAPES, ONE TOOL (2026-08-27). commodities.json is a bare top-level array; the RECIPE
# namespace file, recipe-commodities.json, nests its entries under a `commodities` key beside a readme
# and a global_exclude. This script only understood the first, so it answered "clone source not found"
# for every id in the recipe namespace - which is where form-splits like boneless-skinless-chicken-thigh
# actually live, and therefore where the commodity-registrar sends them. A registrar ruling that can be
# approved but not executed is a ruling that quietly does not happen: boneless-pork-chops sat approved
# and unminted from 2026-08-26 until this was found, while a recipe priced its main protein on the
# bone-in id it was ruled off.
#
# ONLY THE ENTRY LIST MOVES. The text surgery below is shape-agnostic already - it finds the clone
# source's own braces and inserts after them - and the proof compares parsed entry against parsed entry.
$Entries = { param($doc) if ($null -ne $doc -and $doc.PSObject.Properties.Name -contains 'commodities') { return @($doc.commodities) } return @($doc) }
$bList = New-Object System.Collections.ArrayList; foreach ($x in (& $Entries $before)) { [void]$bList.Add($x) }
if ($bList | Where-Object { [string]$_.id -eq $Id }) { Die ('a commodity with id ''' + $Id + ''' already exists.') }
$src = $bList | Where-Object { [string]$_.id -eq $CloneExcludeFrom }
if ($null -eq $src) { Die ('clone source ''' + $CloneExcludeFrom + ''' not found.') }

# ---- build the new entry, property order matching the file ------------------------------------------------
$obj = [ordered]@{ id = $Id; label = $Label; unit = $Unit }
if ($BandMin -gt 0) { $obj['band_min'] = $BandMin }
if ($BandMax -gt 0) { $obj['band_max'] = $BandMax }
$obj['include'] = @($Include)
$obj['exclude'] = @(@($ExtraExclude) + @($src.exclude))
$blockJson = ([pscustomobject]$obj | ConvertTo-Json -Depth 6)
# indent the whole object by 4 to sit inside the top-level array
# INDENT TO MATCH THE CLONE SOURCE'S OWN LINE. Hardcoding 4 put a recipe-namespace entry (6) at the
# wrong depth - valid JSON, unreadable diff, and the next hand-edit lands in the wrong place.
$srcLineStart = $raw.LastIndexOf("`n", $m.Index) + 1
$srcIndent = ''
for ($ci = $srcLineStart; $ci -lt $raw.Length -and $raw[$ci] -eq ' '; $ci++) { $srcIndent += ' ' }
if ($srcIndent.Length -lt 2) { $srcIndent = '    ' } else { $srcIndent = $srcIndent.Substring(0, $srcIndent.Length - 2) }
$indented = (($blockJson -split "`r?`n" | ForEach-Object { $srcIndent + $_ }) -join "`r`n")

# ---- insert immediately after the clone source's entry ----------------------------------------------------
$idPat = '"id":\s*"' + [regex]::Escape($CloneExcludeFrom) + '"'
if ([regex]::Matches($raw, $idPat).Count -ne 1) { Die ('clone source id appears ' + [regex]::Matches($raw, $idPat).Count + ' times in raw text; refusing.') }
$m = [regex]::Match($raw, $idPat)
$start = $raw.LastIndexOf('{', $m.Index)
$depth = 0; $end = -1
for ($i = $start; $i -lt $raw.Length; $i++) {
  $ch = $raw[$i]
  if ($ch -eq '"') { $i++; while ($i -lt $raw.Length -and $raw[$i] -ne '"') { if ($raw[$i] -eq '\') { $i++ }; $i++ }; continue }
  if ($ch -eq '{') { $depth++ } elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
}
if ($end -lt 0) { Die 'could not find the end of the clone source entry.' }
$newRaw = $raw.Substring(0, $end + 1) + ",`r`n" + $indented + $raw.Substring($end + 1)

# ---- prove it ---------------------------------------------------------------------------------------------
$after = $null
try { $after = $newRaw | ConvertFrom-Json } catch { Die ('edit produced invalid JSON, nothing written: ' + $_.Exception.Message) }
$aList = New-Object System.Collections.ArrayList; foreach ($x in (& $Entries $after)) { [void]$aList.Add($x) }
if ($aList.Count -ne $bList.Count + 1) { Die ('entry count went ' + $bList.Count + ' -> ' + $aList.Count + ', expected +1; refusing.') }
$newIdx = -1
for ($i = 0; $i -lt $aList.Count; $i++) { if ([string]$aList[$i].id -eq $Id) { $newIdx = $i; break } }
if ($newIdx -lt 0) { Die 'the new entry is not in the parsed result; refusing.' }
$collateral = New-Object System.Collections.ArrayList
$j = 0
for ($i = 0; $i -lt $aList.Count; $i++) {
  if ($i -eq $newIdx) { continue }
  $bs = ($bList[$j] | ConvertTo-Json -Depth 8 -Compress)
  $as = ($aList[$i] | ConvertTo-Json -Depth 8 -Compress)
  if ($bs -ne $as) { [void]$collateral.Add([string]$bList[$j].id) }
  $j++
}
if ($collateral.Count -gt 0) { Die ('COLLATERAL DAMAGE: ' + $collateral.Count + ' existing commodit(ies) changed (' + (($collateral | Select-Object -First 5) -join ', ') + '). Nothing written.') }

# THE CARVE-OUT TRAP (added 2026-08-21, after it bit four of eleven new commodities in one sitting).
# Cloning the parent's ~100 exclude patterns is what stops a new commodity arriving defenceless. But
# when the new id is carved OUT of that parent, the inherited armour blocks the child - because the
# parent's exclude exists precisely to keep this food away from it:
#     almond-flour       inherited `almond`         from flour          (flour excludes almond)
#     fresh-oregano      inherited `\bfresh\b`      from dried-oregano
#     bacon-bits         inherited `bits`           from bacon
#     yellow-bell-pepper inherited `yellow\s+bell`  from bell-peppers
# Every one matched NOTHING and produced zero candidates, silently - the commodity existed, looked
# healthy in the file, and could never win a cell. Nothing downstream can distinguish that from "no
# store carries it", which is why it has to be caught here.
#
# The test is deliberately narrow: does an inherited exclude kill an include pattern's OWN literal?
# It builds a sample from each include pattern by stripping the regex metacharacters, then asks
# whether the entry would refuse its own name. It cannot catch every case - a pattern too exotic to
# de-regex is skipped rather than guessed at - but it catches the shape that actually happens.
$selfBlocked = New-Object System.Collections.ArrayList
foreach ($inc in @($Include)) {
  # Turn `almond\s+flour` into `almond flour`. If what is left still contains regex syntax, skip it.
  $sample = $inc -replace '\\s\+', ' ' -replace '\\s\*', ' ' -replace '\\b', ''
  if ($sample -match '[\\\[\]\(\)\|\?\*\+\{\}\^\$]') { continue }
  foreach ($ex in @($obj['exclude'])) {
    $hit = $false
    try { $hit = [regex]::IsMatch($sample, $ex, 'IgnoreCase') } catch { $hit = $false }
    if ($hit) {
      [void]$selfBlocked.Add(("include '" + $inc + "' is killed by inherited exclude '" + $ex + "'"))
      break
    }
  }
}
if ($selfBlocked.Count -gt 0) {
  Die ("SELF-BLOCKED: this entry would match NOTHING, because an exclude inherited from " + $CloneExcludeFrom +
       " cancels its own include. " + (($selfBlocked | Select-Object -First 3) -join '; ') +
       ". That is the carve-out trap: the parent excludes this food precisely because it belongs here instead. " +
       "Re-run with -ExtraExclude unchanged and then drop the offending pattern with " +
       "add-commodity-rule.ps1 -Id " + $Id + " -RemoveExclude '<pattern>', or clone the excludes from a " +
       "different sibling. Nothing written.")
}

Say ('new-commodity: ' + $Id + ' [' + $Unit + '] inserted at index ' + $newIdx + ', right after ' + $CloneExcludeFrom)
Say ('    include: ' + (@($Include) -join ' | '))
Say ('    exclude: ' + @($obj['exclude']).Count + ' patterns (' + $ExtraExclude.Count + ' new + ' + @($src.exclude).Count + ' inherited from ' + $CloneExcludeFrom + ')')
Say ('    ' + $bList.Count + ' -> ' + $aList.Count + ' commodities, 0 collateral changes')
if ($DryRun) { Say '    DRY RUN - nothing written.'; exit 0 }
[IO.File]::WriteAllText($File, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
Say ('    wrote ' + $File)
exit 0
