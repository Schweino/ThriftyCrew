# audit-ghost-field-limits.ps1
# ---------------------------------------------------------------------------------------------------
# Every spec field that publish.ps1 sends to Ghost must fit the column Ghost stores it in.
#
# WHY (2026-08-29). Wave 5 of hunt-2026-08-15-lowcarb-100 went GO on all nine recipes. Seven
# published. Two came back HTTP 422 and nothing anywhere said why: publish.ps1's catch reports
# "(422) Unknown Error" without reading the response body, and propagate-recipes echoes only
# `Select-Object -Last 2` of publish's output, so the per-slug line was discarded before a human saw
# it. Diagnosing it took a hand call to publish.ps1 and then a hand call to the Ghost API reading the
# error stream.
#
# The cause: Ghost caps `custom_excerpt` at 300 characters. publish.ps1 sends spec.head.description
# into custom_excerpt AFTER Expand-SpecProse resolves its {{cal}}/{{protein}} tokens, and those two
# expanded to 313 and 309. Every slug that published was under 300 - the nearest at 294. So the
# boundary was crossed by 9 and 13 characters of prose, and the whole wave stopped.
#
# THE LENGTH THAT MATTERS IS THE EXPANDED ONE, which is the reason this cannot live in a plain schema
# check. The raw spec text was 326 and 322; the token expansion SHORTENS it (a {{protein}} of 11
# characters becomes "35"), so a gate reading the raw field would have judged the wrong string in the
# wrong direction. This expands exactly as publish.ps1 does, through the same library.
#
# $desc feeds FOUR fields - custom_excerpt, meta_description, og_description, twitter_description -
# and only custom_excerpt is capped at 300; the other three allow 500. So 300 is the binding
# constraint on the description, and it is the one asserted here.
#
#   .\audit-ghost-field-limits.ps1
#   .\audit-ghost-field-limits.ps1 -Slugs a,b,c
#   .\audit-ghost-field-limits.ps1 -Json
#   .\audit-ghost-field-limits.ps1 -SelfTest
# Exit 0 clean, 1 findings, 2 self-test failure.
# ---------------------------------------------------------------------------------------------------
param([string[]]$Slugs = @(), [string]$RecipesDir, [switch]$Json, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$runJson = [bool]$Json; $runSelfTest = [bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $mp 'lib\render-tokens.ps1')
if (-not $RecipesDir) { $RecipesDir = Join-Path $mp 'db\recipes' }

# Ghost v5 column limits, for the fields publish.ps1 actually sends. Only the ones that can realistically
# bite are asserted; a limit nothing can approach is noise in a gate.
$script:LIMITS = @{
  custom_excerpt = 300    # head.description. PROVEN by a live 422 at 309 and a live success at 294.
  title          = 255    # spec.name
  meta_title     = 300    # spec.name + ' | Thrifty Crew'
}
$script:META_TITLE_SUFFIX = ' | Thrifty Crew'

# The judgement, as a function so fixtures can drive it without a spec store.
function Get-FieldLimitProblems {
  param([string]$Slug, [string]$ExpandedDesc, [string]$Name)
  $out = @()
  $d = [string]$ExpandedDesc
  if ($d.Length -gt $script:LIMITS.custom_excerpt) {
    $out += [pscustomobject]@{ slug = $Slug; field = 'custom_excerpt'; len = $d.Length; limit = $script:LIMITS.custom_excerpt
                               detail = ("head.description expands to {0} characters; Ghost stores custom_excerpt in a {1}-character column and answers 422" -f $d.Length, $script:LIMITS.custom_excerpt) }
  }
  $n = [string]$Name
  if ($n.Length -gt $script:LIMITS.title) {
    $out += [pscustomobject]@{ slug = $Slug; field = 'title'; len = $n.Length; limit = $script:LIMITS.title
                               detail = ("name is {0} characters; Ghost's title column holds {1}" -f $n.Length, $script:LIMITS.title) }
  }
  $mt = $n + $script:META_TITLE_SUFFIX
  if ($mt.Length -gt $script:LIMITS.meta_title) {
    $out += [pscustomobject]@{ slug = $Slug; field = 'meta_title'; len = $mt.Length; limit = $script:LIMITS.meta_title
                               detail = ("name plus '{0}' is {1} characters; Ghost's meta_title column holds {2}" -f $script:META_TITLE_SUFFIX, $mt.Length, $script:LIMITS.meta_title) }
  }
  return @($out)
}

function Get-ExpandedDescription {
  param([string]$Path)
  $spec = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
  # EXPANDED, exactly as publish.ps1 does it, through the same library. See the header: the raw text
  # is longer than the shipped text, so a raw-length check errs in the unsafe direction.
  $spec = Expand-SpecProse $spec
  return [pscustomobject]@{ desc = [string]$spec.head.description; name = [string]$spec.name }
}

# ---------------------------------------------------------------------------------------------------
if ($runSelfTest) {
  $f = 0
  function T([string]$name, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $name) } else { $script:f++; Write-Output ("  FAIL  " + $name + "   got: " + $got) }
  }
  $under = 'x' * 294
  $over  = 'x' * 309
  $at    = 'x' * 300

  T 'CLEAN TWIN a description at 294 - the longest that actually published - is clean' `
    (@(Get-FieldLimitProblems 's' $under 'A Name').Count -eq 0) '294 flagged'
  T 'CLEAN TWIN a description EXACTLY at the 300 limit is clean - the column holds 300, not 299' `
    (@(Get-FieldLimitProblems 's' $at 'A Name').Count -eq 0) '300 flagged'
  $p = @(Get-FieldLimitProblems 's' $over 'A Name')
  T 'MUST FIRE  a description at 309 - the live 422 - is a finding' `
    ($p.Count -eq 1 -and $p[0].field -eq 'custom_excerpt' -and $p[0].len -eq 309) (($p | ForEach-Object { $_.field }) -join ',')
  T 'MUST FIRE  an over-long title is a finding' `
    (@(Get-FieldLimitProblems 's' $under ('t' * 256) | Where-Object { $_.field -eq 'title' }).Count -eq 1) 'title not checked'
  # meta_title is name + 15 characters, so a name UNDER the 255 title limit can still overflow a
  # 300-character meta_title only if the title limit were raised - but the suffix is what makes the
  # two limits different, and pinning it stops a future rename of the suffix going unnoticed.
  T 'CLEAN TWIN a 255-character name is legal as a title AND as a meta_title with the suffix' `
    (@(Get-FieldLimitProblems 's' $under ('t' * 255)).Count -eq 0) 'a legal 255 name was flagged'

  # THE LIVE TREE. The fixtures prove the rule; this proves the estate obeys it right now, which is
  # what a rule silently stops being.
  $bad = @()
  foreach ($sf in (Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))) {
    $e = Get-ExpandedDescription $sf.FullName
    $bad += @(Get-FieldLimitProblems $sf.BaseName $e.desc $e.name)
  }
  T 'CLEAN TWIN every spec in db\recipes fits the columns Ghost stores it in' `
    ($bad.Count -eq 0) (($bad | ForEach-Object { $_.slug + ':' + $_.field + '=' + $_.len }) -join ' | ')

  if ($f -eq 0) { Write-Output 'ghost-field-limits SELF-TEST PASS'; exit 0 }
  Write-Output ("ghost-field-limits SELF-TEST FAIL: {0} case(s)" -f $f); exit 2
}

