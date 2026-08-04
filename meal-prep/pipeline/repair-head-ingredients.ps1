<#
  repair-head-ingredients.ps1 - bring head.recipeIngredient (the live JSON-LD ingredient list) into
  agreement with the ingredient list the card actually shows, on every spec that already exists.

  WHY THERE IS A REPAIR AND NOT JUST A GENERATOR FIX: build-v2-spec now derives the field
  (head-ingredients-lib.ps1), but it builds a spec FROM AN INTAKE FILE, and the 513 live recipes have no
  intake files - they came from the archived run generators, which emitted head.recipeIngredient empty for
  a writer to fill in by hand. Re-running the generator is not available to them. So the existing specs
  get the same derivation applied in place.

  MEASURED BEFORE: 507 of 513 specs had a JSON-LD ingredient list of a different LENGTH from the card's,
  usually far shorter (american-goulash-pasta: 6 against 16), stating package units the page never uses.

  TWO DEFECTS, both live on thriftycrew.com, both fixed here:

    1. head.recipeIngredient  rewritten from ingredients_display via head-ingredients-lib.
    2. cost_lines package plurals  "Buy 3 16oz boxs" -> "boxes", "Buy 2 eachs" -> "each". A retired
       generator pluralised package labels with a bare + 's'. The current renderer's Plural() has handled
       both cases correctly since the port (x/ch/sh/ss/s/z take 'es'; 'each' is invariant), so this is
       stranded output, not a live bug - nothing regenerates these strings, so they need repairing in the
       data. 25 specs carry "boxs", 17 carry "eachs".

  WRITES ARE KEY-SCOPED (SPEC-SCHEMA.md standing rule): a spec is NEVER round-tripped through
  ConvertFrom-Json | ConvertTo-Json - the prose fields carry \uXXXX escapes that a re-serialize rewrites,
  and PS 5.1 serializers have corrupted this file class before. Only the bytes of the head.recipeIngredient
  ARRAY (located by brace/bracket matching inside the "head" object) and the two plural typos are replaced.
  head.description is not touched by any path here - it doubles as the post meta description.

  Read-only unless -Apply.
  Usage: .\repair-head-ingredients.ps1 [-Apply] [-Slugs a,b] | .\repair-head-ingredients.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string[]]$Slugs, [string]$Root = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }
. (Join-Path $here 'head-ingredients-lib.ps1')

