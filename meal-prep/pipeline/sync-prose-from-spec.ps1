<#
  sync-prose-from-spec.ps1 - write the SPEC's current prose back into specs\prose\prose-<slug>.json.

  WHY THIS EXISTS, and why it is the last open durability item from the 2026-07-26 cost redesign.
  spec-guards.ps1 in FULL mode does not read prose to check it - it MERGES prose INTO the spec and then
  validates the result (see its "prose merge" block: intro/portion/cost_closing/upsell, shop_smart,
  make_it, and seven head fields are all assigned from the prose file). That is the correct design while
  the prose file is the writer's copy and the spec is generated from it.
  The redesign inverted that relationship and nothing wrote it back. Three writer waves re-anchored prose
  directly in the SPECS - the per-serving basis change, the moved cost sentences, and the shop_smart
  money cleanup (97 specs, 211 hard dollar figures removed) - and build-card2 reads specs directly, so the
  live cards are right. But specs\prose\ still holds the PRE-REDESIGN text.

  MEASURED 2026-08-02: ALL 400 slugs that have both a spec and a prose file would be overwritten by one
  full spec-guards run - 400 upsell_html, 400 cost_closing_html, 362 head.description, 325 intro_html.
  Three of them would have their deleted dollar figures put back into shop_smart. There is no partial
  version of this failure: the run that "validates" a run dir is the run that reverts it.

  SCOPE, CORRECTED THE SAME DAY AND WORTH BEING PRECISE ABOUT. These specs and prose files live in
  archive\<run>\specs\ - the PRE-CONSOLIDATION snapshot of each run. The LIVE spec layer is db\recipes,
  which engine\build-cards.ps1 renders from and which has NO prose directory at all, so full-mode
  spec-guards cannot run against it and cannot revert a live card. What this protects is the run
  snapshots: still worth having in step (they are the record of what each run shipped, and spec-guards is
  pointed at them by hand), but it is NOT the live-card risk the first version of this header claimed.
  The live-layer contradictions are a separate job - see audit-spec-contradictions.ps1, which defaults to
  db\recipes for exactly this reason.

  DIRECTION IS THE WHOLE POINT. This only ever writes spec -> prose. The spec is what built every live
  card, so it is the truth; copying prose -> spec is the revert this exists to prevent. A field is written
  only when the SPEC has a non-empty value for it - an empty spec field NEVER blanks a prose field.

  Also creates the prose file when a run never had one (orig and r10 were reconstructed straight into
  specs). Without it those 121 slugs fail full-mode spec-guards on 'missing prose file', which reads like
  a broken run rather than a run that never used that surface.

  Usage: .\sync-prose-from-spec.ps1 -SpecsDir ..\archive\r300\specs [-WhatIf]
         .\sync-prose-from-spec.ps1 -AllRuns [-WhatIf]
         .\sync-prose-from-spec.ps1 -SelfTest
#>
param(
  [string]$SpecsDir = "",
  [switch]$AllRuns,
  [switch]$WhatIf,
  # -Check is the GUARD: same code, writes nothing, exits 1 if any prose file disagrees with its spec.
  # Deliberately the same script rather than a separate checker - a guard that re-implements what it
  # guards drifts from it, which is the exact failure this whole file exists to fix, one level up.
  [switch]$Check,
  [switch]$SelfTest,
  [string]$Root = ""
)
$ErrorActionPreference = 'Stop'
$__jioRoot = $PSScriptRoot; while ($__jioRoot -and -not (Test-Path (Join-Path $__jioRoot 'lib\json-io.ps1'))) { $__jioRoot = Split-Path $__jioRoot -Parent }
if (-not $__jioRoot) { throw 'json-io.ps1 not found walking up from ' + $PSScriptRoot + " - Read-JsonFile is unavailable and a bare Get-Content would decode a BOM-less file as cp1252" }
. (Join-Path $__jioRoot 'lib\json-io.ps1')   # walk UP to find it: this file is two levels below the repo root, and a fixed -Parent hop assumed one
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }

# EXACTLY the fields spec-guards.ps1 assigns from prose onto the spec. Kept as one list on purpose: if that
# merge ever grows a field, this list has to grow with it or the new field silently keeps reverting, which
# is the failure mode this whole script is about. test-auditors pins the two lists against each other.
$PROSE_STR  = @('intro_html','cost_closing_html','portion_html','upsell_html')
$PROSE_ARR  = @('shop_smart','make_it')
$HEAD_STR   = @('description','keywords','prepTime','cookTime','totalTime')
$HEAD_ARR   = @('recipeIngredient','steps')
# spec-guards' own minimums. A spec that violates one is a real finding, not something to paper over by
# leaving the old prose in place - syncing it faithfully makes the finding visible on the next full run.
$MINS = @{ shop_smart = 2; make_it = 5; recipeIngredient = 3; steps = 3 }

