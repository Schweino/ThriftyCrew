# golden-test.ps1 - the regression test for engine\cost-recipes.ps1, THE unified cost engine behind every
# price on the site. Exit 0 = pass, 2 = fail.
#
# ---------------------------------------------------------------------------------------------------
# WHY THIS WAS REBUILT (2026-08-06)
#
# v1 compared a DAILY-REGENERATED output (db\costed.json) against a FROZEN output (the retired per-run
# archive\*\recipes-costed.json). That comparison was true for exactly one day - the day of the port. Every
# daily recost moved cost_batch and every board switching package size moved pkg_g with it, so by
# 2026-08-04 a cold run emitted 10,339 diffs, which reads as catastrophe and was in fact nine days of
# grocery prices. To its credit v1 then refused to run rather than report a false pass. But the honest
# refusal had a cost: the engine ran the site's prices for eleven days with NO regression test, and its
# own message said "nothing re-proves it". On 2026-08-06 the engine was modified anyway (the -Slugs
# append fix) and could only be verified by a hand-rolled one-off diff.
#
# The fix is not a fresher output baseline - that ages out again on the next price move, and a test that
# expires whenever prices move will always be expired. It is to stop comparing across moving inputs:
#
#   [1] STRUCTURAL  asserts the live catalogue against ITSELF and its specs. Reads no price board, so
#                   nothing here can rot. Covers what a cost row gets wrong that isn't about money:
#                   missing/orphan rows, stale grams, package ceil math, the pantry fold, the totals.
#   [2] FROZEN      runs the engine over FROZEN INPUTS (specs + ingredient db + a board slice, all
#                   pinned in regression-inputs\golden\) and demands the output match byte for byte.
#                   Inputs cannot move, so the expected output can only change when the ENGINE changes -
#                   which is the only thing a regression test was ever meant to notice. This lane also
#                   exercises the -Slugs splice in both directions (replace AND append).
#   [3] PROVENANCE  v1's archive comparison. Kept because the port's history is worth being able to
#                   re-read, but it is INFORMATIONAL now and never gates. -Provenance to run it.
#
# Default (no switches) runs [1] and [2]. Both ship must-fire fixtures, because a check that reports
# nothing is indistinguishable from a check that is broken.
#
# WHEN THE ENGINE CHANGES ON PURPOSE: run this, read the diff it prints, and if the change is intended
# accept it with -Rebaseline. That rewrites ONLY the expected output, never the frozen inputs. There is
# no schedule to miss and nothing that silently ages out; the baseline moves when the engine moves.
param(
  [switch]$Structural,
  [switch]$Frozen,
  [switch]$Provenance,
  [switch]$Rebaseline,
  [switch]$Force,          # provenance lane: run it despite the frozen-baseline caveat
  [string]$CostedFile      # structural lane: check a file other than db\costed.json
)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here
$db   = Join-Path $mp 'db'
$fx   = Join-Path $here 'regression-inputs\golden'
$fin  = Join-Path $fx 'inputs'
$fexp = Join-Path $fx 'expected'
$sfx  = Join-Path $fx 'structural-fixtures'
$engine = Join-Path $here 'cost-recipes.ps1'
. (Join-Path $here 'structural-lib.ps1')

