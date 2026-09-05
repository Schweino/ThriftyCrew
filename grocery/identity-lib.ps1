<#
  identity-lib.ps1 - THE product identity table: its key, its rules hash, and its file format.

  WHAT THIS IS. PLAN-product-identity-2026-08-22.md step 1. compare-deals.ps1 already computes, for every
  captured product, which commodity owns it. That answer was thrown away at process exit and recomputed by
  twenty other scripts, each with its own copy of the rule. This library is where the answer is WRITTEN
  DOWN, so everything downstream is a lookup instead of a twenty-first copy.

  THE KEY IS (store, product_id | name_key, NAMESPACE). The namespace is not decoration: graph/schema.md
  keeps the `staple` and `recipe` commodity namespaces separate on purpose (staple `ground-turkey` and
  recipe `93-7-ground-turkey` are different purchases), and recipe-overlay.ps1 runs the engine a SECOND
  time over recipe-commodities.json. One SKU therefore legitimately carries one assignment per namespace
  and they differ. A table keyed on the product alone would overwrite the staple answer with the recipe
  answer every single run - PLAN section 10.1.

  ONE FILE PER (NAMESPACE, STORE), NOT PER STORE. The plan sketches graph/identity/<store>.jsonl. It
  cannot be that, and the reason is section 10.12's own resolution: the truth file holds ONE CURRENT ROW
  per key and is REWRITTEN WHOLE (append-only plus a full rematch on every rule change would have written
  1.6 million lines on 2026-08-21 alone). The two namespaces are produced by two separate PROCESSES minutes
  apart, so a whole-file rewrite by the staple run would delete every recipe row and vice versa. Splitting
  the path by namespace is what makes "rewrite the whole file" safe. Rows still carry `namespace`, so a
  reader that globs all of graph/identity/**/*.jsonl needs no path knowledge.

  HISTORY IS GIT. The file is tracked and sorted by key, so an assignment change is a commit diff and the
  previous state of any row is `git show HEAD:graph/identity/<ns>/<store>.jsonl`. On a quiet day the
  rewrite produces identical bytes and Save-IdentityTable does not touch the file at all, so nothing is
  committed and no diff is invented. RULINGS are the append-only half and do NOT live here (section 10.13);
  they are joined at read time in step 2.

  PROVENANCE. graph/schema.md commitment 1 says record_provenance() is the ONLY minting path, and it is
  Python. PowerShell must therefore not invent provenance ids. What this library writes instead is a
  per-namespace _manifest.json naming the run that produced the files (rules hash, board date, built_at,
  per-store counts); graph/import/import_all.py mints one provenance id per file it imports, exactly as
  every other importer does. Nothing here claims an id it did not mint.

  Usage:
      . identity-lib.ps1
      $h = Get-IdentityRulesHash -GroceryRoot $root
      $prev = Read-IdentityTable -Root $repo -Namespace 'staple' -Store "Baker's"
      Save-IdentityTable -Root $repo -Namespace 'staple' -Store "Baker's" -Rows $rows -RulesHash $h
#>

# ---------------------------------------------------------------- where the table lives
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage

function Get-IdentityRoot {
  <# repo\graph\identity - resolved from the GROCERY directory, which is what every caller has. #>
  param([Parameter(Mandatory)][string]$GroceryRoot)
  return (Join-Path (Split-Path $GroceryRoot -Parent) 'graph\identity')
}

function Get-IdentityStoreSlug {
  <#
    A store name is a filename here, so it has to survive apostrophes and spaces: "Sam's Club" ->
    sams-club, "Hy-Vee" -> hy-vee, "Family Fare" -> family-fare. Apostrophes are DELETED rather than
    turned into separators, matching known-wrong-lib's KwNorm, so "Baker's" folds to bakers and not to
    baker-s. The row carries the real store string; this is only the path.
  #>
  param([string]$Store)
  $s = ('' + $Store)
  $s = $s.Replace([string][char]0x2019, "'").Replace([string][char]0x2018, "'")
  $s = $s.ToLower() -replace "'", ''
  $s = $s -replace '[^a-z0-9]+', '-'
  return $s.Trim('-')
}