function Get-FieldText($v) {
  if ($null -eq $v) { return '' }
  if ($v -is [array]) { return (@($v | ForEach-Object { [string]$_ }) -join ([char]1)) }
  return [string]$v
}
function Set-Prop($obj, [string]$name, $value) {
  if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name = $value }
  else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

function Invoke-ProseSync([string]$specsDir, [bool]$whatIf) {
  $proseDir = Join-Path $specsDir 'prose'
  $specs = @(Get-ChildItem (Join-Path $specsDir '*.json') -ErrorAction SilentlyContinue |
             # _index.json is the run's catalogue, not a spec - excluded here exactly as spec-guards.ps1
             # line 90 excludes it, because a list of files to sync that does not match the list of files
             # the consumer reads is how a "synced" surface still drifts.
             Where-Object { $_.Name -notmatch '^(run-|recipes-)' -and $_.Name -ne '_index.json' })
  if ($specs.Count -eq 0) { return @{ text = "prose-sync [$specsDir]: no spec files"; changed = 0; created = 0; issues = @() } }
  if (-not $whatIf -and -not (Test-Path $proseDir)) { New-Item -ItemType Directory -Path $proseDir -Force | Out-Null }

  $created = 0; $updated = 0; $same = 0; $skeleton = 0
  $issues = New-Object System.Collections.Generic.List[string]
  $names  = New-Object System.Collections.Generic.List[string]
  $skelNames = New-Object System.Collections.Generic.List[string]
  foreach ($sf in $specs) {
    $slug = $sf.BaseName
    $spec = Read-JsonFile $sf.FullName
    $pf = Join-Path $proseDir ("prose-$slug.json")
    # A SKELETON SPEC HAS NOTHING TO SYNC. The r10 run's 8 specs declare every prose field and leave them
    # all empty - their prose was never written to this surface. Creating a prose file from them would only
    # trade spec-guards' "missing prose file" for "prose field empty", which is the same failure wearing a
    # more confusing name. Skip and count them; a spec with even ONE prose field still syncs that field.
    if (-not (Test-Path $pf)) {
      $anyProse = $false
      foreach ($k in $PROSE_STR) { if ([string]$spec.$k) { $anyProse = $true; break } }
      if (-not $anyProse) { foreach ($k in $PROSE_ARR) { if (@($spec.$k).Count -gt 0) { $anyProse = $true; break } } }
      if (-not $anyProse) { $skeleton++; if ($skelNames.Count -lt 8) { $skelNames.Add($slug) }; continue }
    }
    $isNew = -not (Test-Path $pf)
    $pr = if ($isNew) { [pscustomobject]@{} } else { Read-JsonFile $pf }
    $before = ($pr | ConvertTo-Json -Depth 8 -Compress)

    foreach ($k in $PROSE_STR) {
      $v = [string]$spec.$k
      if ($v) { Set-Prop $pr $k $v }
      elseif (-not (Get-FieldText $pr.$k)) { $issues.Add("$slug : $k is empty in BOTH the spec and the prose file - full spec-guards will fail this slug") }
    }
    foreach ($k in $PROSE_ARR) {
      $v = @($spec.$k)
      if ($v.Count -gt 0) {
        Set-Prop $pr $k $v
        if ($MINS.ContainsKey($k) -and $v.Count -lt $MINS[$k]) { $issues.Add("$slug : spec.$k has $($v.Count) entr(y/ies), spec-guards requires $($MINS[$k]) - synced faithfully, the shortfall is a real finding") }
      }
      elseif (@($pr.$k).Count -eq 0) { $issues.Add("$slug : $k is empty in BOTH the spec and the prose file") }
    }
    if ($spec.head) {
      if (-not ($pr.PSObject.Properties.Name -contains 'head')) { Set-Prop $pr 'head' ([pscustomobject]@{}) }
      foreach ($k in $HEAD_STR) {
        $v = [string]$spec.head.$k
        if ($v) { Set-Prop $pr.head $k $v }
        elseif (-not (Get-FieldText $pr.head.$k)) { $issues.Add("$slug : head.$k is empty in BOTH") }
      }
      foreach ($k in $HEAD_ARR) {
        $v = @($spec.head.$k)
        if ($v.Count -gt 0) {
          Set-Prop $pr.head $k $v
          if ($MINS.ContainsKey($k) -and $v.Count -lt $MINS[$k]) { $issues.Add("$slug : spec.head.$k has $($v.Count), spec-guards requires $($MINS[$k])") }
        }
        elseif (@($pr.head.$k).Count -eq 0) { $issues.Add("$slug : head.$k is empty in BOTH") }
      }
    } else { $issues.Add("$slug : the SPEC has no head block - nothing to sync into head prose") }

    $after = ($pr | ConvertTo-Json -Depth 8 -Compress)
    if ($after -eq $before -and -not $isNew) { $same++; continue }
    if ($isNew) { $created++ } else { $updated++ }
    if ($names.Count -lt 6) { $names.Add($slug) }
    if (-not $whatIf) { ($pr | ConvertTo-Json -Depth 8) | Set-Content $pf -Encoding UTF8 }
  }
  $t = ("prose-sync [{0}]: {1} created, {2} updated, {3} already in sync{4}{5}" -f (Split-Path $specsDir -Leaf), $created, $updated, $same,
        $(if ($skeleton -gt 0) { ", $skeleton SKELETON spec(s) skipped (every prose field empty, nothing to sync): " + (($skelNames.ToArray()) -join ', ') } else { '' }),
        $(if ($whatIf) { '  [WhatIf - nothing written]' } else { '' }))
  return @{ text = $t; changed = ($created + $updated); created = $created; updated = $updated; same = $same; skeleton = $skeleton; issues = @($issues.ToArray()); names = @($names.ToArray()) }
}