# ---------------------------------------------------------------------------------------------------
$files = @(Get-ChildItem (Join-Path $RecipesDir '*.json'))
if ($Slugs.Count) { $files = @($files | Where-Object { $Slugs -contains $_.BaseName }) }
$findings = @()
foreach ($sf in $files) {
  $e = Get-ExpandedDescription $sf.FullName
  $findings += @(Get-FieldLimitProblems $sf.BaseName $e.desc $e.name)
}

if ($runJson) {
  [pscustomobject]@{ specs = $files.Count; findings = $findings } | ConvertTo-Json -Depth 5
} else {
  Write-Output ("ghost field limits: {0} spec(s) checked, {1} finding(s)" -f $files.Count, $findings.Count)
  foreach ($x in $findings) { Write-Output ("  [{0}] {1}  {2}" -f $x.field.ToUpper(), $x.slug, $x.detail) }
  if ($findings.Count) {
    Write-Output ''
    Write-Output '  Ghost answers 422 on these, publish.ps1 reports only "(422) Unknown Error", and propagate'
    Write-Output '  echoes just the last two lines of publish output - so in the wild this costs a whole wave'
    Write-Output '  and a hand call to the Ghost API to diagnose. Shorten the field in the spec and rebuild the card.'
  }
}
Write-GuardComplete -Name 'ghost-field-limits' -Summary ("specs={0} findings={1}" -f $files.Count, $findings.Count)
exit $(if ($findings.Count) { 1 } else { 0 })
