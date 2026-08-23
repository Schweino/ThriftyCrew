# find-similar.ps1
# ---------------------------------------------------------------------------------------------------
# Answers "what in the catalog is closest to this dish" in ~1KB, so a sourcer or adjudicator never has
# to read catalog-digest.json (111,942 bytes, ~27.5K tokens) into context to make one dedup judgment.
#
# MEASURED JUSTIFICATION (2026-08-16, lane-tokens.ps1 over run wf_11382034-6fd): the hunt and select
# lanes together burned 567,701,098 tokens - 75.5% of the run - across 578 agent invocations, most of
# it repeated context. This script exists to make that context unnecessary rather than to make the
# agents read it faster.
#
#   .\find-similar.ps1 -Name 'Creamy Tuscan Chicken' -Protein chicken
#   .\find-similar.ps1 -Name '...' -Top 8 -Json
#   .\find-similar.ps1 -SelfTest
#
# Scoring is deliberately crude and explainable: shared significant words in the recipe NAME, plus a
# bonus for shared commodity items. It is a SHORTLIST for an agent to judge, never a verdict - the
# adjudicator and decider still rule. A crude shortlist an agent can check beats a clever score it
# cannot see behind.
# ---------------------------------------------------------------------------------------------------
param(
  [string]$Name = '',
  [string]$Protein = '',
  [string[]]$Items = @(),
  [int]$Top = 5,
  [string]$DigestFile,
  # BATCH MODE (2026-08-23, v3 D3). harvest.py scores hundreds of candidates against the catalog on
  # every crawl. One PowerShell process per candidate is ~1 s of process start to do ~5 ms of work, and
  # the alternative - a second copy of Get-Score in Python - is the two-implementations trap this estate
  # has paid for three times. So the batch reads many queries and answers them in ONE process, through
  # the SAME Get-Score. -BatchFile is a JSON array of {key, name, protein, items}; -Json emits an array
  # of {key, query, matches} whose rows are byte-identical to the single-query answer.
  [string]$BatchFile = '',
  [switch]$Json,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest; $runJson = [bool]$Json

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $DigestFile) { $DigestFile = Join-Path $here 'catalog-digest.json' }

# Words that carry no dish identity. Without this, "Slow Cooker Beef" matches every slow cooker recipe
# in the catalog on the strength of "slow" and "cooker", and the shortlist becomes noise.
$script:STOP = @('the','and','with','a','an','of','in','on','for','over','style','easy','best','quick',
                 'simple','homemade','recipe','recipes','low','carb','keto','healthy','one','pan','pot',
                 'sheet','skillet','slow','cooker','instant','baked','bake','crockpot','make','ahead','my')

function Get-Tokens {
  param([string]$Text)
  if (-not $Text) { return @() }
  $t = ($Text.ToLower() -replace '[^a-z0-9 ]', ' ')
  return @($t -split '\s+' | Where-Object { $_ -and $_.Length -gt 2 -and ($script:STOP -notcontains $_) } | Select-Object -Unique)
}

function Get-Score {
  param($NameTokens, $CandTokens, $Items, $CandItems)
  $shared = @($NameTokens | Where-Object { $CandTokens -contains $_ })
  $score = 10 * @($shared).Count
  $sharedItems = @()
  if (@($Items).Count -gt 0 -and @($CandItems).Count -gt 0) {
    $sharedItems = @($Items | Where-Object { $CandItems -contains $_ })
    $score += @($sharedItems).Count
  }
  return @{ score = $score; words = @($shared); items = @($sharedItems) }
}

