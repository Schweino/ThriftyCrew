# gated-republish-lib.ps1 - the daily chain's recipe republish, gated per slug (backlog I234, 2026-09-18).
#
# WHAT IT REPLACES. grocery\check-ad-cycles.ps1's close-the-loop block ran engine\build-cards.ps1 over the
# re-anchored slugs and then engine\publish.ps1 over the SAME list whatever build-cards returned. build-cards
# catches a failing card and carries on, so a slug whose rebuild threw still had its OLD card in db\built,
# and publish sent that old card to the live page: the stale version, under a run that logged the failure
# and published anyway. That path also never met meal-prep\pipeline\propagate-recipes.ps1, so the allergen
# check I233 put between build and publish there (Invoke-GatedPublish) never ran on it.
#
# WHAT IT DOES, in order, and each step can only REMOVE slugs from the set that reaches publish:
#   1. a slug with no spec is held (build-cards would silently skip it and publish would send its old card);
#   2. build-cards runs over the rest, and only a slug it reports as built is kept. Its per-slug failures are
#      its "  X <slug> :: <why>" lines. If its summary line is absent, or does not add up to what it was
#      asked to build, NO slug counts as rebuilt: a build that cannot account for itself is a could-not-look;
#   3. pipeline\audit-allergen-line.ps1, the same judge propagate runs, reads each rebuilt card as it sits on
#      disk, and a card it finds missing or wrong is held. If its answer cannot be read, every card is held;
#   4. publish runs once, over what is left, and never over a held slug.
# Everything held is returned by name with its reason, so the chain can report it and keep it pending.
#
# PER SLUG, NOT ALL OR NOTHING, and that is a deliberate difference from propagate. propagate publishes a
# wave and its collateral, where one refusal should stop the lot for a human. The daily republish carries
# every card whose price moved overnight; holding all of them for one bad card would leave every other live
# page on yesterday's cost, which is the error this loop exists to close. A held slug stays in
# republish-pending.txt and is retried and re-reported every run until it builds and passes.
#
# Build and Publish are SCRIPTBLOCKS taking the slug list, so the self-test drives the real function and the
# real allergen audit with stubs that never touch db\built or Ghost. IN-PROCESS: -Slugs is [string[]] and a
# `powershell -File` hop would pass only the first element (engine\README.md).
#
# NO param() BLOCK: dot-sourced under PS 5.1 it would reset the caller's own switches.
# Dot-source:  . (Join-Path $repo 'meal-prep\lib\gated-republish-lib.ps1')
# Self-test:   powershell -NoProfile -File meal-prep\lib\gated-republish-lib.ps1 -SelfTest

$__gatedRepublishSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
$script:GatedRepublishHere = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Read-TcBuildCardsReport {
  # Reads engine\build-cards.ps1's own output. Returns { Complete; Built; Total; Failed = ordered slug -> why; Why }.
  # Complete is false when the summary line is missing or the X lines do not match its error count.
  param([string[]]$Lines)
  $failed = [ordered]@{}
  $summary = $null
  foreach ($raw in @($Lines)) {
    $l = [string]$raw
    if ($l -match '^built (\d+)/(\d+)\s+errors (\d+)\s*$') { $summary = $Matches }
    elseif ($l -match '^  X (\S+) :: (.*)$') { $failed[$Matches[1]] = $Matches[2] }
  }
  if ($null -eq $summary) {
    return [pscustomobject]@{ Complete = $false; Built = 0; Total = 0; Failed = $failed; Why = 'build-cards printed no "built N/M errors K" line, so it did not finish' }
  }
  $b = [int]$summary[1]; $t = [int]$summary[2]; $e = [int]$summary[3]
  if ($e -ne $failed.Count -or ($b + $e) -ne $t) {
    return [pscustomobject]@{ Complete = $false; Built = $b; Total = $t; Failed = $failed; Why = ("build-cards reported built {0}/{1} errors {2} but named {3} failed slug(s), so its failures cannot be attributed" -f $b, $t, $e, $failed.Count) }
  }
  return [pscustomobject]@{ Complete = $true; Built = $b; Total = $t; Failed = $failed; Why = '' }
}