function Get-IdentityTablePath {
  param([Parameter(Mandatory)][string]$GroceryRoot, [Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Store)
  return (Join-Path (Join-Path (Get-IdentityRoot -GroceryRoot $GroceryRoot) $Namespace) ((Get-IdentityStoreSlug $Store) + '.jsonl'))
}

# ---------------------------------------------------------------- the rules hash
function Get-IdentityRulesHash {
  <#
    SHA-256 over everything that can change an assignment. Same hash => a stored row is still the answer
    the rules would give today; different hash => every derived row is stale by definition.

    THE FILES ARE HASHED AS THEY SIT ON DISK, WHICH IS THE POST-BAKE FORM (section 10.4).
    apply-category-excludes.ps1 BAKES category-excludes.json into commodities.json, so hashing the source
    of that bake instead of its output would call a re-baked catalog unchanged. commodities.json on disk
    is what the engine reads, so hashing it is hashing what actually decided.

    product-classes.json is already in the input list although step 4 has not created it yet: the file is
    hashed if present and ignored if not. Section 10.16 says a class edit that is not hashed would leave
    stale derived rows behind a matching hash, and the cheapest time to close that is before the file
    exists.

    $GLOBAL_EXCLUDE lives in compare-deals.ps1 source, not in a data file, so its BLOCK TEXT is hashed.
    Extraction failing is a THROW, never a silently different hash: a hash computed over three of four
    inputs would quietly bless rows a global-exclude edit had already invalidated.
  #>
  param([Parameter(Mandatory)][string]$GroceryRoot)
  $sha = New-Object System.Security.Cryptography.SHA256Managed
  $parts = New-Object System.Collections.Generic.List[byte]
  # LINE ENDINGS ARE NORMALISED OUT BEFORE HASHING. git checks these files out CRLF on Windows and LF in
  # the cloud clone, so a byte hash would make the same rules produce two different hashes on two
  # machines - and the whole table would read as stale wherever it was not built. Only CRLF pairs are
  # folded; a lone CR (which no rule file contains) is left alone rather than silently deleted.
  function LfBytes([byte[]]$b) {
    $o = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $b.Length; $i++) {
      if ($b[$i] -eq 13 -and ($i + 1) -lt $b.Length -and $b[$i + 1] -eq 10) { continue }
      $o.Add($b[$i])
    }
    # `,` ON THE RETURN. Without it PowerShell unrolls the Byte[] through the output pipeline and the
    # caller receives an Object[] that List[byte].AddRange refuses - the same trap the file-read above
    # documents, one layer up. Get-MatchTexts uses this idiom for the same reason.
    return , $o.ToArray()
  }
  foreach ($f in @('commodities.json', 'recipe-commodities.json', 'category-excludes.json', 'product-classes.json')) {
    $p = Join-Path $GroceryRoot $f
    # A PLAIN if STATEMENT, not an if EXPRESSION, and that is not style. In PS 5.1 the value of an
    # if/else statement travels through the output pipeline: a Byte[] comes back unrolled and re-boxed
    # as Object[] (List[byte].AddRange then refuses it), and an EMPTY array comes back as $null
    # (AddRange then throws "Value cannot be null"). Both were measured here, in that order, on the
    # first two emission runs. Assigning straight from the method call keeps the real Byte[].
    $bytes = New-Object byte[] 0
    if (Test-Path $p) { $bytes = LfBytes ([IO.File]::ReadAllBytes($p)) }
    # the NAME goes in too, so "file absent" and "file empty" cannot hash the same as each other
    $parts.AddRange([Text.Encoding]::UTF8.GetBytes($f + ':' + $bytes.Length + ':'))
    $parts.AddRange($bytes)
  }
  $cdPath = Join-Path $GroceryRoot 'compare-deals.ps1'
  $src = [IO.File]::ReadAllText($cdPath)
  # the same two anchors test-match-lib.ps1 extracts between, so the two cannot disagree about where the
  # global list starts and ends
  $a = $src.IndexOf('$GLOBAL_EXCLUDE = @(')
  $b = $src.IndexOf('# ---------------------------------------------------------------- -Explain')
  if ($a -lt 0 -or $b -le $a) {
    throw 'identity-lib: could not locate the $GLOBAL_EXCLUDE block in compare-deals.ps1. The rules hash would be computed over an incomplete rule set, which would mark stale rows fresh. Fix the anchors (test-match-lib.ps1 uses the same two) rather than letting this pass.'
  }
  $parts.AddRange([Text.Encoding]::UTF8.GetBytes('global_exclude:'))
  # the extra parens are load-bearing: a bare command call is not an expression, so it cannot sit
  # directly in a method argument list
  $gexBytes = LfBytes ([Text.Encoding]::UTF8.GetBytes($src.Substring($a, $b - $a)))
  $parts.AddRange([byte[]]$gexBytes)
  return [BitConverter]::ToString($sha.ComputeHash($parts.ToArray())).Replace('-', '').ToLower()
}

