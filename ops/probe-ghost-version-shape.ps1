<#
  probe-ghost-version-shape.ps1 - does the live Ghost Admin API answer a DIFFERENT SHAPE when a caller sends
  one Accept-Version rather than another? A REPORT, never a gate, run by hand. Backlog I230.

  WHY IT EXISTS. Every Ghost caller in this repo sent `Accept-Version: v5.0` while the site ran v6.x, and
  Brad's ruling of 2026-09-19 was to move them all to v6 only after a READ-ONLY trial of every GET shape the
  repo uses. This is that trial, committed so the next major (v7) is one command rather than a rewritten
  harness (.claude\rules\measurement.md: a rewritten probe is a second harness).

  WHAT IT DOES. For each GET shape in $script:Trials it calls the live Admin API twice, once per version,
  and compares the SET OF KEY PATHS in the two JSON bodies (never the values): `posts[].id`,
  `meta.pagination.total`, and so on. An array contributes the union of its elements' paths under `[]`. For
  `settings/` it also records each setting's `key` NAME as `settings[].key=<name>`, because that is what
  the callers look up. It also prints the status code and the Content-Version header of each call, and
  for every `limit=all` shape the number of rows returned beside `meta.pagination.total`.

  WHAT IT NEVER DOES.
  - It sends GET and nothing else: Invoke-ProbeGet refuses any other method before a socket opens.
  - It never prints a member. Members shapes are reduced to their top-level keys and `meta`, so no
    member's fields, ids or values are read into a path at all (Brad's rule for this trial).
  - It never prints a value from any body. Only key names, counts, status codes and version headers.
  - It clears TC_WRITE_JOURNAL for its own process (a GET is never journalled anyway).

  EXIT: 0 no shape differed between the two versions; 1 at least one differed; 3 could not evaluate (no
  key, or a trial failed at either version). The last line is PROBE-GHOST-VERSION-SHAPE-COMPLETE.

  SCOPE OF A CLEAN REPORT: UNSOUND. It compares the shapes it lists, from the resources the site holds
  today (an empty collection has no element paths to compare), and it reads GET only: a write's request
  shape is outside it, and I230 records the Ghost changelog reading for those instead.
