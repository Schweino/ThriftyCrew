<#
  test-pulib-differential.ps1 - prove a change to pu-lib.ps1 did ONLY what it claimed.

  pu-lib is the single per-unit implementation behind BOTH the published page and the guards that gate it.
  A regression here is invisible twice over: the page prints a wrong number and the gate agrees with it.
  Reasoning about the regex is not enough - I already shipped one pu-lib-adjacent change ("N Ea") that a
  differential caught and my reading had not.

  So: run the OLD function (from git) and the NEW one (working tree) over EVERY stored link, and classify
  every disagreement. A change is safe only when the disagreements are exactly the ones intended.

  Usage: test-pulib-differential.ps1 [-Ref HEAD]
  Exit 0 always - this reports, the human judges. It is a differential, not a gate.
#>
param([string]$Ref = 'HEAD')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# OLD, straight from git, renamed so both can live in one session
Push-Location $root
$old = (git show ("{0}:grocery/pu-lib.ps1" -f $Ref) | Out-String)
Pop-Location
if (-not $old -or $old.Length -lt 200) { Write-Output "could not read pu-lib.ps1 from $Ref"; exit 1 }
Invoke-Expression ($old -replace 'function Get-LinkPerUnit', 'function Get-OldPU')

# NEW, from the working tree
. (Join-Path $root 'pu-lib.ps1')

$cmpF = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1
$cmp = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison
$pu = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
$unitOf = @{}
foreach ($r in $cmp) { $unitOf[[string]$r.id] = [string]$r.unit }

$same = 0; $changed = @(); $gained = @(); $lost = @()
foreach ($idp in $pu.PSObject.Properties) {
  $id = $idp.Name
  if (-not $unitOf.ContainsKey($id)) { continue }
  $u = $unitOf[$id]
  foreach ($stp in $idp.Value.PSObject.Properties) {
    $l = $stp.Value
    $p = 0.0; [void][double]::TryParse((([string]$l.price) -replace '[^0-9.]', ''), [ref]$p)
    if ($p -le 0) { continue }
    $a = Get-OldPU        -size ([string]$l.size) -unit $u -price $p -name ([string]$l.name)
    $b = Get-LinkPerUnit  -size ([string]$l.size) -unit $u -price $p -name ([string]$l.name)
    $tag = ('  {0,-22}{1,-13}unit={2,-7}size=[{3}]' -f $id, $stp.Name, $u, [string]$l.size)
    if ($null -eq $a -and $null -eq $b) { $same++ }
    elseif ($null -eq $a -and $null -ne $b) { $gained += ($tag + '   null -> ' + [math]::Round($b, 4)) }
    elseif ($null -ne $a -and $null -eq $b) { $lost += ($tag + '   ' + [math]::Round($a, 4) + ' -> null') }
    elseif ([math]::Abs($a - $b) -gt 0.00001) { $changed += ($tag + '   ' + [math]::Round($a, 4) + ' -> ' + [math]::Round($b, 4)) }
    else { $same++ }
  }
}

Write-Output ("pu-lib differential vs " + $Ref + "  (" + $cmpF.Name + ")")
Write-Output ''
Write-Output ("  identical                    : " + $same)
Write-Output ("  GAINED (null -> a number)    : " + $gained.Count)
$gained | ForEach-Object { Write-Output $_ }
Write-Output ("  LOST (a number -> null)      : " + $lost.Count)
$lost | ForEach-Object { Write-Output $_ }
Write-Output ("  CHANGED (number -> different): " + $changed.Count)
$changed | ForEach-Object { Write-Output $_ }
Write-Output ''
if ($lost.Count -or $changed.Count) {
  Write-Output 'REVIEW REQUIRED: this change altered or removed an answer it may not have meant to.'
  Write-Output 'A pu-lib edit that only ADDS coverage shows GAINED>0 with LOST=0 and CHANGED=0.'
}
else { Write-Output 'This change is purely additive: no existing answer moved.' }
exit 0