# ---------------------------------------------------------------- the product key
function Get-IdentityKey {
  <#
    The store's own product id when the capture row carries one, the normalised name otherwise.
    MEASURED 2026-08-22 on the current captures: Baker's product_id (7,289 rows), Hy-Vee product_id
    (1,554), Family Fare product_id (5,224), Walmart item_id (136). Aldi, Fareway, Sam's Club and the
    hunter-* files carry NO id field on the row at all, so those are name-keyed - and so is every ad row,
    which has no store id by nature and whose names change every cycle (section 10.14). That is expected
    churn, not instability.

    $NameKey is Get-MatchTexts' normalised variant - the exact string the include patterns were tested
    against - so the key cannot drift from what the rules saw (section 10.3).
  #>
  param([string]$ProductId, [Parameter(Mandatory)][string]$NameKey)
  # NOT $pid: that is a read-only AUTOMATIC variable in PowerShell (the process id), and assigning it
  # throws at RUNTIME while the file parses perfectly. Measured here on the third emission run.
  $sid = ('' + $ProductId).Trim()
  if ($sid) { return [pscustomobject]@{ key = $sid; key_kind = 'product_id' } }
  return [pscustomobject]@{ key = ('name:' + $NameKey); key_kind = 'name' }
}

# ---------------------------------------------------------------- read
function Read-IdentityTable {
  <#
    Returns a hashtable keyed "<key>" for ONE (namespace, store) file, or an EMPTY table when the file
    does not exist yet. A file that exists but holds an unparseable line is a THROW: a half-read table
    would silently look like "these rows are new" and rewrite every one of them.
  #>
  param([Parameter(Mandatory)][string]$GroceryRoot, [Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Store)
  $out = @{}
  $p = Get-IdentityTablePath -GroceryRoot $GroceryRoot -Namespace $Namespace -Store $Store
  if (-not (Test-Path $p)) { return $out }
  $lines = @([IO.File]::ReadAllLines($p) | Where-Object { $_ -and $_.Trim() })
  if (-not $lines.Count) { return $out }
  # ONE ConvertFrom-Json OVER THE WHOLE FILE, not one per line. Measured on the live 35,365-row table:
  # per-line parsing is the single largest cost in the emission block, and PS 5.1's cmdlet overhead is
  # what makes it so - the parse itself is fast. Wrapping the lines as one array costs a string join.
  $rows = $null
  try { $rows = ('[' + ($lines -join ',') + ']') | ConvertFrom-Json }
  catch { throw ("identity-lib: " + $p + " does not parse as JSONL - refusing to treat a damaged table as an empty one (which would silently re-match and rewrite every row): " + $_.Exception.Message) }
  foreach ($row in @($rows)) { $out[[string]$row.key] = $row }
  return $out
}

function Read-IdentityIndexByName {
  <#
    THE GATE'S LOOKUP. Every row across every store file of ONE namespace, keyed "<store>|<name_key>"
    -> commodity id. That is the join a board cell can actually make: a cell carries the store and the
    product NAME it priced, never the store's internal product id.

    PowerShell, not Python, and deliberately (section 10.8): this runs inside guards.ps1 on the ship path,
    and a keyed hashtable over ~40k rows is sub-second. Nothing puts a Python call in front of publish.

    Returns $null when the namespace directory does not exist at all - the caller must report that as
    BLIND, not as agreement (section 10.7: an empty table is "not populated yet", never a pass).
  #>
  param([Parameter(Mandatory)][string]$GroceryRoot, [Parameter(Mandatory)][string]$Namespace, [string]$RulesHash = '')
  $dir = Join-Path (Get-IdentityRoot -GroceryRoot $GroceryRoot) $Namespace
  if (-not (Test-Path $dir)) { return $null }
  $files = @(Get-ChildItem (Join-Path $dir '*.jsonl') -ErrorAction SilentlyContinue)
  if (-not $files.Count) { return $null }
  $idx = @{}
  $stale = 0
  $unreadable = 0
  foreach ($f in $files) {
    $lines = @([IO.File]::ReadAllLines($f.FullName) | Where-Object { $_ -and $_.Trim() })
    if (-not $lines.Count) { continue }
    $rows = $null
    # One parse per FILE. A file that will not parse is counted, never skipped in silence: the caller
    # reports it, because "the table could not be read" and "the table agrees" must not look the same.
    try { $rows = ('[' + ($lines -join ',') + ']') | ConvertFrom-Json } catch { $unreadable++; continue }
    foreach ($row in @($rows)) {
      # ONLY rows at the CURRENT hash are comparable. A row under an older hash is stale by definition,
      # not a disagreement (section 10.7), so it must not enter the index and must not be counted as one.
      if ($RulesHash -and [string]$row.rules_hash -ne $RulesHash) { $stale++; continue }
      $idx[([string]$row.store + '|' + [string]$row.name_key)] = $row
    }
  }
  return [pscustomobject]@{ rows = $idx; files = $files.Count; stale = $stale; unreadable = $unreadable }
}

# ---------------------------------------------------------------- write
function Save-IdentityTable {
  <#
    ONE CURRENT ROW PER KEY, SORTED BY KEY, WRITTEN ATOMICALLY, AND ONLY WHEN THE BYTES CHANGE.

    Sorted so a commit diff is the assignment change and nothing else. Atomic (temp + re-parse + move)
    because compare-deals is also run ad hoc and a torn 40k-line write is the 13 MB price-history tear
    of 2026-08-22 with a different filename (section 10.9). Unchanged-bytes short-circuit because the
    daily churn is 0-14 names per store: a rewrite that produced identical content would still update
    the mtime and, worse, invite a reader to believe something moved.

    Returns what happened, so the caller can log it rather than assert it.
  #>
  param(
    [Parameter(Mandatory)][string]$GroceryRoot,
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$Store,
    [Parameter(Mandatory)]$Rows
  )
  $p = Get-IdentityTablePath -GroceryRoot $GroceryRoot -Namespace $Namespace -Store $Store
  $dir = Split-Path $p -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  # ordinal sort: a culture-sensitive sort would reorder the file on a machine with a different locale
  # and turn a no-op run into a whole-file diff.
  $sorted = @($Rows | Sort-Object -Property @{ Expression = { [string]$_.key } } -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
  $sb = New-Object System.Text.StringBuilder
  foreach ($r in $sorted) { [void]$sb.Append(($r | ConvertTo-Json -Depth 6 -Compress)); [void]$sb.Append("`n") }
  $text = $sb.ToString()
  if (Test-Path $p) {
    $old = [IO.File]::ReadAllText($p)
    if ($old -eq $text) { return [pscustomobject]@{ path = $p; rows = $sorted.Count; changed = $false } }
  }
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $tmp = $p + '.tmp'
  [IO.File]::WriteAllText($tmp, $text, $utf8)
  # RE-PARSE BEFORE THE SWAP. The point of temp+move is that the live file is never half-written; the
  # point of re-parsing first is that it is never atomically replaced by something unreadable either.
  $back = @([IO.File]::ReadAllLines($tmp) | Where-Object { $_ -and $_.Trim() })
  # ASSIGN, THEN COUNT. In PS 5.1 ConvertFrom-Json writes a JSON array to the pipeline as ONE object,
  # so @( ... | ConvertFrom-Json ).Count is 1 no matter how many rows there are - which made this
  # re-parse check fail on its first real run and (correctly) refuse to swap the file in.
  $parsed = ('[' + ($back -join ',') + ']') | ConvertFrom-Json
  $n = @($parsed).Count
  if ($n -ne $sorted.Count) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    throw ("identity-lib: wrote " + $sorted.Count + " row(s) to " + $tmp + " but only " + $n + " parsed back. The live table was NOT replaced.")
  }
  Move-Item -Path $tmp -Destination $p -Force
  return [pscustomobject]@{ path = $p; rows = $sorted.Count; changed = $true }
}

function Save-IdentityManifest {
  <#
    The run that produced this namespace's files: which rules hash, which board date, when, how many rows
    per store, and how many of them were reused from the previous table rather than re-matched.

    This is also the file the graph importer takes its provenance from, and the file a human reads to
    answer "is the table current?" without parsing 40k lines.
  #>
  param(
    [Parameter(Mandatory)][string]$GroceryRoot,
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$RulesHash,
    [Parameter(Mandatory)][string]$BoardDate,
    [Parameter(Mandatory)]$Stores,
    [int]$Reused = 0,
    [int]$Matched = 0,
    [int]$Contested = 0,
    [int]$IdCollisions = 0
  )
  $dir = Join-Path (Get-IdentityRoot -GroceryRoot $GroceryRoot) $Namespace
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  # Flattened with an explicit loop, not a pipeline inside the hash literal. Measured 2026-08-22: a
  # List[object] bound to this untyped parameter and then piped from INSIDE an [ordered]@{} literal
  # throws "Argument types do not match" - unlocatable from the message, and the same call with a plain
  # array works. Building the two values first makes the literal pure data.
  $storeList = @()
  $rowsTotal = 0
  foreach ($s in $Stores) { $storeList += $s; $rowsTotal += [int]$s.rows }
  $doc = [ordered]@{
    readme = 'Product identity table, one current row per (store, product key) in this namespace. Truth is the .jsonl files beside this manifest; graph.db is a rebuildable index of them (graph/schema.md commitment 3). History is git: the files are tracked and sorted, so an assignment change is a commit diff. Written by compare-deals.ps1 -IdentityNamespace; never hand-edit.'
    namespace = $Namespace
    rules_hash = $RulesHash
    board_date = $BoardDate
    built_at = (Get-Date).ToString('s')
    rows_total = $rowsTotal
    rows_reused_from_previous = $Reused
    rows_rematched = $Matched
    rows_contested = $Contested
    key_collisions_demoted_to_name = $IdCollisions
    stores = $storeList
  }
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $p = Join-Path $dir '_manifest.json'
  $tmp = $p + '.tmp'
  [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 6), $utf8)
  $null = Read-JsonFile $tmp
  Move-Item -Path $tmp -Destination $p -Force
  return $p
}