function Get-HrKeyArraySpan {
  <#
    Byte span of the VALUE of "<key>": [ ... ] starting the search at $from, bracket-matched and
    string-aware so a '[' or ']' inside a prose value can never end the span. Returns @{start;end} over
    the '[' .. ']' inclusive, or $null.
  #>
  param([string]$Raw, [string]$Key, [int]$From = 0)
  $m = [regex]::Match($Raw.Substring($From), ('"' + [regex]::Escape($Key) + '"\s*:\s*\['))
  if (-not $m.Success) { return $null }
  $start = $From + $m.Index + $m.Length - 1      # index of the '['
  $depth = 0; $inStr = $false; $esc = $false
  for ($i = $start; $i -lt $Raw.Length; $i++) {
    $ch = $Raw[$i]
    if ($esc) { $esc = $false; continue }
    if ($inStr) {
      if ($ch -eq '\') { $esc = $true } elseif ($ch -eq '"') { $inStr = $false }
      continue
    }
    if ($ch -eq '"') { $inStr = $true; continue }
    if ($ch -eq '[') { $depth++ }
    elseif ($ch -eq ']') { $depth--; if ($depth -eq 0) { return @{ start = $start; end = $i } } }
  }
  return $null
}

function Get-HrObjectSpan {
  <# Byte span of the VALUE of "<key>": { ... }, same string-aware brace match. Used to scope the
     recipeIngredient search INSIDE head, so a same-named key anywhere else could never be hit. #>
  param([string]$Raw, [string]$Key)
  $m = [regex]::Match($Raw, ('"' + [regex]::Escape($Key) + '"\s*:\s*\{'))
  if (-not $m.Success) { return $null }
  $start = $m.Index + $m.Length - 1
  $depth = 0; $inStr = $false; $esc = $false
  for ($i = $start; $i -lt $Raw.Length; $i++) {
    $ch = $Raw[$i]
    if ($esc) { $esc = $false; continue }
    if ($inStr) {
      if ($ch -eq '\') { $esc = $true } elseif ($ch -eq '"') { $inStr = $false }
      continue
    }
    if ($ch -eq '"') { $inStr = $true; continue }
    if ($ch -eq '{') { $depth++ }
    elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { return @{ start = $start; end = $i } } }
  }
  return $null
}

function Format-HrArray {
  <# Serialize the new lines in the surrounding file's own style: each element on its own line, escaped by
     ConvertTo-Json so the \uXXXX convention of the rest of the spec is matched exactly (a name carrying
     an apostrophe or ampersand serializes the same way the file already serializes prose).

     $Newline is the file's OWN line ending, not a literal "`n". Specs are written by PS 5.1
     ConvertTo-Json and are CRLF throughout; splicing LF-joined lines into one leaves a file with mixed
     endings, which git then rewrites wholesale - a 17-line edit shows up as a whole-file diff and the
     real change becomes unreviewable. #>
  param([string[]]$Lines, [int]$Indent, [string]$Newline)
  $pad = ' ' * $Indent
  $parts = foreach ($l in $Lines) { $pad + '    ' + (ConvertTo-Json -InputObject ([string]$l)) }
  return ('[' + $Newline + ($parts -join (',' + $Newline)) + $Newline + $pad + ']')
}

function Repair-HrSpecText {
  <# The whole transform on one spec's TEXT. Returns @{text; ingChanged; pluralHits} or throws. Pure, so
     the self-test can drive it without touching db\recipes. #>
  param([string]$Raw, $FoodDbMap)
  $spec = $Raw | ConvertFrom-Json          # READ-only parse; the write path never uses this object
  $newLines = @(Get-HeadRecipeIngredient $spec.ingredients_display $spec.scaler.ing $FoodDbMap)

  $headSpan = Get-HrObjectSpan $Raw 'head'
  if (-not $headSpan) { throw 'no "head" object in spec' }
  $span = Get-HrKeyArraySpan $Raw 'recipeIngredient' $headSpan.start
  if (-not $span -or $span.end -gt $headSpan.end) { throw 'no head.recipeIngredient array in spec' }

  # COLUMN OF THE '[', because that is what PS 5.1's ConvertTo-Json indents an array against: elements sit
  # at bracket+4 and the closing bracket lines up under the opening one. Indenting against the KEY's line
  # instead re-flows the block to a different column from every other array in the file, which turns a
  # 16-line content change into a diff nobody can read.
  $bracketCol = $span.start - ($Raw.LastIndexOf("`n", $span.start) + 1)
  $indent = $bracketCol

  $nl = if (([regex]::Matches($Raw, "`r`n")).Count -gt 0) { "`r`n" } else { "`n" }
  $old = $Raw.Substring($span.start, $span.end - $span.start + 1)
  $new = Format-HrArray $newLines $indent $nl
  $ingChanged = ($old -ne $new)
  $out = $Raw.Substring(0, $span.start) + $new + $Raw.Substring($span.end + 1)

  # package-plural typos from the retired generator. Word-bounded and case-sensitive: these two exact
  # tokens are never legitimate anywhere in a spec.
  $pluralHits = 0
  foreach ($fix in @(@('boxs', 'boxes'), @('eachs', 'each'))) {
    $pluralHits += ([regex]::Matches($out, ('\b' + $fix[0] + '\b'))).Count
    $out = [regex]::Replace($out, ('\b' + $fix[0] + '\b'), $fix[1])
  }

  $reparsed = $out | ConvertFrom-Json      # never return text that will not parse
  if (@($reparsed.head.recipeIngredient).Count -ne @($reparsed.ingredients_display).Count) {
    throw 'post-write count still disagrees with ingredients_display'
  }
  if ([string]$reparsed.head.description -ne [string]$spec.head.description) { throw 'head.description changed - abort' }
  if (@($reparsed.ingredients_display).Count -ne @($spec.ingredients_display).Count) { throw 'ingredients_display changed - abort' }
  return @{ text = $out; ingChanged = $ingChanged; pluralHits = $pluralHits }
}

if ($SelfTest) {
  Invoke-HiSelfTest
  $script:fails = [int]$script:hiFails
  function Chk([string]$what, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok   " + $what) } else { $script:fails++; Write-Output ("  FAIL " + $what + "  got: " + $got) }
  }
  Write-Output 'repair-head-ingredients self-test'
  $db = @{ 'Penne Pasta' = [pscustomobject]@{ brand = 'Barilla' } }
  # A spec shaped like the real ones. The \uXXXX sequences are LITERAL bytes here on purpose: that is how
  # every db\recipes spec stores its markup and punctuation, and preserving those exact bytes outside the
  # edited span is the whole reason this rewrite is key-scoped instead of a re-serialize.
  $sample = @'
{
    "name":  "T",
    "ingredients_display":  [
                                "<strong>Penne Pasta (Barilla):</strong> 10 cups (1050 g)",
                                "<strong>Garlic:</strong> 4 cloves (20 g)"
                            ],
    "cost_lines":  [
                       "Penne Pasta, 10 cups: ~$0.64. <strong>Buy 3 16oz boxs: $2.93.</strong>",
                       "Garlic, 4 cloves: ~$0.20. <strong>Buy 2 eachs: $0.98.</strong>"
                   ],
    "intro_html":  "A bracket [ and a brace { live here, plus an 'escape'.",
    "scaler":  {
                   "ing":  [
                               { "item": "Penne Pasta", "canon": "Penne Pasta", "grams": 1050, "buy": "10 cups" },
                               { "item": "Garlic", "canon": "Garlic", "grams": 20, "buy": "4 cloves" }
                           ]
               },
    "head":  {
                 "description":  "Keep me byte for byte: 'quoted' & escaped.",
                 "recipeIngredient":  [
                                          "3 boxs Penne Pasta"
                                      ],
                 "steps":  [
                               "Boil the penne."
                           ]
             }
}
'@
  $r = Repair-HrSpecText $sample $db
  $o = $r.text | ConvertFrom-Json
  Chk 'one JSON-LD line per displayed ingredient (was 1 of 2)' (@($o.head.recipeIngredient).Count -eq 2) ([string]@($o.head.recipeIngredient).Count)
  Chk 'the truncated package line becomes the cook measure' (@($o.head.recipeIngredient)[0] -eq 'Penne Pasta, 10 cups (1050 g)') (@($o.head.recipeIngredient)[0])
  Chk 'the ingredient that was missing entirely is present' (@($o.head.recipeIngredient)[1] -eq 'Garlic, 4 cloves (20 g)') (@($o.head.recipeIngredient)[1])
  Chk 'cost_lines "boxs" repaired' ($o.cost_lines[0] -match 'Buy 3 16oz boxes:') $o.cost_lines[0]
  Chk 'cost_lines "eachs" repaired' ($o.cost_lines[1] -match 'Buy 2 each:') $o.cost_lines[1]
  Chk 'plural hits counted' ($r.pluralHits -eq 2) ([string]$r.pluralHits)
  Chk 'head.description untouched' ($o.head.description -eq "Keep me byte for byte: 'quoted' & escaped.") $o.head.description
  Chk 'prose with a bare [ and { survives byte for byte' ($r.text -match [regex]::Escape('A bracket [ and a brace { live here')) 'prose damaged'
  Chk 'head.steps untouched' (@($o.head.steps)[0] -eq 'Boil the penne.') (@($o.head.steps)[0])
  Chk 'ingredients_display untouched' (@($o.ingredients_display).Count -eq 2) ([string]@($o.ingredients_display).Count)
  # idempotence: a second pass must be a no-op
  $r2 = Repair-HrSpecText $r.text $db
  Chk 'second pass changes nothing (idempotent)' ((-not $r2.ingChanged) -and $r2.pluralHits -eq 0 -and $r2.text -eq $r.text) 'not idempotent'

  # ---- ESCAPE PRESERVATION, against a REAL spec rather than a fixture. A hand-written sample cannot
  # prove this: the catalog's specs store their markup and punctuation as \uXXXX byte sequences, which is
  # exactly the content a ConvertFrom-Json | ConvertTo-Json round-trip rewrites (SPEC-SCHEMA.md).
  $realFile = Join-Path $mp 'db\recipes\american-goulash-pasta.json'
  if (Test-Path $realFile) {
    $realRaw = [IO.File]::ReadAllText($realFile)
    $realDb = Get-HiFoodDbMap (Join-Path $mp 'food-macros-db.json')
    $rr = Repair-HrSpecText $realRaw $realDb
    $before = ($realRaw | ConvertFrom-Json); $after = ($rr.text | ConvertFrom-Json)
    Chk 'real spec: escaped markup bytes survive verbatim' ($rr.text -match '\\u003cstrong\\u003e93/7 Ground Beef') 'display escapes rewritten'
    Chk 'real spec: an escaped apostrophe survives verbatim' ($rr.text -match "Member\\u0027s Mark") 'apostrophe escape rewritten'
    Chk 'real spec: head.description byte-identical' ($rr.text -match [regex]::Escape('"description":  "A high-protein American meal prep.')) 'description bytes moved'
    Chk 'real spec: every prose + machine field except the JSON-LD list is unchanged' (
      ($after.intro_html -eq $before.intro_html) -and ($after.head.description -eq $before.head.description) -and
      ($after.portion_html -eq $before.portion_html) -and ($after.upsell_html -eq $before.upsell_html) -and
      ($after.credit_html -eq $before.credit_html) -and ($after.cost_batch -eq $before.cost_batch) -and
      (@($after.ingredients_display) -join '|') -eq (@($before.ingredients_display) -join '|') -and
      (@($after.make_it) -join '|') -eq (@($before.make_it) -join '|') -and
      (@($after.head.steps) -join '|') -eq (@($before.head.steps) -join '|')
    ) 'a field outside head.recipeIngredient changed'
    Chk 'real spec: no bare LF spliced into a CRLF file' (
      ([regex]::Matches($rr.text, "(?<!`r)`n")).Count -eq ([regex]::Matches($realRaw, "(?<!`r)`n")).Count
    ) ('bare LFs: ' + ([regex]::Matches($rr.text, "(?<!`r)`n")).Count)
    Chk 'real spec: the JSON-LD list now matches the card line for line' (
      @($after.head.recipeIngredient).Count -eq @($after.ingredients_display).Count -and
      @($after.head.recipeIngredient)[1] -eq 'Penne Pasta, 10 cups (1050 g)'
    ) (@($after.head.recipeIngredient)[1])
  }
  Write-Output ("failures: " + $fails)
  if ($fails) { exit 1 }
  return
}

$foodDb = Get-HiFoodDbMap (Join-Path $mp 'food-macros-db.json')
$specFiles = @(Get-ChildItem (Join-Path $mp 'db\recipes\*.json') | Where-Object { $_.Name -ne '_index.json' })
if ($Slugs) { $specFiles = @($specFiles | Where-Object { $Slugs -contains $_.BaseName }) }
if (-not $specFiles.Count) { throw 'no specs matched' }

$changed = 0; $same = 0; $plural = 0; $pluralFiles = 0; $errs = New-Object System.Collections.Generic.List[string]
$samples = New-Object System.Collections.Generic.List[string]
$countBefore = 0; $countAfter = 0
foreach ($f in $specFiles) {
  # BOM is preserved PER FILE: 186 of the 513 specs carry one and 327 do not (the generators that wrote
  # them differed). Normalising either way would rewrite the first bytes of hundreds of files for no
  # reason and bury the actual change.
  $bytes = [IO.File]::ReadAllBytes($f.FullName)
  $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $raw = [IO.File]::ReadAllText($f.FullName)   # the decoder strips the BOM from the string
  $res = $null
  try { $res = Repair-HrSpecText $raw $foodDb } catch { $errs.Add($f.BaseName + ' :: ' + $_.Exception.Message); continue }
  $before = @(($raw | ConvertFrom-Json).head.recipeIngredient).Count
  $after = @(($res.text | ConvertFrom-Json).head.recipeIngredient).Count
  $countBefore += $before; $countAfter += $after
  if ($res.pluralHits -gt 0) { $plural += $res.pluralHits; $pluralFiles++ }
  if ($res.text -eq $raw) { $same++; continue }
  $changed++
  if ($samples.Count -lt 3) { $samples.Add(("{0}: {1} -> {2} JSON-LD lines" -f $f.BaseName, $before, $after)) }
  if ($Apply) { [IO.File]::WriteAllText($f.FullName, $res.text, (New-Object Text.UTF8Encoding([bool]$hadBom))) }
}
Write-Output ("specs scanned {0} | rewritten {1} | already correct {2} | errors {3}" -f $specFiles.Count, $changed, $same, $errs.Count)
Write-Output ("JSON-LD ingredient lines across the catalog: {0} -> {1}" -f $countBefore, $countAfter)
Write-Output ("package-plural typos repaired: {0} in {1} specs" -f $plural, $pluralFiles)
$samples | ForEach-Object { Write-Output ('  ' + $_) }
$errs | ForEach-Object { Write-Output ('  X ' + $_) }
if (-not $Apply) { Write-Output 'DRY RUN - nothing written. Re-run with -Apply.' }
if ($errs.Count) { exit 1 }
