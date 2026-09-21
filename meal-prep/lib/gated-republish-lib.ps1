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

# ---- COST-ONLY (Brad's ruling, 2026-09-19) -------------------------------------------------------------
# On a page whose cost moved, the daily update changes ONLY the cost. Every other pending change a rebuild
# would carry (the allergen line, I44's paywall claim, the rotating footer, retitled specs, anything later)
# waits for the catalogue republish Brad approves, never rides a price move.
#
# WHAT MOVES WHEN ONLY COST MOVES, measured 2026-09-19 through the real build-card2.ps1 on three specs
# (chicken-rice-and-broccoli, healthy-hamburger-helper, al-pastor-pork-taco-bowl-with-cilantro-lime-rice):
# every costed price scaled, and the first line's prices x1.5 on their own, with the spec's two re-anchored
# machine fields moved to match. With the cost-composition block masked, body and head were byte-identical
# in all 6 of 6 comparisons. Prose prices are hydrated live (lib\render-tokens.ps1), so the block is the only
# baked cost a card carries. That made a cost-only card BUILDABLE: the live card with its cost block swapped.
#
# THE LIVE CARD IS KNOWN ONLY WHEN THE JOURNAL SAYS SO. db\published-hashes.json holds, per slug, the hash
# engine\publish.ps1 computed over body, head, name and description when it last PUT the page, and those are
# every field it sends. So the card on disk before the rebuild IS the live card exactly when that hash,
# computed over it and today's name and description, equals the journal. Then the cost-only card is that
# card with its one cost block replaced by the rebuild's. When it is not provable (no journal entry, a card
# on disk that is not the one live, a retitled spec, a cost block that is not exactly one), the slug is HELD:
# never published, named with its reason, and kept pending. A could-not-look is never a pass.
function Get-TcCostBlockMatch([string]$Body) {
  return [regex]::Matches($Body, "<div class='smp-comp'>.*?<p class='smp-comp-pay'>.*?</p></div>", [Text.RegularExpressions.RegexOptions]::Singleline)
}
# engine\publish.ps1's change-gate hash, COPIED (its body/head/name/description order and its SHA1 over the
# UTF-8 bytes). The self-test pins both spellings against publish.ps1's source.
function Get-TcPublishHash([string]$Body, [string]$Head, [string]$Name, [string]$Desc) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Body + "`0" + $Head + "`0" + $Name + "`0" + $Desc))) -replace '-', '')
}
function Get-TcPublishedNameDesc([string]$SpecPath) {
  # The name and description exactly as publish.ps1 sends them: tokens expanded, then the card's own price
  # moved to live hydration. Dot-sourced HERE so render-tokens' param() block binds in this function's scope.
  . (Join-Path $script:GatedRepublishHere 'render-tokens.ps1')
  $spec = [IO.File]::ReadAllText($SpecPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $spec = Expand-SpecProse $spec
  $spec = Move-SpecPriceToReleaseHydration $spec
  return [pscustomobject]@{ Name = [string]$spec.name; Desc = [string]$spec.head.description }
}
function Get-TcCostOnlyCard {
  <# PURE apart from reading one spec. Returns { Ok; Body; Head; Why }. Ok means Body/Head is the live card with
     only its cost block replaced; otherwise Why says why the live card could not be proven or spliced. #>
  param([string]$Slug, $Prior, [string]$NewBody, [string]$SpecPath, $Journal)
  $no = { param($w) [pscustomobject]@{ Ok = $false; Body = $null; Head = $null; Why = $w } }
  if ($null -eq $Prior) { return (& $no 'no card was on disk before the rebuild, so the live page cannot be shown') }
  if ($null -eq $Journal) { return (& $no 'the publish journal could not be read, so the live page cannot be shown') }
  $jp = $Journal.PSObject.Properties[$Slug]
  if ($null -eq $jp) { return (& $no 'the publish journal has no entry for this slug') }
  $nd = Get-TcPublishedNameDesc $SpecPath
  $h = Get-TcPublishHash $Prior.Body $Prior.Head $nd.Name $nd.Desc
  if (-not [string]::Equals($h, [string]$jp.Value, [StringComparison]::Ordinal)) {
    return (& $no 'the card on disk plus today''s title and description is not what the publish journal says is live, so a rebuild would carry every change made since, not only the cost')
  }
  $pm = Get-TcCostBlockMatch $Prior.Body; $nm = Get-TcCostBlockMatch $NewBody
  if ($pm.Count -ne 1 -or $nm.Count -ne 1) { return (& $no ("expected exactly one cost block in each card, found {0} live and {1} rebuilt" -f $pm.Count, $nm.Count)) }
  $body = $Prior.Body.Substring(0, $pm[0].Index) + $nm[0].Value + $Prior.Body.Substring($pm[0].Index + $pm[0].Length)
  return [pscustomobject]@{ Ok = $true; Body = $body; Head = $Prior.Head; Why = '' }
}
function Write-TcCardText([string]$Path, [string]$Text) {
  # keep the file's own BOM choice: build-card2 decides it, and the hash reads decoded text either way
  $bom = $false
  if (Test-Path -LiteralPath $Path) { $b = [IO.File]::ReadAllBytes($Path); $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) }
  [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($bom)))
}

