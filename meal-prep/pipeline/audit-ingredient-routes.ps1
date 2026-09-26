<#
  audit-ingredient-routes.ps1 - the push-time vocabulary route check: audit-ingredient-identity.ps1 -RoutesOnly.

  run-gates' $static entries take no arguments, so this wrapper is the entry (queue 2026-09-26-177835,
  plan-2026-09-26-2). A push whose commodities.json, ingredients.json or matcher change moves a vocabulary row
  newly off its bid is refused until the rebid rides in the same push. The rule, its fixtures and its exit
  vocabulary live in the child: 0 nothing refused, 2 a row moved off its bid, 3 could not evaluate. This
  wrapper passes the child's exit code and lines through unchanged and adds nothing of its own, so its last
  line is the child's INGREDIENT-IDENTITY-COMPLETE marker.
#>
# gate-inputs: meal-prep\pipeline\audit-ingredient-routes.ps1, meal-prep\pipeline\audit-ingredient-identity.ps1, grocery\commodities.json, meal-prep\db\ingredients.json, ops\out\ingredient-identity-baseline.json, meal-prep\lib\ingredient-identity-lib.ps1, grocery\match-lib.ps1, grocery\global-exclude-lib.ps1, grocery\native-lib.ps1, lib\guard-contract.ps1, lib\json-io.ps1, lib\lf-write.ps1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $repo 'grocery\native-lib.ps1')
$r = Invoke-NativeScript (Join-Path $here 'audit-ingredient-identity.ps1') -RoutesOnly
foreach ($l in @($r.Lines)) { Write-Output $l }
exit $r.ExitCode
