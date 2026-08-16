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

  if ($bad -gt 0) { Write-Output ("find-similar SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'find-similar SELF-TEST PASS'
  Write-GuardComplete -Name 'find-similar' -Summary 'selftest pass'
  exit 0
}

# ---- query -----------------------------------------------------------------------------------------
if (-not $Name) { Write-Output 'find-similar: -Name "<dish name>" is required'; exit 1 }
if (-not (Test-Path $DigestFile)) { Write-Output ("find-similar: no digest at {0} - run make-catalog-digest.ps1" -f $DigestFile); exit 1 }

$digest = Get-Content $DigestFile -Raw -Encoding utf8 | ConvertFrom-Json
$nameTok = Get-Tokens $Name
$wantItems = @($Items | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })

# Protein narrows the search but never hides a match: a cross-protein twin (the same dish in beef and
# in turkey) is the exact collision the decider is asked to catch, so all proteins are always scored.
$rows = @()
foreach ($p in $digest.by_protein.PSObject.Properties) {
  foreach ($r in $p.Value) {
    $ct = Get-Tokens ([string]$r.name)
    $ci = @(@($r.items) | ForEach-Object { ([string]$_).ToLower() })
    $s = Get-Score $nameTok $ct $wantItems $ci
    if ($s.score -le 0) { continue }
    $rows += [pscustomobject]@{
      slug = [string]$r.slug; name = [string]$r.name; protein = $p.Name; score = $s.score
      shared_words = @($s.words); shared_items = @($s.items)
      same_protein = ($Protein -and $p.Name -eq $Protein.ToLower())
    }
  }
}
$hits = @($rows | Sort-Object @{Expression='score';Descending=$true}, @{Expression='same_protein';Descending=$true} | Select-Object -First $Top)

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