function Invoke-TcGatedRepublish {
  param(
    [string[]]$Slugs,
    [string]$RecipesDir,
    [string]$BuiltDir,
    [scriptblock]$Build,
    [scriptblock]$Publish,
    [string]$AuditScript
  )
  # Defaults are meal-prep's own live directories, so a caller in another module names no path inside this one.
  $mpRoot = Split-Path $script:GatedRepublishHere -Parent
  if (-not $AuditScript) { $AuditScript = Join-Path $mpRoot 'pipeline\audit-allergen-line.ps1' }
  if (-not $RecipesDir)  { $RecipesDir  = Join-Path $mpRoot 'db\recipes' }
  if (-not $BuiltDir)    { $BuiltDir    = Join-Path $mpRoot 'db\built' }
  $want = @($Slugs | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
  $held = New-Object System.Collections.Generic.List[object]

  # 1. no spec, no build: build-cards filters to specs it can find and says nothing about the rest
  $toBuild = @()
  foreach ($s in $want) {
    if (Test-Path -LiteralPath (Join-Path $RecipesDir ($s + '.json'))) { $toBuild += $s }
    else { $held.Add([pscustomobject]@{ slug = $s; stage = 'build'; why = 'no spec in db\recipes' }) }
  }

  # 2. build, and keep only what build-cards says it built
  $bLines = @(); $bRc = $null; $built = @()
  if ($toBuild.Count) {
    $bThrew = ''
    $global:LASTEXITCODE = 0
    try { $bLines = @(& $Build $toBuild | ForEach-Object { [string]$_ }) } catch { $bThrew = $_.Exception.Message }
    $bRc = $LASTEXITCODE
    $rep = Read-TcBuildCardsReport -Lines $bLines
    if ($bThrew) {
      foreach ($s in $toBuild) { $held.Add([pscustomobject]@{ slug = $s; stage = 'build'; why = ('build-cards threw: ' + $bThrew) }) }
    } elseif (-not $rep.Complete -or $rep.Total -ne $toBuild.Count) {
      $why = if (-not $rep.Complete) { $rep.Why } else { ("build-cards reported {0} spec(s) for {1} asked" -f $rep.Total, $toBuild.Count) }
      foreach ($s in $toBuild) { $held.Add([pscustomobject]@{ slug = $s; stage = 'build'; why = $why }) }
    } else {
      foreach ($s in $toBuild) {
        if ($rep.Failed.Contains($s)) { $held.Add([pscustomobject]@{ slug = $s; stage = 'build'; why = ('build failed: ' + $rep.Failed[$s]) }) }
        else { $built += $s }
      }
    }
  }

  # 3. the allergen line, on the card that is about to ship
  $aLines = @(); $eligible = @()
  if ($built.Count) {
    $global:LASTEXITCODE = 0
    $parsed = $null; $aWhy = ''
    try {
      $aLines = @(& $AuditScript -Slugs $built -RecipesDir $RecipesDir -BuiltDir $BuiltDir -Json | ForEach-Object { [string]$_ })
      $parsed = ($aLines -join "`n") | ConvertFrom-Json
    } catch { $aWhy = $_.Exception.Message }
    if ($null -eq $parsed -or -not ($parsed.PSObject.Properties.Name -contains 'findings')) {
      if (-not $aWhy) { $aWhy = 'its -Json answer did not parse' }
      foreach ($s in $built) { $held.Add([pscustomobject]@{ slug = $s; stage = 'allergen'; why = ('allergen check could not look: ' + $aWhy) }) }
    } else {
      $bad = @{}
      foreach ($x in @($parsed.findings)) { if ($x -and $x.slug) { $bad[[string]$x.slug] = ([string]$x.kind + ': ' + [string]$x.detail) } }
      foreach ($s in $built) {
        if ($bad.ContainsKey($s)) { $held.Add([pscustomobject]@{ slug = $s; stage = 'allergen'; why = ('allergen line ' + $bad[$s]) }) }
        else { $eligible += $s }
      }
    }
  }

  # 4. publish once, over the survivors only
  $pOut = @(); $pRc = $null; $invoked = $false
  if ($eligible.Count) {
    $invoked = $true
    $global:LASTEXITCODE = 0
    $pOut = @(& $Publish $eligible)
    $pRc = $LASTEXITCODE
  }
  return [pscustomobject]@{
    Requested       = $want
    Built           = $built
    Eligible        = $eligible
    Held            = @($held.ToArray())
    BuildLines      = $bLines
    BuildRc         = $bRc
    AuditLines      = $aLines
    PublishInvoked  = $invoked
    PublishOut      = $pOut
    PublishRc       = $pRc
  }
}

if ($__gatedRepublishSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:grCases = 0; $script:grFail = 0
  function Test-GrCase([string]$Name, [bool]$Ok, [string]$Got) {
    $script:grCases++
    if ($Ok) { Write-Output ('  ok    ' + $Name) } else { Write-Output ('  FAIL  ' + $Name + '   got: ' + $Got); $script:grFail++ }
  }
  $mp = Split-Path $script:GatedRepublishHere -Parent
  $repo = Split-Path $mp -Parent
  . (Join-Path $mp 'lib\allergen-lib.ps1')
  $tmp = Join-Path $env:TEMP ('grl-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  $savedJournal = $env:TC_WRITE_JOURNAL; $savedStage = $env:TC_STAGE_WRITES
  $env:TC_WRITE_JOURNAL = $null; $env:TC_STAGE_WRITES = $null
  try {
    $rec = Join-Path $tmp 'recipes'; $blt = Join-Path $tmp 'built'
    New-Item -ItemType Directory -Force $rec, $blt | Out-Null
    # Two ingredients audit-allergen-line's own self-test pins in the live table (Worcestershire: fish,
    # Oyster Sauce: shellfish). The expected line is rendered through the one Format-TcAllergenLine, the way
    # build-card2 renders it, so the fixture cannot drift from the rule.
    $table = (Get-TcAllergenTable -Path (Join-Path $mp 'db\allergens.json')).Items
    $ing = @([pscustomobject]@{ item = 'Worcestershire Sauce'; grams = 30 }, [pscustomobject]@{ item = 'Oyster Sauce'; grams = 40 })
    $specJson = '{"slug":"SLUG","scaler":{"ing":[{"item":"Worcestershire Sauce","grams":30},{"item":"Oyster Sauce","grams":40}]}}'
    function New-GrSpec([string]$Slug) { Set-Content -LiteralPath (Join-Path $rec ($Slug + '.json')) -Encoding UTF8 -Value ($specJson.Replace('SLUG', $Slug)) }
    function Get-GrRightCard([string]$Slug) { '<ul class="smp-ing"><li>x</li></ul>' + (Format-TcAllergenLine (Get-TcRecipeAllergens $ing $table) $Slug) + '<!--TC-PAYWALL-->' }
    function Get-GrStaleCard([string]$Slug) {
      # rendered before the Worcestershire was added, so it omits the fish
      '<ul class="smp-ing"><li>x</li></ul>' + (Format-TcAllergenLine (Get-TcRecipeAllergens @($ing | Where-Object { $_.item -ne 'Worcestershire Sauce' }) $table) $Slug) + '<!--TC-PAYWALL-->'
    }
    # A STUB build-cards: writes the card it is told to for each slug and prints build-cards' own output
    # shape. $script:grBuildPlan maps slug -> card html, or -> $null to fail that slug the way build-card2's
    # throw does: the OLD card is left on disk and an X line names it.
    $script:grBuildPlan = @{}
    $script:grPublished = @()
    $script:grPublishCalls = 0
    $stubBuild = {
      param($s)
      $ok = 0; $err = @()
      foreach ($x in $s) {
        $card = $script:grBuildPlan[$x]
        if ($null -eq $card) { $err += ('{0} :: fixture build failure' -f $x) }
        else { Set-Content -LiteralPath (Join-Path $blt ($x + '.body.html')) -Encoding UTF8 -Value $card; $ok++ }
      }
      Write-Output ('built {0}/{1}  errors {2}' -f $ok, @($s).Count, $err.Count)
      $err | ForEach-Object { Write-Output ('  X ' + $_) }
    }
    $stubPublish = { param($s) $script:grPublishCalls++; $script:grPublished += @($s); 'published+verified OK: ' + @($s).Count + ' / ' + @($s).Count; 'PUBLISH-UNSTAMPABLE: ' }
    function Invoke-GrRun([string[]]$Slugs) {
      $script:grPublished = @(); $script:grPublishCalls = 0
      return (Invoke-TcGatedRepublish -Slugs $Slugs -RecipesDir $rec -BuiltDir $blt -Build $stubBuild -Publish $stubPublish)
    }

    # ---- MUST FIRE: a slug whose rebuild FAILED is not published, even though an old card sits on disk ----
    New-GrSpec 'gr-fails'; New-GrSpec 'gr-good'
    Set-Content -LiteralPath (Join-Path $blt 'gr-fails.body.html') -Encoding UTF8 -Value (Get-GrRightCard 'gr-fails')   # yesterday's card, allergen line and all
    $script:grBuildPlan = @{ 'gr-fails' = $null; 'gr-good' = (Get-GrRightCard 'gr-good') }
    $r = Invoke-GrRun @('gr-fails', 'gr-good')
    $heldFail = @($r.Held | Where-Object { $_.slug -eq 'gr-fails' })
    Test-GrCase 'MUST FIRE  a slug whose rebuild failed is NOT published, though its old card is on disk and would pass the allergen check' `
      (($script:grPublished -notcontains 'gr-fails') -and $heldFail.Count -eq 1 -and $heldFail[0].stage -eq 'build' -and $heldFail[0].why -match 'fixture build failure') `
      ('published=' + ($script:grPublished -join ',') + ' held=' + (@($r.Held | ForEach-Object { $_.slug + '/' + $_.stage }) -join ','))
    Test-GrCase 'CLEAN TWIN ...and its neighbour that did rebuild still publishes, once' `
      ($script:grPublishCalls -eq 1 -and (@($script:grPublished) -join ',') -eq 'gr-good') ('calls=' + $script:grPublishCalls + ' published=' + ($script:grPublished -join ','))

    # ---- MUST FIRE: a rebuilt card with a WRONG allergen line is refused before publish ------------------
    New-GrSpec 'gr-wrongline'
    $script:grBuildPlan = @{ 'gr-wrongline' = (Get-GrStaleCard 'gr-wrongline'); 'gr-good' = (Get-GrRightCard 'gr-good') }
    $r = Invoke-GrRun @('gr-wrongline', 'gr-good')
    $heldWrong = @($r.Held | Where-Object { $_.slug -eq 'gr-wrongline' })
    Test-GrCase 'MUST FIRE  a card whose allergen line disagrees with its ingredients is held BEFORE publish, by name and reason' `
      (($script:grPublished -notcontains 'gr-wrongline') -and $heldWrong.Count -eq 1 -and $heldWrong[0].stage -eq 'allergen' -and $heldWrong[0].why -match 'disagrees') `
      ('published=' + ($script:grPublished -join ',') + ' held=' + (@($r.Held | ForEach-Object { $_.slug + '/' + $_.stage + '/' + $_.why }) -join ' ; '))
    $script:grBuildPlan = @{ 'gr-wrongline' = '<ul class="smp-ing"><li>x</li></ul><!--TC-PAYWALL-->' }
    $r = Invoke-GrRun @('gr-wrongline')
    Test-GrCase 'MUST FIRE  a card with NO allergen line is held too, and publish is never called when nothing survives' `
      ($script:grPublishCalls -eq 0 -and -not $r.PublishInvoked -and @($r.Held | Where-Object { $_.slug -eq 'gr-wrongline' -and $_.why -match 'missing' }).Count -eq 1) `
      ('calls=' + $script:grPublishCalls + ' held=' + (@($r.Held | ForEach-Object { $_.slug + '/' + $_.why }) -join ' ; '))

    # ---- CLEAN TWIN: a good rebuild publishes, exactly once, and its output comes back -------------------
    $script:grBuildPlan = @{ 'gr-good' = (Get-GrRightCard 'gr-good') }
    $r = Invoke-GrRun @('gr-good')
    Test-GrCase 'CLEAN TWIN a good rebuild reaches publish exactly once, with nothing held, and publish''s output is returned' `
      ($script:grPublishCalls -eq 1 -and (@($script:grPublished) -join ',') -eq 'gr-good' -and @($r.Held).Count -eq 0 -and (@($r.PublishOut) -join '|') -match 'published\+verified OK: 1 / 1') `
      ('calls=' + $script:grPublishCalls + ' held=' + @($r.Held).Count + ' out=' + (@($r.PublishOut) -join '|'))

    # ---- MUST FIRE: a slug with no spec is held, never handed to publish ------------------------------
    $r = Invoke-GrRun @('gr-nospec', 'gr-good')
    Test-GrCase 'MUST FIRE  a slug with no spec is held (build-cards would skip it silently and publish would send its old card)' `
      (($script:grPublished -notcontains 'gr-nospec') -and @($r.Held | Where-Object { $_.slug -eq 'gr-nospec' -and $_.why -match 'no spec' }).Count -eq 1) `
      ('published=' + ($script:grPublished -join ',') + ' held=' + (@($r.Held | ForEach-Object { $_.slug }) -join ','))

    # ---- MUST FIRE: a build that cannot account for itself rebuilt NOTHING -----------------------------
    $mute = { param($s) Write-Output 'something went wrong before the summary' }
    $script:grPublished = @(); $script:grPublishCalls = 0
    $r = Invoke-TcGatedRepublish -Slugs @('gr-good') -RecipesDir $rec -BuiltDir $blt -Build $mute -Publish $stubPublish
    Test-GrCase 'MUST FIRE  a build-cards run with no summary line counts as having rebuilt nothing, so nothing publishes' `
      ($script:grPublishCalls -eq 0 -and @($r.Held | Where-Object { $_.slug -eq 'gr-good' -and $_.why -match 'did not finish' }).Count -eq 1) `
      ('calls=' + $script:grPublishCalls + ' held=' + (@($r.Held | ForEach-Object { $_.slug + '/' + $_.why }) -join ' ; '))
    $throwing = { param($s) throw 'fixture: build-cards died' }
    $script:grPublished = @(); $script:grPublishCalls = 0
    $r = Invoke-TcGatedRepublish -Slugs @('gr-good') -RecipesDir $rec -BuiltDir $blt -Build $throwing -Publish $stubPublish
    Test-GrCase 'MUST FIRE  a build-cards run that throws rebuilt nothing, and the throw is the reason recorded' `
      ($script:grPublishCalls -eq 0 -and @($r.Held | Where-Object { $_.why -match 'build-cards died' }).Count -eq 1) `
      ('calls=' + $script:grPublishCalls + ' held=' + (@($r.Held | ForEach-Object { $_.why }) -join ' ; '))

    # ---- MUST FIRE: an allergen check whose answer cannot be read holds every card ---------------------
    $brokenAudit = Join-Path $tmp 'broken-audit.ps1'
    Set-Content -LiteralPath $brokenAudit -Encoding UTF8 -Value 'param($Slugs, $RecipesDir, $BuiltDir, [switch]$Json) Write-Output "not json"; exit 1'
    $script:grBuildPlan = @{ 'gr-good' = (Get-GrRightCard 'gr-good') }
    $script:grPublished = @(); $script:grPublishCalls = 0
    $r = Invoke-TcGatedRepublish -Slugs @('gr-good') -RecipesDir $rec -BuiltDir $blt -Build $stubBuild -Publish $stubPublish -AuditScript $brokenAudit
    Test-GrCase 'MUST FIRE  an allergen check that cannot be read is a could-not-look: the card is held, never passed' `
      ($script:grPublishCalls -eq 0 -and @($r.Held | Where-Object { $_.stage -eq 'allergen' -and $_.why -match 'could not look' }).Count -eq 1) `
      ('calls=' + $script:grPublishCalls + ' held=' + (@($r.Held | ForEach-Object { $_.why }) -join ' ; '))

    # ---- SOURCE PINS: the parser reads build-cards' real output shape, and the chain uses this path ---------
    # Needles by concatenation, so this file cannot satisfy them by quoting them.
    $bcSrc = [IO.File]::ReadAllText((Join-Path $mp 'engine\build-cards.ps1'))
    Test-GrCase 'MUST FIRE  engine\build-cards.ps1 still prints the summary and X lines this parser reads' `
      ($bcSrc.Contains('"built {0}/{1}  errors ' + '{2}"') -and $bcSrc.Contains('("  X " + ' + '$_)') -and $bcSrc.Contains('"{0} :: ' + '{1}"')) 'build-cards output shape moved'
    $cacSrc = [IO.File]::ReadAllText((Join-Path $repo 'grocery\check-ad-cycles.ps1'))
    $pubNeedle = "engine\" + "publish.ps1'"
    $iGate = $cacSrc.IndexOf('Invoke-TcGated' + 'Republish -Slugs')
    # The block itself, not only its position: a direct call placed just after the gated one sits in the same
    # place and would pass a position check (it did, on the first mutation of this case).
    $blockNeedle = '-Publish { param($s) & ''.\' + $pubNeedle + ' -Slugs $s }'
    $iPub = $cacSrc.IndexOf($blockNeedle)
    $nPub = [regex]::Matches($cacSrc, [regex]::Escape($pubNeedle)).Count
    Test-GrCase 'MUST FIRE  grocery\check-ad-cycles.ps1 reaches publish.ps1 only as the Publish block of this gated call' `
      ($iGate -ge 0 -and $nPub -eq 1 -and $iPub -gt $iGate -and ($iPub - $iGate) -lt 600) ("gate@{0} publishBlock@{1} publishRefs={2}" -f $iGate, $iPub, $nPub)
  } finally {
    $env:TC_WRITE_JOURNAL = $savedJournal; $env:TC_STAGE_WRITES = $savedStage
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:grCases -lt 11) { Write-Output ("GATED-REPUBLISH SELF-TEST FAIL: ran {0} of 11 case(s)" -f $script:grCases); exit 1 }
  if ($script:grFail) { Write-Output ("GATED-REPUBLISH SELF-TEST FAIL: {0} of {1} case(s)" -f $script:grFail, $script:grCases); exit 1 }
  Write-Output ("GATED-REPUBLISH SELF-TEST PASS: {0} of {0} case(s)" -f $script:grCases)
  exit 0
}
