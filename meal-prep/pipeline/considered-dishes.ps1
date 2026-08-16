# considered-dishes.ps1
# ---------------------------------------------------------------------------------------------------
# The estate's memory of dishes it has already ruled on. catalog-digest.json covers PUBLISHED recipes
# only, so a rejected candidate left no trace outside its run dir: run hunt-2026-08-15-lowcarb-100
# rejected 44 of 91 recipes as duplicates, and every future run would have re-sourced, re-adjudicated
# and re-decided the same 44, forever. Measured cost of that lane: select burned 242,157,676 tokens,
# 32.2% of the run (lane-tokens.ps1, wf_11382034-6fd).
#
# ADVISORY, NOT A GATE - deliberately, for now. A too-coarse key rejects genuinely new dishes; a
# too-fine one never matches. The sourcer is TOLD what was rejected and why and may still return the
# candidate with a stated reason. It becomes blocking only after a hand-checked false-positive rate.
#
#   .\considered-dishes.ps1 -Record -Slug s -Name 'X' -Protein beef -Method skillet -Verdict rejected-dupe -Reason '...' [-DupeOf a,b] -Run <id>
#   .\considered-dishes.ps1 -Query -Name 'X' -Protein beef [-Method skillet]
#   .\considered-dishes.ps1 -List [-Verdict rejected-dupe]
#   .\considered-dishes.ps1 -SelfTest
# Exit 0 ok / no prior ruling, 3 on -Query when a prior ruling EXISTS (so a caller can branch), 2 self-test fail.
# ---------------------------------------------------------------------------------------------------
param(
  [switch]$Record, [switch]$Query, [switch]$List, [switch]$SelfTest,
  [string]$Slug = '', [string]$Name = '', [string]$Protein = '', [string]$Method = '',
  [string]$Verdict = '', [string]$Reason = '', [string[]]$DupeOf = @(), [string]$Run = '', [string]$By = '',
  [string]$Store = '', [switch]$Json
)
$ErrorActionPreference = 'Stop'
$runRecord=[bool]$Record; $runQuery=[bool]$Query; $runList=[bool]$List; $runSelfTest=[bool]$SelfTest; $runJson=[bool]$Json

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $Store) { $Store = Join-Path $mp 'db\considered-dishes.json' }

# Sauce/flavour families. Identity lives here more than in the protein: "creamy tuscan chicken" and
# "creamy asiago pork medallions" are the same dinner wearing different meat, which is precisely the
# cross-protein twin the decider had to catch by hand five times in the 2026-08-15 run.
$script:FAMILIES = [ordered]@{
  'cream'    = @('creamy','cream','alfredo','tuscan','marry me','asiago','parmesan cream','white sauce','bechamel')
  'tomato'   = @('marinara','tomato','arrabbiata','pomodoro','bolognese','enchilada','tinga','chili')
  'soy'      = @('soy','teriyaki','bulgogi','hoisin','sesame','egg roll','stir fry','lo mein','japchae')
  'curry'    = @('curry','tikka','masala','korma','coconut curry','yellow curry','red curry','dal')
  'wine'     = @('wine','marsala','bourguignon','coq au vin','piccata','chasseur','fricassee','braised in red')
  'cheese'   = @('cheddar','queso','cheese','quiche','gratin','mac and cheese','pizza')
  'bbq'      = @('bbq','barbecue','sweet and sour','honey garlic','teriyaki glaze')
  'herb'     = @('chimichurri','pesto','herb','lemon garlic','gremolata','ranch')
  'spice'    = @('taco','fajita','chipotle','adobo','barbacoa','tex-mex','cajun','blackened','harissa','berbere','sumac','tandoori')
}

function Get-Family {
  param([string]$Text)
  if (-not $Text) { return 'plain' }
  $t = $Text.ToLower()
  foreach ($k in $script:FAMILIES.Keys) {
    foreach ($needle in $script:FAMILIES[$k]) { if ($t -like ('*' + $needle + '*')) { return $k } }
  }
  return 'plain'
}

function Get-DishKey {
  param([string]$Name, [string]$Protein, [string]$Method)
  # protein | method | sauce-family. Slugs vary by publisher; identity does not.
  $p = if ($Protein) { $Protein.ToLower().Trim() } else { 'any' }
  $m = if ($Method) { $Method.ToLower().Trim() } else { 'any' }
  return ('{0}|{1}|{2}' -f $p, $m, (Get-Family $Name))
}

