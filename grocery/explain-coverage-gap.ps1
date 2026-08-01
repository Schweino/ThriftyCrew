<#
  explain-coverage-gap.ps1 - why is THIS product invisible to THIS commodity's rule?

  The semantic sweep says "no rule matches this product but it looks like commodity X". That is a lead,
  not a diagnosis, and acting on a lead without a diagnosis is how a rule gets widened for the wrong
  reason. There are four completely different causes and they need four different responses:

    NO-INCLUDE    no include pattern matches      -> the rule genuinely cannot see it. Widen (carefully).
    EXCLUDED      an include matched, an exclude killed it  -> USUALLY CORRECT. The exclude is doing its
                  job (a "Pumpkin Pie" is not a pie pumpkin). Only touch it if the exclude is overbroad.
    CLAIMED       a DIFFERENT commodity matched first (first-match-wins by array order) -> this is the
                  collision trap: widening the intended rule changes nothing, because the other
                  commodity still wins. The fix is order or the other rule's excludes.
    MATCHES       the include DOES match and nothing excludes it -> the product is not actually invisible
                  and the sweep's premise was wrong for this row. Verify the premise before fixing it.

  Usage:  .\explain-coverage-gap.ps1                 explain every row in out\semantic-findings.json
          .\explain-coverage-gap.ps1 -Id ground-beef-93-7
#>
param([string]$Id = '', [string]$FindingsFile = '')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $FindingsFile) { $FindingsFile = Join-Path $root 'out\semantic-findings.json' }
if (-not (Test-Path $FindingsFile)) { Write-Output 'BLIND: no findings file - run audit-semantic-identity.ps1 first'; exit 3 }

$coms = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$find = Get-Content $FindingsFile -Raw | ConvertFrom-Json

# compile once, in ENGINE ORDER, because first-match-wins is the whole point of the CLAIMED verdict
$rx = New-Object System.Collections.Generic.List[object]
$exc = @{}
foreach ($c in $coms) {
  foreach ($p in @($c.include)) { if ($p) { $rx.Add([pscustomobject]@{ id = [string]$c.id; pat = [string]$p; r = [regex]::new([string]$p, 'IgnoreCase,Compiled') }) } }
  $l = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($c.exclude)) { if ($p) { $l.Add([pscustomobject]@{ pat = [string]$p; r = [regex]::new([string]$p, 'IgnoreCase,Compiled') }) } }
  $exc[[string]$c.id] = $l
}

function Explain([string]$name, [string]$wantId) {
  # what the engine would actually do, in order
  $claimedBy = ''
  foreach ($e in $rx) {
    if (-not $e.r.IsMatch($name)) { continue }
    $killed = $false
    foreach ($x in $exc[$e.id]) { if ($x.r.IsMatch($name)) { $killed = $true; break } }
    if (-not $killed) { $claimedBy = $e.id; break }
  }
  # what the INTENDED commodity thinks of it
  $incHit = ''
  foreach ($e in $rx) { if ($e.id -eq $wantId -and $e.r.IsMatch($name)) { $incHit = $e.pat; break } }
  $excHit = ''
  if ($exc.ContainsKey($wantId)) { foreach ($x in $exc[$wantId]) { if ($x.r.IsMatch($name)) { $excHit = $x.pat; break } } }

  if ($claimedBy -and $claimedBy -ne $wantId) { return [pscustomobject]@{ verdict = 'CLAIMED'; detail = "claimed first by '$claimedBy'" } }
  if ($incHit -and $excHit) { return [pscustomobject]@{ verdict = 'EXCLUDED'; detail = "include '$incHit' matched, exclude '$excHit' killed it" } }
  if ($incHit) { return [pscustomobject]@{ verdict = 'MATCHES'; detail = "include '$incHit' already matches - the sweep's premise is wrong for this row" } }
  return [pscustomobject]@{ verdict = 'NO-INCLUDE'; detail = 'no include pattern matches' }
}

$rows = @($find.coverage)
if ($Id) { $rows = @($rows | Where-Object { $_.id -eq $Id }) }
$out = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
  $e = Explain ([string]$r.product) ([string]$r.id)
  $out.Add([pscustomobject]@{ id = [string]$r.id; store = [string]$r.store; product = [string]$r.product; verdict = $e.verdict; detail = $e.detail })
}
$by = @($out | Group-Object verdict | Sort-Object { -(@($_.Group).Count) })
Write-Output ("explained {0} coverage finding(s):" -f $out.Count)
foreach ($g in $by) { Write-Output ("  {0,-11} {1}" -f $g.Name, @($g.Group).Count) }
Write-Output ''
foreach ($g in $by) {
  Write-Output ("--- {0} ---" -f $g.Name)
  foreach ($r in ($g.Group | Sort-Object id)) {
    Write-Output ("  {0,-24} [{1,-12}] {2}" -f $r.id, $r.store, ([string]$r.product).Substring(0, [math]::Min(52, ([string]$r.product).Length)))
    Write-Output ("      {0}" -f $r.detail)
  }
}
($out.ToArray() | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $root 'out\coverage-gap-explained.json') -Encoding UTF8
exit 0