function Get-Matches {
  param([object]$Digest, [string]$QName, [string]$QProtein, [string[]]$QItems, [int]$TopN)
  # Protein narrows the ordering but never hides a match: a cross-protein twin (the same dish in beef
  # and in turkey) is the exact collision the decider is asked to catch, so all proteins are scored.
  $nameTok = Get-Tokens $QName
  $rows = @()
  foreach ($p in $Digest.by_protein.PSObject.Properties) {
    foreach ($r in $p.Value) {
      $ct = Get-Tokens ([string]$r.name)
      $ci = @(@($r.items) | ForEach-Object { ([string]$_).ToLower() })
      $s = Get-Score $nameTok $ct $QItems $ci
      if ($s.score -le 0) { continue }
      $rows += [pscustomobject]@{
        slug = [string]$r.slug; name = [string]$r.name; protein = $p.Name; score = $s.score
        shared_words = @($s.words); shared_items = @($s.items)
        same_protein = ($QProtein -and $p.Name -eq $QProtein.ToLower())
      }
    }
  }
  return @($rows | Sort-Object @{Expression='score';Descending=$true}, @{Expression='same_protein';Descending=$true} | Select-Object -First $TopN)
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  T 'stop-words are dropped so method words do not drive the match' ((Get-Tokens 'Slow Cooker Beef Stew') -notcontains 'slow') ((Get-Tokens 'Slow Cooker Beef Stew') -join ',')
  T 'significant words survive' ((Get-Tokens 'Slow Cooker Beef Stew') -contains 'beef') ((Get-Tokens 'Slow Cooker Beef Stew') -join ',')
  T 'MUST FIRE  the same dish scores above an unrelated one' (
      (Get-Score (Get-Tokens 'Creamy Tuscan Chicken') (Get-Tokens 'Creamy Tuscan Chicken Skillet') @() @()).score -gt
      (Get-Score (Get-Tokens 'Creamy Tuscan Chicken') (Get-Tokens 'Korean Beef Bulgogi') @() @()).score
    ) 'ordering wrong'
  # 'x'/'y' are stripped by Get-Tokens (length <= 2), so this isolates the item contribution.
  # Items must be >2 chars to survive tokenisation the same way, hence the realistic commodity ids.
  T 'shared commodity items add signal' (
      (Get-Score @() @() @('chicken-breast','heavy-cream') @('chicken-breast','heavy-cream')).score -eq 2
    ) ([string](Get-Score @() @() @('chicken-breast','heavy-cream') @('chicken-breast','heavy-cream')).score)
  T 'MUST FIRE  an unrelated dish scores ZERO, so a thin shortlist stays thin' (
      (Get-Score (Get-Tokens 'Korean Beef Bulgogi') (Get-Tokens 'Lemon Garlic Shrimp') @() @()).score -eq 0
    ) 'nonzero'
  # the bulgogi case from the live run: two names for one dish must collide
  T 'the low-carb-korean-beef-bulgogi / beef-bulgogi-rice-bowls collision is caught' (
      (Get-Score (Get-Tokens 'Low Carb Korean Beef Bulgogi') (Get-Tokens 'Beef Bulgogi Rice Bowls') @() @()).score -ge 20
    ) ([string](Get-Score (Get-Tokens 'Low Carb Korean Beef Bulgogi') (Get-Tokens 'Beef Bulgogi Rice Bowls') @() @()).score)
  T 'MUST FIRE  the digest exists where the sourcer prompts will point' (Test-Path $DigestFile) $DigestFile

  # BATCH MODE returns the SAME rows as the single query, or the batch is a second implementation
  # wearing the first one's name. Asserted against the live digest, on the collision that founded this
  # file (two names for one bulgogi), because a fixture over a synthetic digest would prove nothing
  # about the shape harvest.py actually sends.
  if (Test-Path $DigestFile) {
    $dg = Get-Content $DigestFile -Raw -Encoding utf8 | ConvertFrom-Json
    $one = @(Get-Matches $dg 'Creamy Tuscan Chicken' 'chicken' @() 5)
    $bf = Join-Path $env:TEMP ('fs-batch-' + [guid]::NewGuid().ToString('N') + '.json')
    (ConvertTo-Json -InputObject @(@{ key='k1'; name='Creamy Tuscan Chicken'; protein='chicken'; items=@() }) -Depth 4) | Set-Content $bf -Encoding utf8
    $p1 = Get-Content $bf -Raw -Encoding utf8 | ConvertFrom-Json
    $qs = @($p1)
    Remove-Item $bf -Force -ErrorAction SilentlyContinue
    T 'a one-row batch file survives ConvertFrom-Json as an ARRAY (the PS 5.1 unwrap trap)' (@($qs).Count -eq 1) ([string]@($qs).Count)

    # MUST FIRE, and it is here because the one-row fixture above passed while the batch road was
    # BROKEN on 2026-08-23: `@(<pipeline> | ConvertFrom-Json)` on a MANY-element array collects ONE
    # object of type Object[], so every query in a real batch collapsed into a single row whose key
    # was all the keys joined by a space. A batch of one is the only size at which the broken form
    # looks correct. Three rows is the smallest size that tells the truth.
    $bf3 = Join-Path $env:TEMP ('fs-batch3-' + [guid]::NewGuid().ToString('N') + '.json')
    (ConvertTo-Json -InputObject @(
        @{ key='a'; name='Creamy Tuscan Chicken'; protein='chicken'; items=@() },
        @{ key='b'; name='Korean Beef Bulgogi';   protein='beef';    items=@() },
        @{ key='c'; name='Pork Chops with Apples';protein='pork';    items=@() }) -Depth 4) | Set-Content $bf3 -Encoding utf8
    # NOT $bad: this self-test's failure counter is called $bad, PowerShell variable names are
    # case-insensitive and script-scoped here, and assigning an Object[] over it made the final
    # `if ($bad -gt 0)` throw "Cannot compare System.Object[]". Same family as this estate's
    # $script:REJECTED_STATES clobbering. Give a fixture local a name no counter would take.
    $nestedRows  = @(Get-Content $bf3 -Raw -Encoding utf8 | ConvertFrom-Json)
    $properRows  = Get-Content $bf3 -Raw -Encoding utf8 | ConvertFrom-Json
    Remove-Item $bf3 -Force -ErrorAction SilentlyContinue
    T 'MUST FIRE  @(pipeline | ConvertFrom-Json) NESTS a 3-row array into one Object[] element' (
        @($nestedRows).Count -eq 1 -and $nestedRows[0] -is [object[]]
      ) ('count=' + @($nestedRows).Count)
    T 'CLEAN TWIN assign-then-wrap gives the three rows' (@($properRows).Count -eq 3) ([string]@($properRows).Count)
    T 'MUST FIRE  and each row keeps its OWN key (the collapse showed as a space-joined key)' (
        ([string]@($properRows)[0].key) -eq 'a' -and ([string]@($properRows)[2].key) -eq 'c'
      ) ([string]@($properRows)[0].key)
    $many = @(Get-Matches $dg ([string]$qs[0].name) ([string]$qs[0].protein) @() 5)
    T 'MUST FIRE  batch mode returns the single query''s rows exactly - one Get-Score, not two' (
        (@($one | ForEach-Object { $_.slug + ':' + $_.score }) -join '|') -eq
        (@($many | ForEach-Object { $_.slug + ':' + $_.score }) -join '|')
      ) ((@($many | ForEach-Object { $_.slug }) -join ','))
    T 'CLEAN TWIN the shortlist is non-empty on a name the catalog really carries' (@($one).Count -gt 0) ([string]@($one).Count)
  }

  if ($bad -gt 0) { Write-Output ("find-similar SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'find-similar SELF-TEST PASS'
  Write-GuardComplete -Name 'find-similar' -Summary 'selftest pass'
  exit 0
}

# ---- query -----------------------------------------------------------------------------------------
if (-not (Test-Path $DigestFile)) { Write-Output ("find-similar: no digest at {0} - run make-catalog-digest.ps1" -f $DigestFile); exit 1 }
$digest = Get-Content $DigestFile -Raw -Encoding utf8 | ConvertFrom-Json

if ($BatchFile) {
  if (-not (Test-Path $BatchFile)) { Write-Output ("find-similar: no batch file at {0}" -f $BatchFile); exit 1 }
  # PS 5.1, TWO traps on one line, and the second one bit this file on 2026-08-23:
  #   1. a ONE-element JSON array comes back as a bare object, so it needs @() to stay a collection;
  #   2. `@(<pipeline> | ConvertFrom-Json)` on a MANY-element array gives ONE element of type
  #      Object[] - ConvertFrom-Json emits the whole array as a single pipeline object in 5.1, and
  #      @() then collects that one object. The estate's standing "wrap ConvertFrom-Json in @()"
  #      rule is only half the story and is actively wrong here.
  # ASSIGN FIRST, THEN WRAP. The assignment takes the array itself; @() then guards case 1.
  # A batch of one was the fixture, and a batch of one is the only size where the broken form looks
  # right - which is why the fixture below sends THREE.
  $parsed = Get-Content $BatchFile -Raw -Encoding utf8 | ConvertFrom-Json
  $queries = @($parsed)
  $out = @()
  foreach ($q in $queries) {
    $qi = @(@($q.items) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim().ToLower() })
    $out += [pscustomobject]@{
      key = [string]$q.key
      query = [string]$q.name
      matches = @(Get-Matches $digest ([string]$q.name) ([string]$q.protein) $qi $Top)
    }
  }
  # -Depth 6: matches carry shared_words/shared_items arrays one level below the row.
  Write-Output (ConvertTo-Json -InputObject @($out) -Depth 6)
  exit 0
}

if (-not $Name) { Write-Output 'find-similar: -Name "<dish name>" is required (or -BatchFile <json>)'; exit 1 }
$wantItems = @($Items | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$hits = @(Get-Matches $digest $Name $Protein $wantItems $Top)

if ($runJson) {
  ([pscustomobject]@{ query=$Name; protein=$Protein; catalog=$digest.recipe_count; matches=@($hits) } | ConvertTo-Json -Depth 5)
  exit 0
}
Write-Output ("find-similar: '{0}'{1} vs {2} live recipes" -f $Name, $(if($Protein){" [$Protein]"}else{''}), $digest.recipe_count)
if (-not $hits.Count) {
  Write-Output '  no catalog recipe shares a significant word - nothing to dedup against on name.'
  exit 0
}
foreach ($h in $hits) {
  Write-Output ("  {0,3}  {1,-46} [{2}]  words: {3}{4}" -f $h.score, $h.slug, $h.protein, (@($h.shared_words) -join '+'),
    $(if (@($h.shared_items).Count) { '  items: ' + ((@($h.shared_items) | Select-Object -First 4) -join ',') } else { '' }))
}
Write-Output '  This is a SHORTLIST to judge, not a verdict. Cross-protein twins are included deliberately.'
exit 0