#>
[CmdletBinding()]
param(
  [string]$From = 'v5.0',
  [string]$To = 'v6.0',
  [string]$KeyRoot = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here

function Get-JsonKeyPaths {
  <# The set of key paths in a parsed JSON value (JavaScriptSerializer output: dictionaries and arrays).
     -TopOnly keeps only the first level of a named collection, for members. #>
  param($Node, [string]$Prefix = '', [string[]]$TopOnly = @())
  $out = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  if ($Node -is [System.Collections.IDictionary]) {
    foreach ($k in $Node.Keys) {
      $p = if ($Prefix) { $Prefix + '.' + $k } else { [string]$k }
      [void]$out.Add($p)
      if ($Prefix -eq '' -and ($TopOnly -contains [string]$k)) { continue }
      $child = Get-JsonKeyPaths -Node $Node[$k] -Prefix $p -TopOnly $TopOnly
      foreach ($c in $child) { [void]$out.Add($c) }
    }
    if ($Prefix -eq 'settings[]' -and $Node.ContainsKey('key')) { [void]$out.Add('settings[].key=' + [string]$Node['key']) }
  } elseif (($Node -is [System.Collections.IEnumerable]) -and -not ($Node -is [string])) {
    foreach ($el in $Node) {
      $child = Get-JsonKeyPaths -Node $el -Prefix ($Prefix + '[]') -TopOnly $TopOnly
      foreach ($c in $child) { [void]$out.Add($c) }
    }
  }
  return ,$out
}

function Compare-KeyPathSets {
  <# Returns @{ missing = paths in From not in To; added = paths in To not in From }, each sorted ordinally. #>
  param($FromSet, $ToSet)
  $missing = New-Object System.Collections.ArrayList
  $added = New-Object System.Collections.ArrayList
  foreach ($p in $FromSet) { if (-not $ToSet.Contains($p)) { [void]$missing.Add($p) } }
  foreach ($p in $ToSet) { if (-not $FromSet.Contains($p)) { [void]$added.Add($p) } }
  $m = [string[]]$missing.ToArray(); [Array]::Sort($m, [StringComparer]::Ordinal)
  $a = [string[]]$added.ToArray(); [Array]::Sort($a, [StringComparer]::Ordinal)
  return @{ missing = $m; added = $a }
}

function ConvertFrom-ProbeJson([string]$Text) {
  Add-Type -AssemblyName System.Web.Extensions
  $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $ser.MaxJsonLength = [int]::MaxValue
  $ser.RecursionLimit = 1000
  return ,$ser.DeserializeObject($Text)
}

function Invoke-ProbeGet {
  <# GET only. Any other method is refused before a request is built. #>
  param([string]$Method, [string]$Uri, [hashtable]$Headers)
  if (-not [string]::Equals($Method, 'GET', [StringComparison]::Ordinal)) { throw "probe-ghost-version-shape sends GET only, refused $Method" }
  $r = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 90
  return [pscustomobject]@{ status = [int]$r.StatusCode; version = [string]$r.Headers['Content-Version']; body = [string]$r.Content }
}

# Every GET shape the repo's live callers use, reduced to one representative each (census in I230). {POST_ID}
# is filled from the start-here post, which deploy-starthere and verify-starthere read. `top` names collections
# whose elements are NOT walked (members).
$script:Trials = @(
  @{ name = 'site';                       path = 'site/' }
  @{ name = 'posts browse lessons all';   path = 'posts/?limit=all&filter=tag:financial-lessons&fields=slug,title,visibility,published_at&formats='; all = 'posts' }
  @{ name = 'posts browse all ids';       path = 'posts/?limit=all&fields=id&formats='; all = 'posts' }
  @{ name = 'posts browse drafts all';    path = ('posts/?filter=' + [uri]::EscapeDataString('tag:hash-item-request-queue+status:draft') + '&limit=all&fields=id,title,custom_excerpt,created_at'); all = 'posts' }
  @{ name = 'posts browse paged lexical'; path = 'posts/?limit=15&page=1&formats=lexical&fields=id,slug,title,custom_excerpt,visibility,codeinjection_head,lexical' }
  @{ name = 'posts browse paged fields';  path = 'posts/?limit=15&page=1&fields=id,slug,title,visibility,updated_at,codeinjection_head' }
  @{ name = 'posts browse published tag'; path = ('posts/?filter=' + [uri]::EscapeDataString('tag:financial-lessons+status:published') + '&limit=15&page=1&fields=title,slug,custom_excerpt') }
  @{ name = 'posts export shape';         path = 'posts/?formats=lexical,html&limit=15&page=1&include=tags' }
  @{ name = 'pages export shape';         path = 'pages/?formats=lexical,html&limit=15&page=1&include=tags' }
  @{ name = 'post slug fields';           path = 'posts/slug/start-here/?fields=id,slug,visibility,updated_at,status,title,og_image' }
  @{ name = 'post slug full';             path = 'posts/slug/start-here/' }
  @{ name = 'post slug html,lexical';     path = 'posts/slug/start-here/?formats=html,lexical' }
  @{ name = 'post id lexical fields';     path = 'posts/{POST_ID}/?formats=lexical&fields=id,title,custom_excerpt,codeinjection_head,lexical' }
  @{ name = 'post id include email';      path = 'posts/{POST_ID}/?include=email' }
  @{ name = 'page slug html fields';      path = 'pages/slug/meal-prep-recipes/?formats=html&fields=id,html,updated_at' }
  @{ name = 'page slug fields';           path = 'pages/slug/the-52-week-program/?fields=id,updated_at' }
  @{ name = 'page slug lexical';          path = 'pages/slug/membership/?formats=lexical' }
  @{ name = 'members meta only';          path = 'members/?limit=1'; top = @('members') }
  @{ name = 'members include meta only';  path = 'members/?limit=1&include=labels,newsletters'; top = @('members') }
  @{ name = 'settings';                   path = 'settings/' }
  @{ name = 'tiers prices all';           path = 'tiers/?include=monthly_price,yearly_price&limit=all'; all = 'tiers' }
  @{ name = 'tiers benefits all';         path = 'tiers/?include=benefits&limit=all'; all = 'tiers' }
  @{ name = 'newsletters all';            path = 'newsletters/?limit=all'; all = 'newsletters' }
  @{ name = 'newsletters active';         path = 'newsletters/?filter=status:active&limit=1' }
  @{ name = 'tag slug';                   path = 'tags/slug/financial-lessons/?fields=id,name' }
)

if ($SelfTest) {
  $script:n = 0; $script:f = 0
  function Assert-Case([string]$Label, [bool]$Ok, [string]$Got) {
    $script:n++
    if ($Ok) { Write-Output ("  ok   {0}" -f $Label) } else { $script:f++; Write-Output ("  FAIL {0}  got={1}" -f $Label, $Got) }
  }
  try {
    $a = ConvertFrom-ProbeJson '{"posts":[{"id":"1","title":"t"},{"id":"2","og_image":null}],"meta":{"pagination":{"total":2}}}'
    $b = ConvertFrom-ProbeJson '{"posts":[{"id":"9","name":"t"}],"meta":{"pagination":{"total":1}}}'
    $d = Compare-KeyPathSets (Get-JsonKeyPaths $a) (Get-JsonKeyPaths $b)
    Assert-Case 'MUST FIRE  a key renamed between versions (title -> name) reads as missing title and added name' `
      ((@($d.missing) -contains 'posts[].title') -and (@($d.added) -contains 'posts[].name')) (($d.missing -join ',') + ' | ' + ($d.added -join ','))
    Assert-Case 'MUST FIRE  a key present on only ONE array element still counts (og_image on the second post)' `
      (@($d.missing) -contains 'posts[].og_image') ($d.missing -join ',')
    $c = ConvertFrom-ProbeJson '{"posts":[{"id":"7","title":"other value"},{"id":"8","og_image":"x"}],"meta":{"pagination":{"total":99}}}'
    $e = Compare-KeyPathSets (Get-JsonKeyPaths $a) (Get-JsonKeyPaths $c)
    Assert-Case 'MUST NOT FIRE  identical keys with different VALUES are the same shape' `
      (($e.missing.Count -eq 0) -and ($e.added.Count -eq 0)) (($e.missing -join ',') + ' | ' + ($e.added -join ','))
    $m = ConvertFrom-ProbeJson '{"members":[{"id":"m1","email":"x@y.z","name":"N"}],"meta":{"pagination":{"total":1}}}'
    $mp = Get-JsonKeyPaths $m -TopOnly @('members')
    Assert-Case 'MUST FIRE  a members body contributes NO element path, so no member field is ever read into the report' `
      (-not (@($mp) | Where-Object { $_ -like 'members`[`]*' })) ((@($mp) | Sort-Object) -join ',')
    Assert-Case 'CLEAN TWIN  the members body still reports its collection and meta.pagination.total' `
      ($mp.Contains('members') -and $mp.Contains('meta.pagination.total')) ((@($mp) | Sort-Object) -join ',')
    $s = ConvertFrom-ProbeJson '{"settings":[{"key":"codeinjection_foot","value":"secret"},{"key":"navigation","value":"[]"}]}'
    $sp = Get-JsonKeyPaths $s
    Assert-Case 'CLEAN TWIN  settings records each setting NAME the callers look up' `
      ($sp.Contains('settings[].key=codeinjection_foot') -and $sp.Contains('settings[].key=navigation')) ((@($sp) | Sort-Object) -join ',')
    Assert-Case 'MUST NOT FIRE  a setting VALUE never becomes a path' (-not (@($sp) | Where-Object { $_ -like '*secret*' })) ((@($sp) | Sort-Object) -join ',')
    $refused = $false
    try { [void](Invoke-ProbeGet -Method 'PUT' -Uri 'https://invalid.invalid/ghost/api/admin/posts/x/' -Headers @{}) } catch { $refused = ($_.Exception.Message -like '*GET only*') }
    Assert-Case 'MUST FIRE  a PUT is refused before any request is built' $refused ([string]$refused)
    $refusedLower = $false
    try { [void](Invoke-ProbeGet -Method 'get' -Uri 'https://invalid.invalid/' -Headers @{}) } catch { $refusedLower = ($_.Exception.Message -like '*GET only*') }
    Assert-Case 'MUST FIRE  the method test is ordinal: a lower-case get is refused too' $refusedLower ([string]$refusedLower)
    Assert-Case 'CLEAN TWIN  the trial list covers every resource the census found (posts pages members settings tiers newsletters tags site)' `
      ((@('posts','pages','members','settings','tiers','newsletters','tags','site') | Where-Object { $r = $_; -not ($script:Trials | Where-Object { $_.path -like ($r + '/*') -or $_.path -eq ($r + '/') }) }).Count -eq 0) 'resource missing'
  } catch {
    $script:f++; Write-Output ("  FAIL threw: {0}" -f $_.Exception.Message)
  }
  if ($script:f -eq 0 -and $script:n -eq 10) { Write-Output ("probe-ghost-version-shape SELF-TEST PASS: {0} case(s)" -f $script:n); exit 0 }
  Write-Output ("probe-ghost-version-shape SELF-TEST FAIL: {0} of {1} case(s) failed (expected 10 cases)" -f $script:f, $script:n)
  exit 1
}

# ---- live, read-only ----
$env:TC_WRITE_JOURNAL = $null
. (Join-Path $repo 'lib\ghost-lib.ps1')
if (-not $KeyRoot) { $KeyRoot = $repo }
try { $key = Get-GhostKey -Root $KeyRoot } catch {
  Write-Output ('no Ghost key: ' + $_.Exception.Message)
  Write-Output 'PROBE-GHOST-VERSION-SHAPE-COMPLETE trials=0 blind=1'
  exit 3
}
$base = $script:GhostApiUrl + '/ghost/api/admin/'
function New-ProbeHeaders([string]$Ver) { return @{ Authorization = ('Ghost ' + (Get-GhostJWT -Key $key)); 'Accept-Version' = $Ver } }

$seed = ConvertFrom-ProbeJson (Invoke-ProbeGet -Method 'GET' -Uri ($base + 'posts/slug/start-here/?fields=id') -Headers (New-ProbeHeaders $From)).body
$postId = [string]$seed['posts'][0]['id']

$differ = 0; $failed = 0; $ran = 0
Write-Output ("probe-ghost-version-shape: {0} trial(s), {1} vs {2}, GET only, key paths only" -f $script:Trials.Count, $From, $To)
foreach ($t in $script:Trials) {
  $uri = $base + ($t.path -replace '\{POST_ID\}', $postId)
  $top = @(); if ($t.top) { $top = @($t.top) }
  try {
    $ra = Invoke-ProbeGet -Method 'GET' -Uri $uri -Headers (New-ProbeHeaders $From)
    $rb = Invoke-ProbeGet -Method 'GET' -Uri $uri -Headers (New-ProbeHeaders $To)
  } catch {
    $failed++
    Write-Output ("  ERROR {0}: {1}" -f $t.name, $_.Exception.Message)
    continue
  }
  $ran++
  $ja = ConvertFrom-ProbeJson $ra.body; $jb = ConvertFrom-ProbeJson $rb.body
  $pa = Get-JsonKeyPaths $ja -TopOnly $top; $pb = Get-JsonKeyPaths $jb -TopOnly $top
  $d = Compare-KeyPathSets $pa $pb
  $same = ($d.missing.Count -eq 0 -and $d.added.Count -eq 0 -and $ra.status -eq $rb.status)
  if (-not $same) { $differ++ }
  $extra = ''
  if ($t.all) {
    $na = @($ja[$t.all]).Count; $nb = @($jb[$t.all]).Count
    $tot = $ja['meta']['pagination']['total']
    $extra = (" limit=all returned {0}/{1} rows of total={2}" -f $na, $nb, $tot)
  }
  Write-Output ("  {0,-5} {1,-28} status {2}/{3} content-version {4}/{5} paths {6}/{7}{8}" -f `
    ($(if ($same) { 'same' } else { 'DIFF' })), $t.name, $ra.status, $rb.status, $ra.version, $rb.version, $pa.Count, $pb.Count, $extra)
  foreach ($p in $d.missing) { Write-Output ("        missing at {0}: {1}" -f $To, $p) }
  foreach ($p in $d.added) { Write-Output ("        added at {0}: {1}" -f $To, $p) }
}
Write-Output ("PROBE-GHOST-VERSION-SHAPE-COMPLETE trials={0} ran={1} differ={2} failed={3}" -f $script:Trials.Count, $ran, $differ, $failed)
if ($failed -gt 0) { exit 3 }
if ($differ -gt 0) { exit 1 }
exit 0