$runAll = -not ($Structural -or $Frozen -or $Provenance -or $Rebaseline)
$pass=0; $failed=0
function Ok($m)  { Write-Output ("  PASS  " + $m); $script:pass++ }
function Bad($m) { Write-Output ("  FAIL  " + $m); $script:failed++ }
function NewTemp([string]$tag){
  $p = Join-Path $env:TEMP ('golden-' + $tag + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  $null = New-Item -ItemType Directory $p -Force
  return $p
}
function Sha([string]$p){ (Get-FileHash $p -Algorithm SHA256).Hash }
# A FIXTURE RUN MUST NEVER WRITE WHERE THE LIVE RUN WRITES, and must never write inside the fixture
# either - a frozen fixture that a test writes into is no longer frozen. Every engine call below sends
# -OutFile/-FlagsFile to a temp dir. (grocery\test-auditors.ps1 learned this by overwriting the real
# board audit reports with a fixture's results.)
function Invoke-Engine([string]$outFile,[string]$flagsFile,[string[]]$slugs){
  $a = @{ DbRoot=(Join-Path $fin 'db'); GroceryOut=(Join-Path $fin 'grocery-out'); OutFile=$outFile; FlagsFile=$flagsFile }
  if($slugs){ $a['Slugs'] = $slugs }
  return (& $engine @a) 2>&1 | ForEach-Object { [string]$_ }
}

# =====================================================================================  [1] STRUCTURAL
if($runAll -or $Structural){
  Write-Output ''
  Write-Output 'STRUCTURAL - the live catalogue against its own specs (no price board is read)'

  # must-fire first. If these do not fire, nothing below this line means anything.
  $mf = [ordered]@{
    'mustfire-missing-row'  = @{ code='C1'; what='a costed recipe with no row (the 2026-08-06 -Slugs splice drop)' }
    'mustfire-orphan-row'   = @{ code='C1'; what='a costed row whose recipe no longer exists' }
    'mustfire-stale-grams'  = @{ code='C2'; what='costed grams that disagree with the spec' }
    'mustfire-bad-ceil'     = @{ code='C9'; what='buy_n that is not ceil(grams/pkg_g - 0.02)' }
    'mustfire-bad-total'    = @{ code='C7'; what='cost_first_run with the pantry fold dropped' }
  }
  foreach($name in $mf.Keys){
    $r = Invoke-StructuralCheck -CostedFile (Join-Path $sfx "$name\costed.json") -SpecDir (Join-Path $sfx 'specs') -IngredientsFile (Join-Path $sfx 'ingredients.json')
    $hit = @($r.failures | Where-Object { $_ -like ($mf[$name].code + ' *') })
    if($hit.Count -ge 1){ Ok ("{0} FIRES on {1}" -f $mf[$name].code, $mf[$name].what) }
    else { Bad ("{0} MISSED its founding bug in {1}: {2}" -f $mf[$name].code, $name, (($r.failures) -join ' | ')) }
  }
  $r = Invoke-StructuralCheck -CostedFile (Join-Path $sfx 'clean\costed.json') -SpecDir (Join-Path $sfx 'specs') -IngredientsFile (Join-Path $sfx 'ingredients.json')
  if($r.failures.Count -eq 0){ Ok 'SILENT on the clean twin' }
  else { Bad ('false-positived on the clean twin: ' + ($r.failures -join ' | ')) }

  # ...then the live catalogue
  $live = if($CostedFile){ $CostedFile } else { Join-Path $db 'costed.json' }
  $r = Invoke-StructuralCheck -CostedFile $live -SpecDir (Join-Path $db 'recipes') `
        -IngredientsFile (Join-Path $db 'ingredients.json') -DensitiesFile (Join-Path $db 'densities.json') `
        -LabelPricesFile (Join-Path $db 'label-prices.json')
  Write-Output ("  {0} recipes checked; {1} package size(s) not checkable from the db alone (label-priced)" -f $r.checked, $r.unverifiable)
  if($r.failures.Count -eq 0){ Ok ("live catalogue is internally consistent ({0} recipes)" -f $r.checked) }
  else {
    Bad ("live catalogue: {0} structural failure(s)" -f $r.failures.Count)
    $r.failures | Select-Object -First 40 | ForEach-Object { Write-Output ("        " + $_) }
    if($r.failures.Count -gt 40){ Write-Output ("        ... and {0} more" -f ($r.failures.Count-40)) }
    [IO.File]::WriteAllLines((Join-Path $db 'golden-structural.txt'), @($r.failures), (New-Object Text.UTF8Encoding($false)))
    Write-Output '        full list -> db\golden-structural.txt'
  }
}

# =========================================================================================  [2] FROZEN
if($runAll -or $Frozen -or $Rebaseline){
  Write-Output ''
  Write-Output 'FROZEN - the engine over pinned inputs, byte for byte'
  if(-not (Test-Path $fin)){ Bad 'no fixture at regression-inputs\golden\inputs - run engine\seed-golden-fixture.ps1'; }
  else {
    $manFile = Join-Path $fx 'MANIFEST.json'
    $tmp = NewTemp 'frozen'

    if($Rebaseline){
      $null = New-Item -ItemType Directory $fexp -Force
      Invoke-Engine (Join-Path $fexp 'costed.json') (Join-Path $fexp 'cost-flags.txt') $null | Out-Null
      $inputs = [ordered]@{}
      foreach($f in (Get-ChildItem $fin -Recurse -File | Sort-Object FullName)){ $inputs[$f.FullName.Substring($fin.Length+1)] = (Sha $f.FullName) }
      ([ordered]@{
        _doc            = 'Baseline acceptance record. Inputs are FROZEN; only expected\ is rewritten, and only by -Rebaseline after a human read the diff.'
        accepted_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        engine_sha256   = (Sha $engine)
        expected_costed = (Sha (Join-Path $fexp 'costed.json'))
        expected_flags  = (Sha (Join-Path $fexp 'cost-flags.txt'))
        inputs          = $inputs
      }) | ConvertTo-Json -Depth 5 | Set-Content $manFile -Encoding UTF8
      Write-Output ("  REBASELINED. expected\costed.json accepted for engine {0}" -f (Sha $engine).Substring(0,12))
    }
    elseif(-not (Test-Path $manFile)){ Bad 'no MANIFEST.json - run golden-test.ps1 -Rebaseline once to accept a baseline' }
    else {
      $man = Get-Content $manFile -Raw | ConvertFrom-Json

      # (a) the fixture itself must not have moved. An edited input makes a correct engine look broken,
      #     which is the failure mode that turns a red test into a test nobody reads.
      $drift = New-Object System.Collections.Generic.List[string]
      foreach($p in $man.inputs.PSObject.Properties){
        $full = Join-Path $fin $p.Name
        if(-not (Test-Path $full)){ $drift.Add("missing: $($p.Name)") } elseif((Sha $full) -ne $p.Value){ $drift.Add("edited: $($p.Name)") }
      }
      foreach($f in (Get-ChildItem $fin -Recurse -File)){ $rel = $f.FullName.Substring($fin.Length+1); if(-not $man.inputs.PSObject.Properties[$rel]){ $drift.Add("added: $rel") } }
      if($drift.Count -eq 0){ Ok ("frozen inputs intact ({0} files)" -f @($man.inputs.PSObject.Properties).Count) }
      else { Bad ('the FROZEN inputs changed - the fixture, not the engine, moved: ' + ($drift -join '; ')) }

      # (b) the run
      $got = Join-Path $tmp 'costed.json'; $gotF = Join-Path $tmp 'cost-flags.txt'
      Invoke-Engine $got $gotF $null | Out-Null
      $engMoved = ((Sha $engine) -ne $man.engine_sha256)
      if((Sha $got) -eq $man.expected_costed){
        if($engMoved){ Ok 'output byte-identical to the baseline (engine has changed since acceptance - the change is output-neutral)' }
        else { Ok 'output byte-identical to the baseline' }
      } else {
        Bad 'output DIFFERS from the frozen baseline - inputs did not move, so the engine did'
        $exp = @((Get-Content (Join-Path $fexp 'costed.json') -Raw | ConvertFrom-Json))
        $now = @((Get-Content $got -Raw | ConvertFrom-Json))
        $eh=@{}; foreach($x in $exp){ $eh[[string]$x.slug] = ($x | ConvertTo-Json -Depth 8 -Compress) }
        $nh=@{}; foreach($x in $now){ $nh[[string]$x.slug] = ($x | ConvertTo-Json -Depth 8 -Compress) }
        foreach($s in ($eh.Keys | Sort-Object)){
          if(-not $nh.ContainsKey($s)){ Write-Output "        gone: $s" }
          elseif($eh[$s] -ne $nh[$s]){ Write-Output "        changed: $s" }
        }
        foreach($s in ($nh.Keys | Sort-Object)){ if(-not $eh.ContainsKey($s)){ Write-Output "        new: $s" } }
        Copy-Item $got (Join-Path $db 'golden-frozen-actual.json') -Force
        Write-Output '        actual -> db\golden-frozen-actual.json. If the change is intended: golden-test.ps1 -Rebaseline'
      }
      if((Sha $gotF) -eq $man.expected_flags){ Ok 'cost-flags identical (all five flag branches still reachable)' }
      else { Bad 'cost-flags DIFFER from the frozen baseline'; Get-Content $gotF | ForEach-Object { Write-Output ("        " + $_) } }

      # (c) must-fire: a lane that cannot see an engine-visible change is not a lane. Perturb ONE input
      #     in a COPY of the fixture and demand the output moves.
      $pt = NewTemp 'perturb'
      Copy-Item $fin (Join-Path $pt 'inputs') -Recurse -Force
      $pin = Join-Path $pt 'inputs'
      $pIng = Join-Path $pin 'db\ingredients.json'
      $rowsP = @((Get-Content $pIng -Raw | ConvertFrom-Json))
      $victim = @($rowsP | Where-Object { $_.buy_pkg_g -gt 0 } | Sort-Object item) | Select-Object -First 1
      $victim.buy_pkg_g = [double]$victim.buy_pkg_g + 37
      $rowsP | ConvertTo-Json -Depth 6 | Set-Content $pIng -Encoding UTF8
      $pOut = Join-Path $pt 'costed.json'
      & $engine -DbRoot (Join-Path $pin 'db') -GroceryOut (Join-Path $pin 'grocery-out') -OutFile $pOut -FlagsFile (Join-Path $pt 'flags.txt') | Out-Null
      if((Sha $pOut) -ne $man.expected_costed){ Ok ("FIRES when an input moves (" + $victim.item + " package +37 g)") }
      else { Bad 'the frozen lane did NOT notice a changed package size - it is comparing nothing' }

      # (d) the -Slugs splice, both directions. This is the code that changed on 2026-08-06: it could only
      #     ever REPLACE an existing row, so a brand-new recipe was costed and then silently dropped.
      $sl = 'ranch-chicken-burrito'
      $expRows = @((Get-Content (Join-Path $fexp 'costed.json') -Raw | ConvertFrom-Json))
      $expRow  = @($expRows | Where-Object { $_.slug -eq $sl }) | Select-Object -First 1
      if(-not $expRow){ Bad "splice test slug '$sl' is not in the baseline" }
      else {
        # REPLACE: the row exists -> row count unchanged, content unchanged
        $rp = Join-Path $tmp 'splice-replace.json'
        Copy-Item (Join-Path $fexp 'costed.json') $rp -Force
        $o1 = Invoke-Engine $rp (Join-Path $tmp 'sr-flags.txt') @($sl)
        $after = @((Get-Content $rp -Raw | ConvertFrom-Json))
        $row1  = @($after | Where-Object { $_.slug -eq $sl }) | Select-Object -First 1
        if($after.Count -eq $expRows.Count -and ($row1|ConvertTo-Json -Depth 8 -Compress) -eq ($expRow|ConvertTo-Json -Depth 8 -Compress)){
          Ok ("-Slugs REPLACE: {0} rows in, {0} out, row unchanged" -f $expRows.Count)
        } else { Bad ("-Slugs REPLACE changed the catalogue: {0} rows -> {1}" -f $expRows.Count, $after.Count) }

        # APPEND: pull the row out first, so the targeted recost has nothing to overwrite. Before the
        # 2026-08-06 fix this run reported success and wrote a file that was still missing the recipe.
        $ap = Join-Path $tmp 'splice-append.json'
        @($expRows | Where-Object { $_.slug -ne $sl }) | ConvertTo-Json -Depth 7 | Out-File $ap -Encoding utf8
        $o2 = Invoke-Engine $ap (Join-Path $tmp 'sa-flags.txt') @($sl)
        $after2 = @((Get-Content $ap -Raw | ConvertFrom-Json))
        $row2   = @($after2 | Where-Object { $_.slug -eq $sl }) | Select-Object -First 1
        if($after2.Count -ne $expRows.Count -or -not $row2){
          Bad ("-Slugs APPEND dropped the new recipe: {0} rows, row present = {1}" -f $after2.Count, [bool]$row2)
        } elseif(($row2|ConvertTo-Json -Depth 8 -Compress) -ne ($expRow|ConvertTo-Json -Depth 8 -Compress)){
          Bad '-Slugs APPEND restored the row but its contents differ from a full run'
        } elseif(($o2 -join ' ') -notmatch '0 replaced, 1 newly added'){
          Bad ("-Slugs APPEND landed the row but did not report it as newly added: " + (($o2 | Where-Object { $_ -match 'targeted recost' }) -join ' '))
        } else { Ok '-Slugs APPEND: a recipe with no row to replace is added, not dropped' }
      }
      # this runs daily; leaving four scratch dirs behind per run adds up
      foreach($d in @($tmp,$pt)){ if($d -and (Test-Path $d)){ Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } }
    }
  }
}

# ====================================================================================  [3] PROVENANCE
if($Provenance){
  Write-Output ''
  Write-Output 'PROVENANCE - the 2026-07-26 port comparison against the retired per-run engines'
  Write-Output '  INFORMATIONAL ONLY. It diffs today''s db\costed.json against outputs frozen on 2026-07-26,'
  Write-Output '  so every price move and every deliberate db edit since then shows up as a diff. It cannot'
  Write-Output '  pass and is not counted in the result. The port itself is recorded in engine\README.md.'
  if(-not $Force){ Write-Output '  (add -Force to actually run it)' }
  else {
    function Slugify([string]$s){ (($s.ToLower() -replace "[^a-z0-9]+","-").Trim('-')) }
    $new=@{}
    foreach($r in (Get-Content (Join-Path $db 'costed.json') -Raw | ConvertFrom-Json)){ $new[[string]$r.slug]=$r }
    $specSlugs=@{}
    foreach($sf in (Get-ChildItem (Join-Path $db 'recipes\*.json'))){ $specSlugs[$sf.BaseName]=1 }
    $totalDiffs=New-Object System.Collections.Generic.List[string]
    $lineDiffs=New-Object System.Collections.Generic.List[string]
    $checked=0; $matched=0
    foreach($run in 'r100','r300','orig'){
      $old = Get-Content (Join-Path $mp "archive\$run\recipes-costed.json") -Raw | ConvertFrom-Json
      foreach($o in $old){
        $slug = if($o.PSObject.Properties.Name -contains 'slug' -and $o.slug){ [string]$o.slug } else { $null }
        if(-not $slug){
          $cand = Slugify ([string]$o.proposed_name)
          if($specSlugs.ContainsKey($cand)){ $slug=$cand }
          else {
            $hit = ($new.Values | Where-Object { $_.proposed_name -eq $o.proposed_name } | Select-Object -First 1)
            if($hit){ $slug = [string]$hit.slug }
          }
        }
        if(-not $slug -or -not $new.ContainsKey($slug)){ $totalDiffs.Add(("[$run] NO NEW MATCH for '{0}'" -f $o.proposed_name)); continue }
        $n = $new[$slug]; $checked++; $ok=$true
        foreach($f in 'cost_batch','cost_batch_true','cost_pantry_add','cost_first_run'){
          $ov=[double]$o.$f; $nv=[double]$n.$f
          if([math]::Abs($ov-$nv) -gt 0.005){ $ok=$false; $totalDiffs.Add(("[$run] {0} .{1}: old {2} new {3}" -f $slug,$f,$ov,$nv)) }
        }
        $om=@{}; foreach($l in $o.lines){ $om[[string]$l.item]=$l }
        foreach($l in $n.lines){
          $ol = $om[[string]$l.item]
          if(-not $ol){ $ok=$false; $lineDiffs.Add(("[$run] {0} :: {1} :: line only in NEW" -f $slug,$l.item)); continue }
          foreach($f in 'buy_n','buy_cost','pkg_g','starter_n','starter_cost','starter_pkg_g','util_cost'){
            $ov = $ol.PSObject.Properties[$f].Value; $nv = $l.PSObject.Properties[$f].Value
            $ovS = if($null -eq $ov){''}else{('{0:0.###}' -f [double]$ov)}
            $nvS = if($null -eq $nv){''}else{('{0:0.###}' -f [double]$nv)}
            if($ovS -ne $nvS){ $ok=$false; $lineDiffs.Add(("[$run] {0} :: {1} .{2}: old '{3}' new '{4}'" -f $slug,$l.item,$f,$ovS,$nvS)) }
          }
        }
        foreach($l in $o.lines){ if(-not ($n.lines | Where-Object { $_.item -eq $l.item })){ $ok=$false; $lineDiffs.Add(("[$run] {0} :: {1} :: line only in OLD" -f $slug,$l.item)) } }
        if($ok){ $matched++ }
      }
    }
    Write-Output ("  checked {0} recipes; exact match {1}; with diffs {2}" -f $checked,$matched,($checked-$matched))
    $all = @($totalDiffs) + @($lineDiffs)
    $structural = @($all | Where-Object { $_ -match '\.(buy_n|pkg_g|starter_n|starter_pkg_g):' -or $_ -match 'line only in (NEW|OLD)' -or $_ -match 'NO NEW MATCH' })
    $price      = @($all | Where-Object { $structural -notcontains $_ })
    Write-Output ("  PRICE-DRIVEN {0}   STRUCTURAL {1}" -f $price.Count, $structural.Count)
    $outp = @('==== STRUCTURAL (package counts/sizes, missing lines) ====') + $structural +
            @('', '==== PRICE-DRIVEN (expected: baseline frozen 2026-07-26) ====') + $price
    [IO.File]::WriteAllLines((Join-Path $db 'golden-diffs.txt'), $outp, (New-Object Text.UTF8Encoding($false)))
    Write-Output '  full detail -> db\golden-diffs.txt'
  }
}

Write-Output ''
if($Rebaseline -and $failed -eq 0){ Write-Output 'GOLDEN: baseline accepted.'; exit 0 }
Write-Output ("GOLDEN: {0} passed, {1} failed" -f $pass, $failed)
if($failed -gt 0){ exit 2 }
exit 0
