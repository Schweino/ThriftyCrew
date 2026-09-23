# ingest-shape-lib.ps1 - what a per-row capture builder saw today, and the unit spellings it has PROVED.
#
# WHY THIS EXISTS (2026-09-22, queue 2026-09-22-20fecf, plan-2026-09-22-10). A builder that meets a store rendering
# it has never seen has two outputs: a refusal line in a rejects file nobody reads, and a smaller board. On
# 2026-09-21 Sam's printed 52 unit prices per "fluid ounce (us)" and every one was refused as an unknown unit; the
# first reader of that change was a person, after the board shipped. ops/rehearse-chain.ps1 runs -NoPull, so it
# cannot reach this class by construction: only same-morning data can.
#
# THREE THINGS LIVE HERE, and only these, because the builders dot-source this file:
#   Get-RejectReasonKey      one reason string -> the key a day is compared on (numbers to #, a quoted spelling KEPT)
#   Write-IngestShape        a builder's one call per build: rows in, rows out, rejects by reason key
#   Resolve-UnitAlias        a builder's fallback when its own unit table has no answer: a spelling
#                            audit-ingest-shape.ps1 PROVED from the store's own price arithmetic
# THE PROOF ITSELF LIVES IN audit-ingest-shape.ps1, NOT HERE. It needs walmart-row-lib's name parser, and
# walmart-row-lib defines Resolve-Unit and Build-Row: dot-sourced into build-sams-deals it would replace Sam's own
# functions of the same names. Keep this file free of any function a builder already defines.
#
# NO param() BLOCK: dot-sourced under PS 5.1 a param() block runs in the caller's scope.

$script:IngestShapeLibRoot = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }

# WHERE EACH PER-ROW BUILDER WRITES ITS REJECTS, and the field names it uses. Only three builders write a per-row
# rejects file (build-sams-deals, build-walmart-deals, build-aldi-regular); Family Fare, Hy-Vee, Baker's API and
# Fareway write none, which is this item's leaves_open (a). This is a table of BUILDER OUTPUTS, not a store list:
# the store registry is stores.json, and nothing here decides which stores exist.
$script:IngestShapeBuilders = [ordered]@{
  'sams'    = @{ Label = "Sam's Club"; Dir = 'sams'; Prefix = 'sams-rejects-';    Builder = 'build-sams-deals.ps1' }
  'walmart' = @{ Label = 'Walmart';    Dir = '';     Prefix = 'walmart-rejects-'; Builder = 'build-walmart-deals.ps1' }
  'aldi'    = @{ Label = 'Aldi';       Dir = '';     Prefix = 'aldi-rejects-';    Builder = 'build-aldi-regular.ps1' }
}

function Get-RejectReasonKey([string]$Reason) {
  # Lower case, every number outside a quoted span to '#', whitespace collapsed. A QUOTED span is kept verbatim
  # (lower-cased only): 'unknown unit "fluid ounce (us)"' is the signal, and '#' inside it would merge spellings.
  $t = ('' + $Reason).ToLowerInvariant()
  $parts = [regex]::Split($t, '("[^"]*")')
  $sb = New-Object System.Text.StringBuilder
  foreach ($p in $parts) {
    if ($p.Length -ge 2 -and $p.StartsWith('"') -and $p.EndsWith('"')) { [void]$sb.Append($p) }
    else { [void]$sb.Append(($p -replace '\d+(?:[.,]\d+)*', '#')) }
  }
  return (($sb.ToString() -replace '\s+', ' ').Trim())
}