if ($SelfTest) {
  $fail = 0
  $T = Join-Path $env:TEMP ('prosesync-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path (Join-Path $T 'specs\prose') -Force | Out-Null
  try {
    function Chk([string]$label, [bool]$cond, [string]$got) {
      if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    # FROZEN FIXTURE - the real shape of the drift measured on 2026-08-02. The spec carries the redesign's
    # re-anchored prose ($3.06 basis, dollars stripped from shop_smart); the prose file still holds the
    # pre-redesign text ($1.13 basis, dollars present). A full spec-guards run merges prose OVER spec.
    @{
      name = 'Test Recipe'; servings = 14; visibility = 'paid'
      stat = @{ cost_ps = '3.06'; cal = 620; protein = 41 }
      intro_html = '<p>NEW intro at $3.06 a serving.</p>'
      cost_closing_html = '<p>NEW closing at $3.06.</p>'
      portion_html = '<p>NEW portion text.</p>'
      upsell_html = '<p>NEW upsell at $3.06.</p>'
      shop_smart = @('Buy the 5 lb bag.', 'Skip the pre-diced.')          # dollars removed by the cleanup
      make_it = @('Weigh the pot.', 'b', 'c', 'd', 'e')
      head = @{ description = 'NEW description at $3.06'; keywords = 'k'; prepTime = 'PT15M'; cookTime = 'PT30M'; totalTime = 'PT45M'; recipeIngredient = @('a','b','c'); steps = @('s1','s2','s3') }
    } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $T 'specs\drifted.json') -Encoding UTF8
    @{
      intro_html = '<p>OLD intro at $1.13 a serving.</p>'
      cost_closing_html = '<p>OLD closing at $1.13.</p>'
      portion_html = '<p>OLD portion text.</p>'
      upsell_html = '<p>OLD upsell at $1.13.</p>'
      shop_smart = @('Buy the 5 lb bag for $8.94.', 'Skip the pre-diced, it runs $2.23 a pound.')
      make_it = @('Weigh the pot.', 'b', 'c', 'd', 'e')
      head = @{ description = 'OLD description at $1.13'; keywords = 'k'; prepTime = 'PT15M'; cookTime = 'PT30M'; totalTime = 'PT45M'; recipeIngredient = @('a','b','c'); steps = @('s1','s2','s3') }
    } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $T 'specs\prose\prose-drifted.json') -Encoding UTF8
    # CLEAN TWIN: already in sync - must not be rewritten at all.
    $inSync = @{
      name = 'In Sync'; servings = 14; visibility = 'paid'; stat = @{ cost_ps = '2.00'; cal = 500; protein = 30 }
      intro_html = '<p>i</p>'; cost_closing_html = '<p>c</p>'; portion_html = '<p>p</p>'; upsell_html = '<p>u</p>'
      shop_smart = @('a','b'); make_it = @('Weigh the pot.','b','c','d','e')
      head = @{ description = 'd'; keywords = 'k'; prepTime = 'PT1M'; cookTime = 'PT2M'; totalTime = 'PT3M'; recipeIngredient = @('a','b','c'); steps = @('s1','s2','s3') }
    }
    $inSync | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $T 'specs\insync.json') -Encoding UTF8
    @{
      intro_html = '<p>i</p>'; cost_closing_html = '<p>c</p>'; portion_html = '<p>p</p>'; upsell_html = '<p>u</p>'
      shop_smart = @('a','b'); make_it = @('Weigh the pot.','b','c','d','e')
      head = @{ description = 'd'; keywords = 'k'; prepTime = 'PT1M'; cookTime = 'PT2M'; totalTime = 'PT3M'; recipeIngredient = @('a','b','c'); steps = @('s1','s2','s3') }
    } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $T 'specs\prose\prose-insync.json') -Encoding UTF8
    # NO PROSE FILE AT ALL - the orig/r10 case. Must be created, not reported as broken.
    $inSync.name = 'No Prose'
    $inSync | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $T 'specs\noprose.json') -Encoding UTF8
    # AN EMPTY SPEC FIELD MUST NOT BLANK THE PROSE. This is the one way a sync can destroy writing.
    @{
      name = 'Empty Field'; servings = 14; visibility = 'paid'; stat = @{ cost_ps = '2.00'; cal = 500; protein = 30 }
      intro_html = ''; cost_closing_html = '<p>c2</p>'; portion_html = '<p>p</p>'; upsell_html = '<p>u</p>'
      shop_smart = @('a','b'); make_it = @('Weigh the pot.','b','c','d','e')
      head = @{ description = 'd'; keywords = 'k'; prepTime = 'PT1M'; cookTime = 'PT2M'; totalTime = 'PT3M'; recipeIngredient = @('a','b','c'); steps = @('s1','s2','s3') }
    } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $T 'specs\emptyfield.json') -Encoding UTF8
    @{
      intro_html = '<p>KEEP ME - the spec lost this field</p>'; cost_closing_html = '<p>c-old</p>'
      portion_html = '<p>p</p>'; upsell_html = '<p>u</p>'
      shop_smart = @('a','b'); make_it = @('Weigh the pot.','b','c','d','e')
      head = @{ description = 'd'; keywords = 'k'; prepTime = 'PT1M'; cookTime = 'PT2M'; totalTime = 'PT3M'; recipeIngredient = @('a','b','c'); steps = @('s1','s2','s3') }
    } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $T 'specs\prose\prose-emptyfield.json') -Encoding UTF8

    $insyncBefore = Get-Content (Join-Path $T 'specs\prose\prose-insync.json') -Raw
    $r = Invoke-ProseSync (Join-Path $T 'specs') $false
    Write-Output ('      ' + $r.text)
    $d = Read-JsonFile (Join-Path $T 'specs\prose\prose-drifted.json')
    Chk 'MUST FIRE  the drifted prose now carries the SPEC text ($3.06, not $1.13)' ($d.cost_closing_html -match '3\.06' -and $d.intro_html -match '3\.06' -and $d.head.description -match '3\.06') ("closing=" + $d.cost_closing_html)
    Chk 'MUST FIRE  the shop_smart dollar cleanup is preserved, not put back' ((@($d.shop_smart | Where-Object { $_ -match '\$\d' }).Count) -eq 0) (($d.shop_smart -join ' | '))
    Chk 'MUST FIRE  a run with no prose dir gets its file CREATED' ((Test-Path (Join-Path $T 'specs\prose\prose-noprose.json')) -and $r.created -eq 1) ("created=" + $r.created)
    Chk 'CLEAN TWIN an already-synced prose file is not rewritten' ((Get-Content (Join-Path $T 'specs\prose\prose-insync.json') -Raw) -eq $insyncBefore) 'file was rewritten'
    $e = Read-JsonFile (Join-Path $T 'specs\prose\prose-emptyfield.json')
    Chk 'CLEAN TWIN an EMPTY spec field never blanks the prose field' ($e.intro_html -match 'KEEP ME') ("intro=" + $e.intro_html)
    Chk 'the empty-in-both case is REPORTED, not silently skipped' ((@($r.issues | Where-Object { $_ -match 'emptyfield' }).Count) -eq 0) (($r.issues -join ' | '))
    Chk 'a spec field that DID move is written (cost_closing on emptyfield)' ($e.cost_closing_html -eq '<p>c2</p>') ("closing=" + $e.cost_closing_html)
    # idempotency: a second pass changes nothing at all
    $r2 = Invoke-ProseSync (Join-Path $T 'specs') $false
    Chk 'idempotent - a second run syncs nothing' ($r2.changed -eq 0) ("changed=" + $r2.changed)
    # DIRECTION: the SPEC must never be touched by this script.
    $sp = Read-JsonFile (Join-Path $T 'specs\drifted.json')
    Chk 'the SPEC is never modified - this only ever writes spec -> prose' ($sp.intro_html -match '3\.06') ("spec intro=" + $sp.intro_html)
    # THE GUARD: -Check must FIRE on a re-drifted file and must NOT fire on a synced tree. Without the
    # must-fire half, a guard that always passes is indistinguishable from a guard that works.
    $selfPath = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $here 'sync-prose-from-spec.ps1' }
    $clean = & powershell -NoProfile -ExecutionPolicy Bypass -File $selfPath -SpecsDir (Join-Path $T 'specs') -Check 2>&1 | Out-String
    Chk 'CHECK on a synced tree exits clean' (($LASTEXITCODE -eq 0) -and ($clean -match 'CHECK OK')) ("rc=$LASTEXITCODE " + ($clean -replace "`r?`n", ' '))
    $reDrift = Read-JsonFile (Join-Path $T 'specs\prose\prose-drifted.json')
    $reDrift.upsell_html = '<p>someone edited the prose file back to $1.13.</p>'
    $reDrift | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $T 'specs\prose\prose-drifted.json') -Encoding UTF8
    $dirty = & powershell -NoProfile -ExecutionPolicy Bypass -File $selfPath -SpecsDir (Join-Path $T 'specs') -Check 2>&1 | Out-String
    Chk 'MUST FIRE  CHECK exits 1 and NAMES the slug when prose drifts again' (($LASTEXITCODE -eq 1) -and ($dirty -match 'CHECK FAIL') -and ($dirty -match 'drifted')) ("rc=$LASTEXITCODE " + ($dirty -replace "`r?`n", ' '))
    $stillDrift = Read-JsonFile (Join-Path $T 'specs\prose\prose-drifted.json')
    Chk 'CHECK writes NOTHING - the drift it reports is still there afterwards' ($stillDrift.upsell_html -match '1\.13') ("upsell=" + $stillDrift.upsell_html)
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$dirs = @()
if ($AllRuns) {
  $dirs = @(Get-ChildItem (Join-Path $mp 'archive') -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'specs' } | Where-Object { Test-Path $_ })
} elseif ($SpecsDir) { $dirs = @($SpecsDir) }
else { throw 'sync-prose-from-spec: pass -SpecsDir <dir> or -AllRuns.' }

