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
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $FindingsFile) { $FindingsFile = Join-Path $root 'out\semantic-findings.json' }
if (-not (Test-Path $FindingsFile)) { Write-Output 'BLIND: no findings file - run audit-semantic-identity.ps1 first'; exit 3 }

$coms = Read-JsonFile (Join-Path $root 'commodities.json')
$find = Read-JsonFile $FindingsFile

# THE CLASSIFIER LIVES IN coverage-explain-lib.ps1 SINCE 2026-09-18 (queue 2026-09-18-37ac63): the alert's emitter,
# audit-semantic-identity.ps1, now asks it the same question before it pages, so there is ONE copy of the rule.
# Compiled once, in ENGINE ORDER, because first-match-wins is the whole point of the CLAIMED verdict.
. (Join-Path $root 'coverage-explain-lib.ps1')
$explainer = New-CoverageExplainer -Commodities $coms
function Explain([string]$name, [string]$wantId) { return (Get-CoverageVerdict -Explainer $explainer -Name $name -WantId $wantId) }

# The emitter keeps the findings it suppressed as EXCLUDED under coverage_excluded, so this tool still lists
# every finding the sweep made. Guarded on the property: @($null) is ONE element in PS 5.1.
$rows = @($find.coverage)
if ($find.PSObject.Properties['coverage_excluded'] -and $find.coverage_excluded) { $rows = @($rows) + @($find.coverage_excluded) }
if ($Id) { $rows = @($rows | Where-Object { $_.id -eq $Id }) }
$out = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
  $e = Explain ([string]$r.product) ([string]$r.id)
  $out.Add([pscustomobject]@{ id = [string]$r.id; store = [string]$r.store; product = [string]$r.product; verdict = $e.verdict; detail = $e.detail })
}
# Write the output file BEFORE any display. Side effects must not sit downstream of Write-Output loops:
# piping this script through `Select-Object -First N` raises StopUpstreamCommandsException, which
# terminates it mid-run, so a trailing Set-Content never executes. That happened on 2026-08-01 - the
# script printed a correct "explained 62" while leaving the PREVIOUS run's 88-row file on disk, and the
# stale file nearly drove a batch of rule widenings for 16 commodities that had already been fixed. The
# console said one thing and the artifact said another, with no error anywhere.
($out.ToArray() | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $root 'out\coverage-gap-explained.json') -Encoding UTF8

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
exit 0