function Get-RejectUnitSpelling([string]$Reason) {
  # The spelling a builder refused as a unit, exactly as the store printed it; $null for any other reason.
  $m = [regex]::Match(('' + $Reason), '^unknown unit "(.*)"$')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function ConvertTo-IngestRejectRow($r) {
  # The three builders spell their reject rows two ways: Sam's and Walmart {name, lp, up, reason}; Aldi {item, why}.
  $isAldi = ($null -ne $r.PSObject.Properties['why']) -and ($null -eq $r.PSObject.Properties['reason'])
  if ($isAldi) { return [pscustomobject]@{ name = [string]$r.item; lp = ''; up = ''; reason = [string]$r.why } }
  return [pscustomobject]@{ name = [string]$r.name; lp = [string]$r.lp; up = [string]$r.up; reason = [string]$r.reason }
}

function Write-IngestShape {
  # One call per build, after the rejects file. Writes out\ingest-shape\<store>-<date>.json (gitignored): the
  # store's shape today, so tomorrow's reader does not have to re-parse a 12,000-row rejects file to learn it.
  # NEVER FATAL to the caller: every builder wraps this in try/catch, because a builder that dies after writing
  # its rows loses the capture, and this record is a convenience beside the rejects file, not a replacement.
  param([Parameter(Mandatory = $true)][string]$Store, [Parameter(Mandatory = $true)][string]$Date,
        [int]$RowsIn, [int]$RowsOut, $Rejects, [string]$OutRoot = '')
  if (-not $OutRoot) { $OutRoot = Join-Path $script:IngestShapeLibRoot 'out' }
  $byKey = [ordered]@{}; $spell = [ordered]@{}
  foreach ($raw in @($Rejects)) {
    if ($null -eq $raw) { continue }
    $r = ConvertTo-IngestRejectRow $raw
    $k = Get-RejectReasonKey $r.reason
    if ($byKey.Contains($k)) { $byKey[$k] = [int]$byKey[$k] + 1 } else { $byKey[$k] = 1 }
    $s = Get-RejectUnitSpelling $r.reason
    if ($null -ne $s) { if ($spell.Contains($s)) { $spell[$s] = [int]$spell[$s] + 1 } else { $spell[$s] = 1 } }
  }
  $dir = Join-Path $OutRoot 'ingest-shape'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $path = Join-Path $dir ("{0}-{1}.json" -f $Store, $Date)
  $doc = [ordered]@{ store = $Store; date = $Date; rows_in = $RowsIn; rows_out = $RowsOut
                     rejects = @($Rejects).Count; rejects_by_reason = $byKey; unknown_unit_spellings = $spell }
  [IO.File]::WriteAllText($path, (($doc | ConvertTo-Json -Depth 5) + "`n"), (New-Object Text.UTF8Encoding($false)))
  return $path
}

$script:UnitAliasCache = @{}
# A self-test points this at a temp file so a builder's fallback can be driven without touching the live ledger.
$script:UnitAliasDefaultFile = ''
function Get-UnitAliasDoc([string]$AliasFile = '') {
  if (-not $AliasFile) { $AliasFile = if ($script:UnitAliasDefaultFile) { $script:UnitAliasDefaultFile } else { Join-Path $script:IngestShapeLibRoot 'unit-aliases.json' } }
  $full = [IO.Path]::GetFullPath($AliasFile)
  if ($script:UnitAliasCache.ContainsKey($full)) { return $script:UnitAliasCache[$full] }
  $doc = $null
  if (Test-Path -LiteralPath $full) {
    $doc = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8) | ConvertFrom-Json
  }
  $script:UnitAliasCache[$full] = $doc
  return $doc
}

function Resolve-UnitAlias {
  # A builder's FALLBACK, asked only when its own Resolve-Unit returned nothing. Returns @{tok; unit} in the
  # builders' own vocabulary for a spelling audit-ingest-shape PROVED for THIS store, else $null. A spelling
  # proved at one store is not admitted at another: the proof is that store's own arithmetic.
  # An unreadable alias file answers $null (the builder refuses the row exactly as it did before this file).
  param([Parameter(Mandatory = $true)][string]$Store, [string]$Spelling, [string]$AliasFile = '')
  if (-not $Spelling) { return $null }
  try { $doc = Get-UnitAliasDoc $AliasFile } catch { return $null }
  if ($null -eq $doc -or $null -eq $doc.PSObject.Properties['stores']) { return $null }
  $st = $doc.stores.PSObject.Properties[$Store]
  if ($null -eq $st) { return $null }
  $key = $Spelling.Trim().ToLowerInvariant()
  foreach ($p in $st.Value.PSObject.Properties) {
    if ([string]::Equals($p.Name.ToLowerInvariant(), $key, [StringComparison]::Ordinal)) {
      if ($p.Value.tok -and $p.Value.unit) { return @{ tok = [string]$p.Value.tok; unit = [string]$p.Value.unit } }
    }
  }
  return $null
}