$allIssues = New-Object System.Collections.Generic.List[string]
$allNames = New-Object System.Collections.Generic.List[string]
$totChanged = 0
$dryRun = ([bool]$WhatIf) -or ([bool]$Check)
foreach ($d in $dirs) {
  $r = Invoke-ProseSync $d $dryRun
  Write-Output $r.text
  if ($r.names -and $r.names.Count) { Write-Output ('    e.g. ' + (($r.names) -join ', ')); foreach ($n in $r.names) { $allNames.Add($n) } }
  $totChanged += [int]$r.changed
  foreach ($i in $r.issues) { $allIssues.Add($i) }
}
if ($allIssues.Count -gt 0) {
  Write-Output ("  ISSUES ({0}) - synced faithfully, but these slugs will still fail a full spec-guards run and the reason is in the SPEC, not the prose file:" -f $allIssues.Count)
  foreach ($i in ($allIssues | Select-Object -First 25)) { Write-Output ('    ' + $i) }
}
if ($Check) {
  if ($totChanged -eq 0) { Write-Output ("prose-sync CHECK OK: every prose file matches its spec across {0} run(s) - a full spec-guards run cannot revert anything." -f $dirs.Count); exit 0 }
  Write-Output ("prose-sync CHECK FAIL: {0} prose file(s) disagree with their spec. spec-guards FULL mode MERGES prose INTO the spec, so the next full run would overwrite the spec's text with the older prose - silently, and on every slug at once. Run  sync-prose-from-spec.ps1 -AllRuns  to write the specs back. e.g. {1}" -f $totChanged, (($allNames | Select-Object -First 6) -join ', '))
  exit 1
}
Write-Output ("prose-sync: {0} file(s) written across {1} run(s)" -f $totChanged, $dirs.Count)
exit 0