function Read-Store {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return @() }
  try { $d = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json } catch { return @() }
  if ($d -and ($d.PSObject.Properties.Name -contains 'dishes')) { return @($d.dishes) }
  return @()
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  T 'MUST FIRE  the cross-protein twin that fooled the adjudicator collides on family' (
      (Get-Family 'Creamy Tuscan Chicken Skillet') -eq (Get-Family 'Creamy Asiago Pork Tenderloin Medallions')
    ) ((Get-Family 'Creamy Tuscan Chicken Skillet') + ' vs ' + (Get-Family 'Creamy Asiago Pork Tenderloin Medallions'))
  T 'MUST FIRE  egg roll in a bowl is one family across all three proteins' (
      (Get-Family 'Beef Egg Roll in a Bowl') -eq (Get-Family 'Pork Egg Roll in a Bowl')
    ) (Get-Family 'Beef Egg Roll in a Bowl')
  T 'CLEAN TWIN a genuinely different sauce family does NOT collide' (
      (Get-Family 'Creamy Tuscan Chicken') -ne (Get-Family 'Korean Beef Bulgogi')
    ) 'collided'
  T 'the key is protein|method|family' ((Get-DishKey 'Creamy Tuscan Chicken' 'chicken' 'skillet') -eq 'chicken|skillet|cream') (Get-DishKey 'Creamy Tuscan Chicken' 'chicken' 'skillet')
  T 'MUST FIRE  same dish, different protein => DIFFERENT key (decider still judges, we only surface)' (
      (Get-DishKey 'Creamy Tuscan Chicken' 'chicken' 'skillet') -ne (Get-DishKey 'Creamy Asiago Pork' 'pork' 'skillet')
    ) 'keys identical - too coarse'
  T 'an unmatched name falls back to plain rather than erroring' ((Get-Family 'Roast Beef') -eq 'plain') (Get-Family 'Roast Beef')

  # MUST FIRE: the catch-all trap, found on first live test 2026-08-16. A stored row with no protein,
  # no method and no sauce family (`any|any|plain`) matched EVERY query, so a Senegalese chicken dish
  # was reported as prior art for a Moroccan lamb tagine. Wildcards may widen a match that already has
  # evidence; they may never BE the evidence.
  function TestSignal { param($P,[string]$Kp,[string]$Km,[string]$Kf)
    if ($Kf -ne 'plain') { return $true }
    if ($P[0] -eq $Kp -and $Kp -ne 'any' -and $P[1] -eq $Km -and $Km -ne 'any') { return $true }
    return $false }
  T 'MUST FIRE  an all-wildcard stored row is NOT evidence for an unrelated dish' (
      -not (TestSignal @('any','any','plain') 'lamb' 'braised' 'plain')
    ) 'matched on no evidence'
  T 'CLEAN TWIN a shared sauce family IS evidence' (TestSignal @('any','any','cream') 'turkey' 'skillet' 'cream') 'family ignored'
  T 'CLEAN TWIN concrete protein+method IS evidence even with no family' (
      TestSignal @('beef','skillet','plain') 'beef' 'skillet' 'plain'
    ) 'concrete match rejected'

  # round-trip against a scratch store
  $tmp = Join-Path $env:TEMP ('cd-selftest-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    $rows = @([pscustomobject]@{ key='beef|skillet|soy'; slug='beef-egg-roll-in-a-bowl'; name='Beef Egg Roll in a Bowl'; verdict='rejected-dupe'; reason='third protein-swap'; dupe_of=@('pork-egg-roll-in-a-bowl'); run='r1'; at='2026-08-16' })
    ([pscustomobject]@{ _doc='test'; dishes=$rows } | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding utf8
    $back = Read-Store $tmp
    T 'the store round-trips' (@($back).Count -eq 1 -and $back[0].slug -eq 'beef-egg-roll-in-a-bowl') ([string]@($back).Count)
    T 'MUST FIRE  a single stored row does not collapse to a scalar' (@($back).Count -eq 1) ([string]@($back).Count)
    $miss = Read-Store (Join-Path $env:TEMP 'definitely-not-here.json')
    T 'a missing store reads as empty, not as an error' (@($miss).Count -eq 0) ([string]@($miss).Count)
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }

  if ($bad -gt 0) { Write-Output ("considered-dishes SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'considered-dishes SELF-TEST PASS'
  Write-GuardComplete -Name 'considered-dishes' -Summary 'selftest pass'
  exit 0
}

$dishes = @(Read-Store $Store)

# ---- -Record ---------------------------------------------------------------------------------------
if ($runRecord) {
  if (-not $Slug -or -not $Verdict) { Write-Output 'considered-dishes: -Record needs -Slug and -Verdict'; exit 1 }
  $key = Get-DishKey $Name $Protein $Method
  $row = [pscustomobject]@{
    key=$key; slug=$Slug; name=$Name; protein=$Protein; method=$Method; verdict=$Verdict
    reason=$Reason; dupe_of=@($DupeOf | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    run=$Run; by=$By; at=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
  }
  # Same slug ruled twice: keep the LATEST, so a re-ruling supersedes rather than accumulating.
  $kept = @($dishes | Where-Object { [string]$_.slug -ne $Slug })
  $out = @($kept + $row)
  $doc = [pscustomobject]@{
    _doc = 'Dishes this estate has already ruled on. Read by sourcers BEFORE fetching and by adjudicators as prior art. Written by the DECIDER only - it is already the single writer of selection state. Advisory: a sourcer may return a previously-rejected dish with a stated reason.'
    _key = 'protein|method|sauce-family - identity, not slug, because slugs vary by publisher and the same dinner recurs under many names.'
    updated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); count = @($out).Count; dishes = @($out)
  }
  $tmpf = $Store + '.tmp'
  ($doc | ConvertTo-Json -Depth 6) | Set-Content -Path $tmpf -Encoding utf8
  Move-Item -Path $tmpf -Destination $Store -Force
  Write-Output ("considered-dishes: recorded {0}  [{1}]  {2}" -f $Slug, $key, $Verdict)
  Write-GuardComplete -Name 'considered-dishes' -Summary ("record {0}" -f $Slug); exit 0
}

# ---- -Query ----------------------------------------------------------------------------------------
if ($runQuery) {
  if (-not $Name) { Write-Output 'considered-dishes: -Query needs -Name'; exit 1 }
  $key = Get-DishKey $Name $Protein $Method
  $kp = $key.Split('|')[0]; $km = $key.Split('|')[1]; $kf = $key.Split('|')[2]

  # 'any' is a WILDCARD, not a value. A ruling recorded before the method was known must still match
  # the same dish when the method is known later, or the ledger silently forgets its own entries.
  function Test-Part { param([string]$a, [string]$b) return ($a -eq $b -or $a -eq 'any' -or $b -eq 'any') }

  # A match needs at least one POSITIVE signal. Without this, a stored row keyed `any|any|plain` - no
  # protein detected, no method detected, no sauce family - matches every query ever made, and the
  # ledger confidently reports a Senegalese chicken dish as prior art for a Moroccan lamb tagine.
  # Wildcards may WIDEN a match that already has evidence; they may never BE the evidence.
  function Test-HasSignal {
    param($P, [string]$Kp, [string]$Km, [string]$Kf)
    if ($Kf -ne 'plain') { return $true }                                  # shared sauce family is signal
    if ($P[0] -eq $Kp -and $Kp -ne 'any' -and $P[1] -eq $Km -and $Km -ne 'any') { return $true }  # concrete protein+method
    return $false
  }
  $exact = @($dishes | Where-Object {
    $p = ([string]$_.key).Split('|')
    (Test-Part $p[0] $kp) -and (Test-Part $p[1] $km) -and $p[2] -eq $kf -and (Test-HasSignal $p $kp $km $kf)
  })

  # 'plain' means NO family was detected - it is the absence of a signal, not a shared one. Reporting
  # cross-protein 'plain' matches turned a brand-new lamb tagine into five false neighbours on first
  # test, which is exactly the too-coarse failure this ledger has to avoid to stay believable.
  $fam = @()
  if ($kf -ne 'plain') {
    $fam = @($dishes | Where-Object {
      $p = ([string]$_.key).Split('|')
      $p[2] -eq $kf -and -not ((Test-Part $p[0] $kp) -and (Test-Part $p[1] $km))
    })
  }
  if ($runJson) {
    ([pscustomobject]@{ key=$key; prior=@($exact); same_family_other_protein=@($fam | Select-Object -First 5) } | ConvertTo-Json -Depth 6)
    if (@($exact).Count -gt 0) { exit 3 }
    exit 0
  }
  Write-Output ("considered-dishes: '{0}' -> key {1}" -f $Name, $key)
  if (-not @($exact).Count -and -not @($fam).Count) { Write-Output '  no prior ruling on this dish identity.'; exit 0 }
  foreach ($d in $exact) { Write-Output ("  PRIOR RULING  {0}  {1}  - {2}" -f $d.verdict, $d.slug, $d.reason) }
  foreach ($d in @($fam | Select-Object -First 5)) { Write-Output ("  same family, other protein: {0} [{1}] {2}" -f $d.slug, $d.key, $d.verdict) }
  Write-Output '  ADVISORY: you may still return this candidate - say why it is distinct.'
  if (@($exact).Count -gt 0) { exit 3 }
  exit 0
}

# ---- -List -----------------------------------------------------------------------------------------
$rows = if ($Verdict) { @($dishes | Where-Object { [string]$_.verdict -eq $Verdict }) } else { $dishes }
if ($runJson) { ([pscustomobject]@{ count=@($rows).Count; dishes=@($rows) } | ConvertTo-Json -Depth 6); exit 0 }
Write-Output ("considered-dishes: {0} ruling(s){1}" -f @($rows).Count, $(if($Verdict){" with verdict '$Verdict'"}else{''}))
foreach ($d in @($rows | Sort-Object key)) { Write-Output ("  {0,-34} {1,-18} {2}" -f $d.key, $d.verdict, $d.slug) }
exit 0
