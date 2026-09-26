<#
  test-capture-encoding-scope.ps1 -SelfTest - audit-capture-encoding.ps1 names the store of each ambiguous capture file in
  the QUARANTINE-STORE protocol (queue 2026-09-22-6e6a3b, Brad 2026-09-21: one bad item must not hold the board; one
  capture file is one store's prices), and affirms no scope when a file's store cannot be named. Each case runs the real
  audit as a child with -Root at a per-run fixture tree and reads its output through the same Get-TcChildQuarantineScope
  guards.ps1 uses. The founding shape is 2026-09-05's BOM-less Hy-Vee row carrying Campbell's curly apostrophe.
#>
# The self-test runs audit-capture-encoding.ps1 over a temp fixture tree; the audit reads its lane-to-store map from stores.json.
# gate-inputs: grocery\audit-capture-encoding.ps1, grocery\stores.json
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-capture-encoding-scope: run with -SelfTest'; exit 3 }
. (Join-Path $PSScriptRoot 'cell-quarantine-lib.ps1')
$script:bad = 0; $script:n = 0
function Cec([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ces-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$audit = Join-Path $PSScriptRoot 'audit-capture-encoding.ps1'
$noBom = New-Object Text.UTF8Encoding($false); $bom = New-Object Text.UTF8Encoding($true)
$apos = [char]0x2019   # a codepoint, so re-encoding this file can never alter the fixture
function Invoke-Ce([string]$name, [hashtable]$files) {
  $r = Join-Path $tmp $name
  foreach ($k in $files.Keys) {
    $p = Join-Path $r $k
    New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force -ErrorAction Stop | Out-Null
    $enc = $noBom; if ($files[$k].bom) { $enc = $bom }
    [IO.File]::WriteAllText($p, [string]$files[$k].text, $enc)
  }
  $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit -Root $r)
  return [pscustomobject]@{ rc = $LASTEXITCODE; out = $o; text = ($o -join ' / ') }
}
$hyveeBad = @{ text = ('{"store":"Hy-Vee","deals":[{"item":"Campbell' + $apos + 's Turkey Gravy"}]}'); bom = $false }
$samsBad = @{ text = ('{"deals":[{"item":"Member' + $apos + 's Mark Gravy"}]}'); bom = $false }
$walmartOk = @{ text = ('{"store":"Walmart","deals":[{"item":"Great Value' + $apos + 's Gravy"}]}'); bom = $true }
try {
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  # MUST FIRE: the founding BOM-less Hy-Vee file names the store Hy-Vee; a BOM-marked Walmart file beside it is not named.
  $r = Invoke-Ce 'fire' @{ 'regular\hy-vee-regular-2026-09-25.json' = $hyveeBad; 'regular\walmart-regular-2026-09-25.json' = $walmartOk }
  $sc = Get-TcChildQuarantineScope $r.out
  $st = @(); if ($sc) { $st = @($sc.stores) }
  Cec 'MUST FIRE  a BOM-less non-ASCII Hy-Vee file exits 2 and is named for guards as the store Hy-Vee only, scope complete' (($r.rc -eq 2) -and ($null -ne $sc) -and ($st.Count -eq 1) -and ([string]$st[0] -eq 'Hy-Vee')) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST FIRE: a sams-lane file with no store field is named by its lane, Sam's Club.
  $r = Invoke-Ce 'lane' @{ 'sams\sams-deals-2026-09-25.json' = $samsBad }
  $sc = Get-TcChildQuarantineScope $r.out
  $st = @(); if ($sc) { $st = @($sc.stores) }
  Cec 'MUST FIRE  an ambiguous sams-lane file with no store field is named by its lane as Sam''s Club' (($r.rc -eq 2) -and ($null -ne $sc) -and ($st.Count -eq 1) -and ([string]$st[0] -eq 'Sam''s Club')) ('rc=' + $r.rc + ' ' + $r.text)
  # CLEAN TWIN: a regular-lane file with no store field still fails (exit 2, named AMBIGUOUS) and affirms no scope,
  # so guards holds the board exactly as before this change.
  $r = Invoke-Ce 'nostore' @{ 'regular\x-regular-2026-09-25.json' = $samsBad }
  $sc = Get-TcChildQuarantineScope $r.out
  Cec 'CLEAN TWIN  an ambiguous regular file naming no store still exits 2 and is reported AMBIGUOUS, with no scope affirmed' (($r.rc -eq 2) -and ($null -eq $sc) -and ($r.text -match 'AMBIGUOUS  x-regular-2026-09-25\.json')) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST NOT FIRE: a BOM-marked file exits 0 and prints no quarantine line.
  $r = Invoke-Ce 'clean' @{ 'regular\walmart-regular-2026-09-25.json' = $walmartOk }
  Cec 'MUST NOT FIRE  a BOM-marked capture exits 0 and prints no QUARANTINE line' (($r.rc -eq 0) -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Write-Output ('test-capture-encoding-scope self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 4) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (4 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 4) { 0 } else { 1 })