# WHAT A PUBLISH DID NOT SHIP (2026-09-21). engine\publish.ps1 exits 0 whether or not every slug went out: a slug it
# refused, could not create, staged or HELD (the live-price rollout) is named only on its machine line
# `PUBLISH-UNSTAMPABLE: a,b`. The daily chain read exit 0 as "every eligible card republished", logged "loop closed"
# and dropped the held slugs from republish-pending.txt, so the log said a card shipped that never left. Returns
# { Known; Unshipped }: Known is false when the machine line is missing, and then NOTHING may be counted as shipped.
function Get-TcPublishUnshipped {
  param([string[]]$Lines, [string[]]$Eligible)
  $m = @($Lines | Where-Object { [string]$_ -match '^PUBLISH-UNSTAMPABLE:' })
  if (-not $m.Count) { return [pscustomobject]@{ Known = $false; Unshipped = @($Eligible) } }
  $named = @(([string]$m[-1]).Substring('PUBLISH-UNSTAMPABLE:'.Length).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  return [pscustomobject]@{ Known = $true; Unshipped = @($Eligible | Where-Object { $named -contains $_ }) }
}

function Invoke-TcGatedRepublish {
  param(
    [string[]]$Slugs,
    [string]$RecipesDir,
    [string]$BuiltDir,
    [scriptblock]$Build,
    [scriptblock]$Publish,
    [string]$AuditScript,
    [switch]$CostOnly,
    [string]$JournalPath
  )
  # Defaults are meal-prep's own live directories, so a caller in another module names no path inside this one.
  $mpRoot = Split-Path $script:GatedRepublishHere -Parent
  if (-not $AuditScript) { $AuditScript = Join-Path $mpRoot 'pipeline\audit-allergen-line.ps1' }
  if (-not $RecipesDir)  { $RecipesDir  = Join-Path $mpRoot 'db\recipes' }
  if (-not $BuiltDir)    { $BuiltDir    = Join-Path $mpRoot 'db\built' }
  if (-not $JournalPath) { $JournalPath = Join-Path $mpRoot 'db\published-hashes.json' }
  $want = @($Slugs | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
  $held = New-Object System.Collections.Generic.List[object]

  # 1. no spec, no build: build-cards filters to specs it can find and says nothing about the rest
  $toBuild = @()
  foreach ($s in $want) {
    if (Test-Path -LiteralPath (Join-Path $RecipesDir ($s + '.json'))) { $toBuild += $s }
    else { $held.Add([pscustomobject]@{ slug = $s; stage = 'build'; why = 'no spec in db\recipes' }) }
  }

  # 1b. COST-ONLY: remember the card each slug had on disk BEFORE the rebuild overwrites it
  $prior = @{}
  if ($CostOnly) {
    foreach ($s in $toBuild) {
      $pb = Join-Path $BuiltDir ($s + '.body.html'); $ph = Join-Path $BuiltDir ($s + '.head.html')
      if ((Test-Path -LiteralPath $pb) -and (Test-Path -LiteralPath $ph)) {
        $prior[$s] = [pscustomobject]@{ Body = [IO.File]::ReadAllText($pb, [Text.Encoding]::UTF8); Head = [IO.File]::ReadAllText($ph, [Text.Encoding]::UTF8) }
      }
    }
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

  # 2b. COST-ONLY: the card that ships is the live card with its cost block swapped, or nothing at all
  $costOnlyWritten = @()
  if ($CostOnly -and $built.Count) {
    $journal = $null
    try { $journal = [IO.File]::ReadAllText($JournalPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $journal = $null }
    $keep = @()
    foreach ($s in $built) {
      $nbPath = Join-Path $BuiltDir ($s + '.body.html'); $nhPath = Join-Path $BuiltDir ($s + '.head.html')
      $r = $null
      try {
        $newBody = [IO.File]::ReadAllText($nbPath, [Text.Encoding]::UTF8)
        $r = Get-TcCostOnlyCard -Slug $s -Prior $prior[$s] -NewBody $newBody -SpecPath (Join-Path $RecipesDir ($s + '.json')) -Journal $journal
      } catch { $r = [pscustomobject]@{ Ok = $false; Why = ('cost-only check threw: ' + $_.Exception.Message) } }
      if ($r.Ok) {
        Write-TcCardText $nbPath $r.Body
        Write-TcCardText $nhPath $r.Head
        $costOnlyWritten += $s; $keep += $s
      } else {
        # put the card that was on disk back, so db\built does not carry a render nobody published
        if ($null -ne $prior[$s]) { Write-TcCardText $nbPath $prior[$s].Body; Write-TcCardText $nhPath $prior[$s].Head }
        $held.Add([pscustomobject]@{ slug = $s; stage = 'drift'; why = ('not provably cost-only: ' + $r.Why) })
      }
    }
    $built = $keep
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
    CostOnly        = $costOnlyWritten
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

    # ---- COST-ONLY (Brad's ruling, 2026-09-19): a cost move ships the cost and nothing else ---------------
    # A live card (proven by a journal entry hashed the way publish.ps1 hashes it), a rebuild that also carries
    # pending drift (a footer here, standing for the allergen line, the I44 claim or anything else), and a stub
    # publish that records the exact bytes it would have sent. Ghost is never reachable.
    $coRec = Join-Path $tmp 'co-recipes'; $coBlt = Join-Path $tmp 'co-built'; $coJournal = Join-Path $tmp 'co-journal.json'
    New-Item -ItemType Directory -Force $coRec, $coBlt | Out-Null
    function New-CoSpec([string]$Slug, [string]$Name) {
      $j = '{"slug":"SLUG","name":"NAME","stat":{"cost_ps":"2.10"},"head":{"description":"A fixture bowl for the week."},"scaler":{"ing":[{"item":"Worcestershire Sauce","grams":30},{"item":"Oyster Sauce","grams":40}]}}'
      Set-Content -LiteralPath (Join-Path $coRec ($Slug + '.json')) -Encoding UTF8 -Value ($j.Replace('SLUG', $Slug).Replace('NAME', $Name))
    }
    function Get-CoBlock([string]$Pct) { "<div class='smp-comp'><i style='width:" + $Pct + "%' title='Beef: " + $Pct + "%'></i><p class='smp-comp-pay'>Beef is the bill.</p></div>" }
    function Get-CoBody([string]$Slug, [string]$Pct, [string]$Extra) { '<ul class="smp-ing"><li>x</li></ul>' + (Format-TcAllergenLine (Get-TcRecipeAllergens $ing $table) $Slug) + '<!--TC-PAYWALL-->' + (Get-CoBlock $Pct) + $Extra }
    $coHead = '<script type="application/ld+json">{"@type":"Recipe"}</script>'
    $script:coPlan = @{}
    $coBuild = {
      param($s)
      $ok = 0
      foreach ($x in $s) {
        [IO.File]::WriteAllText((Join-Path $coBlt ($x + '.body.html')), $script:coPlan[$x].Body, (New-Object System.Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $coBlt ($x + '.head.html')), $script:coPlan[$x].Head, (New-Object System.Text.UTF8Encoding($false)))
        $ok++
      }
      Write-Output ('built {0}/{1}  errors 0' -f $ok, @($s).Count)
    }
    $script:coSent = @{}
    $coPublish = { param($s) foreach ($x in $s) { $script:coSent[$x] = [IO.File]::ReadAllText((Join-Path $coBlt ($x + '.body.html')), [Text.Encoding]::UTF8) }; 'published+verified OK: ' + @($s).Count + ' / ' + @($s).Count; 'PUBLISH-UNSTAMPABLE: ' }
    function Set-CoLive([string]$Slug, [string]$Body, [hashtable]$Journal, [string]$JournalName) {
      # the card on disk IS the live card, and the journal says so under the name publish sent
      [IO.File]::WriteAllText((Join-Path $coBlt ($Slug + '.body.html')), $Body, (New-Object System.Text.UTF8Encoding($false)))
      [IO.File]::WriteAllText((Join-Path $coBlt ($Slug + '.head.html')), $coHead, (New-Object System.Text.UTF8Encoding($false)))
      $Journal[$Slug] = Get-TcPublishHash $Body $coHead $JournalName 'A fixture bowl for the week.'
    }
    function Invoke-CoRun([string[]]$Slugs, [hashtable]$Journal) {
      [IO.File]::WriteAllText($coJournal, ($Journal | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
      $script:coSent = @{}
      return (Invoke-TcGatedRepublish -Slugs $Slugs -RecipesDir $coRec -BuiltDir $coBlt -Build $coBuild -Publish $coPublish -CostOnly -JournalPath $coJournal)
    }
    $footer = "<div class='smp-rel'><h2>Three more</h2><div class='smp-rel-grid'><a href='/b/'>B</a></div></div>"

    # MUST FIRE: the founding case. The rebuild carries drift beside the cost; only the cost may ship.
    New-CoSpec 'co-drift' 'Fixture Drift Bowl'
    $jr = @{}
    $liveBody = Get-CoBody 'co-drift' '63.269' ''
    Set-CoLive 'co-drift' $liveBody $jr 'Fixture Drift Bowl'
    $script:coPlan = @{ 'co-drift' = [pscustomobject]@{ Body = (Get-CoBody 'co-drift' '70.100' $footer); Head = ($coHead + '<!-- I44 claim -->') } }
    $r = Invoke-CoRun @('co-drift') $jr
    $sent = [string]$script:coSent['co-drift']
    Test-GrCase 'MUST FIRE  a cost-moved card whose rebuild also carries other changes ships ONLY the new cost block: the live card, cost swapped, no footer, head untouched' `
      ($sent -eq (Get-CoBody 'co-drift' '70.100' '') -and $sent -notmatch 'smp-rel' -and ([IO.File]::ReadAllText((Join-Path $coBlt 'co-drift.head.html'), [Text.Encoding]::UTF8)) -eq $coHead -and @($r.Held).Count -eq 0 -and (@($r.CostOnly) -join ',') -eq 'co-drift') `
      ('sent-has-footer=' + ($sent -match 'smp-rel') + ' sent-has-new-cost=' + ($sent -match '70\.100') + ' held=' + (@($r.Held | ForEach-Object { $_.slug + '/' + $_.why }) -join ' ; '))

    # CLEAN TWIN: a pure cost move still publishes, and what it sends is exactly the rebuild.
    New-CoSpec 'co-clean' 'Fixture Clean Bowl'
    $jr = @{}
    Set-CoLive 'co-clean' (Get-CoBody 'co-clean' '40.000' '') $jr 'Fixture Clean Bowl'
    $script:coPlan = @{ 'co-clean' = [pscustomobject]@{ Body = (Get-CoBody 'co-clean' '44.500' ''); Head = $coHead } }
    $r = Invoke-CoRun @('co-clean') $jr
    Test-GrCase 'CLEAN TWIN a card whose rebuild differs only in cost publishes, and sends exactly the rebuilt card' `
      (([string]$script:coSent['co-clean']) -eq (Get-CoBody 'co-clean' '44.500' '') -and @($r.Held).Count -eq 0 -and (@($r.Eligible) -join ',') -eq 'co-clean') `
      ('eligible=' + (@($r.Eligible) -join ',') + ' held=' + (@($r.Held | ForEach-Object { $_.why }) -join ' ; '))

    # MUST FIRE: the card on disk is not the one live, so nothing can prove what else would change: HELD.
    New-CoSpec 'co-unknown' 'Fixture Unknown Bowl'
    $jr = @{}
    Set-CoLive 'co-unknown' (Get-CoBody 'co-unknown' '50.000' '') $jr 'Fixture Unknown Bowl'
    $jr['co-unknown'] = 'DEADBEEF'   # the journal names some other page
    $priorBody = Get-CoBody 'co-unknown' '50.000' ''
    $script:coPlan = @{ 'co-unknown' = [pscustomobject]@{ Body = (Get-CoBody 'co-unknown' '55.000' $footer); Head = $coHead } }
    $r = Invoke-CoRun @('co-unknown') $jr
    Test-GrCase 'MUST FIRE  a card whose live bytes cannot be proven is HELD, named with its reason, never published, and the card on disk is put back' `
      (-not $script:coSent.ContainsKey('co-unknown') -and -not $r.PublishInvoked -and @($r.Held | Where-Object { $_.slug -eq 'co-unknown' -and $_.stage -eq 'drift' -and $_.why -match 'not what the publish journal says is live' }).Count -eq 1 -and ([IO.File]::ReadAllText((Join-Path $coBlt 'co-unknown.body.html'), [Text.Encoding]::UTF8)) -eq $priorBody) `
      ('invoked=' + $r.PublishInvoked + ' held=' + (@($r.Held | ForEach-Object { $_.slug + '/' + $_.stage + '/' + $_.why }) -join ' ; '))

    # MUST FIRE: a retitled spec. The card is unchanged but publish would send a new title: HELD.
    New-CoSpec 'co-title' 'Homemade Fixture Bowl'
    $jr = @{}
    Set-CoLive 'co-title' (Get-CoBody 'co-title' '30.000' '') $jr 'Healthy Fixture Bowl'
    $script:coPlan = @{ 'co-title' = [pscustomobject]@{ Body = (Get-CoBody 'co-title' '31.000' ''); Head = $coHead } }
    $r = Invoke-CoRun @('co-title') $jr
    Test-GrCase 'MUST FIRE  a spec retitled since its last publish is HELD, because publish would ship the new title with the cost' `
      (-not $script:coSent.ContainsKey('co-title') -and @($r.Held | Where-Object { $_.slug -eq 'co-title' -and $_.stage -eq 'drift' }).Count -eq 1) `
      ('held=' + (@($r.Held | ForEach-Object { $_.slug + '/' + $_.why }) -join ' ; '))

    # MUST FIRE: never published (no journal entry) is not provable either.
    New-CoSpec 'co-new' 'Fixture New Bowl'
    $script:coPlan = @{ 'co-new' = [pscustomobject]@{ Body = (Get-CoBody 'co-new' '31.000' ''); Head = $coHead } }
    [IO.File]::WriteAllText((Join-Path $coBlt 'co-new.body.html'), (Get-CoBody 'co-new' '30.000' ''), (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $coBlt 'co-new.head.html'), $coHead, (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-CoRun @('co-new') @{ 'someone-else' = 'X' }
    Test-GrCase 'MUST FIRE  a slug with no publish-journal entry is HELD, not published' `
      (-not $script:coSent.ContainsKey('co-new') -and @($r.Held | Where-Object { $_.slug -eq 'co-new' -and $_.why -match 'no entry' }).Count -eq 1) `
      ('held=' + (@($r.Held | ForEach-Object { $_.slug + '/' + $_.why }) -join ' ; '))

    # PIN: the copied hash and the name/description road are publish.ps1's own. Needles by concatenation.
    $pubSrc = [IO.File]::ReadAllText((Join-Path $mp 'engine\publish.ps1'))
    Test-GrCase 'MUST FIRE  publish.ps1 still hashes body, head, name and description in the order Get-TcPublishHash copies, after the same two spec passes' `
      ($pubSrc.Contains('$contentHash = Get-' + 'ContentHash ($body + "`0" + $head + "`0" + [string]$spec.name + "`0" + $desc)') -and $pubSrc.Contains('$spec = Expand-' + 'SpecProse $spec') -and $pubSrc.Contains('$spec = Move-SpecPrice' + 'ToReleaseHydration $spec') -and $pubSrc.Contains('$desc = [string]$spec.head.' + 'description')) 'publish.ps1 moved its hash or its name/description road'

    # ---- SOURCE PINS: the parser reads build-cards' real output shape, and the chain uses this path ---------
    # Needles by concatenation, so this file cannot satisfy them by quoting them.
    # ---- WHAT A PUBLISH DID NOT SHIP (2026-09-21) ----------------------------------------------------------
    $u = Get-TcPublishUnshipped -Lines @('HELD  b  - live-price rollout ...', 'published+verified OK: 1 / 2', 'PUBLISH-UNSTAMPABLE: b') -Eligible @('a', 'b')
    Test-GrCase 'MUST FIRE  a slug publish HELD (exit 0) is reported as NOT shipped, not as republished' ($u.Known -and @($u.Unshipped).Count -eq 1 -and $u.Unshipped[0] -eq 'b') (@($u.Unshipped) -join ',')
    $u = Get-TcPublishUnshipped -Lines @('published+verified OK: 2 / 2', 'PUBLISH-UNSTAMPABLE: ') -Eligible @('a', 'b')
    Test-GrCase 'MUST NOT FIRE  an empty machine line means every eligible slug shipped' ($u.Known -and @($u.Unshipped).Count -eq 0) (@($u.Unshipped) -join ',')
    $u = Get-TcPublishUnshipped -Lines @('published+verified OK: 2 / 2') -Eligible @('a', 'b')
    Test-GrCase 'MUST FIRE  no machine line at all: nothing may be counted as shipped' ((-not $u.Known) -and @($u.Unshipped).Count -eq 2) (@($u.Unshipped) -join ',')
    $u = Get-TcPublishUnshipped -Lines @('PUBLISH-UNSTAMPABLE: z,b') -Eligible @('a', 'b')
    Test-GrCase 'CLEAN TWIN  a named slug that was never eligible is ignored, the eligible one is kept' ($u.Known -and @($u.Unshipped).Count -eq 1 -and $u.Unshipped[0] -eq 'b') (@($u.Unshipped) -join ',')
    $cacSrc0 = [IO.File]::ReadAllText((Join-Path $repo 'grocery\check-ad-cycles.ps1'))
    Test-GrCase 'MUST FIRE  check-ad-cycles reads the unshipped slugs before it says the loop closed' ($cacSrc0.Contains('Get-TcPublish' + 'Unshipped -Lines')) 'the daily chain no longer asks what publish did not ship'
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
    $coCall = [regex]::Match($cacSrc, 'Invoke-TcGated' + 'Republish -Slugs \$stale -CostOnly\b')
    Test-GrCase 'MUST FIRE  the daily chain asks for the cost-only republish (Brad, 2026-09-19)' $coCall.Success 'check-ad-cycles calls the gated republish without -CostOnly'
  } finally {
    $env:TC_WRITE_JOURNAL = $savedJournal; $env:TC_STAGE_WRITES = $savedStage
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:grCases -lt 18) { Write-Output ("GATED-REPUBLISH SELF-TEST FAIL: ran {0} of 18 case(s)" -f $script:grCases); exit 1 }
  if ($script:grFail) { Write-Output ("GATED-REPUBLISH SELF-TEST FAIL: {0} of {1} case(s)" -f $script:grFail, $script:grCases); exit 1 }
  Write-Output ("GATED-REPUBLISH SELF-TEST PASS: {0} of {0} case(s)" -f $script:grCases)
  exit 0
}
