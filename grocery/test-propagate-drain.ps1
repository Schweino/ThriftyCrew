# test-propagate-drain.ps1 - hermetic self-test of grocery\propagate-drain-lib.ps1 (Invoke-TcPropagateDrain).
# WHAT IT READS: the lib, and two stub scripts it writes into a per-run temp folder. No live pipeline, no Ghost.
# gate-inputs: grocery\propagate-drain-lib.ps1
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here 'propagate-drain-lib.ps1')
$script:logLines = New-Object System.Collections.Generic.List[string]
$script:alerts = 0
function Log([string]$m) { $script:logLines.Add($m) }
function Send-Alert { param($Subject, $Body) $script:alerts++ }
$f = 0; $n = 0
function T([string]$name, [bool]$ok, [string]$got) {
  $script:n++
  if ($ok) { Write-Output "  ok    $name" } else { $script:f++; Write-Output "  FAIL  $name  (got: $got)" }
}
$dir = Join-Path $env:TEMP ('pdl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $dir -ErrorAction Stop | Out-Null
function Set-Stubs([int]$SyncRc, [string]$PropLine, [int]$PropRc) {
  Set-Content (Join-Path $dir 'sync-recipesdb-cost.ps1') ("Write-Output 'sync ok'; exit $SyncRc") -Encoding UTF8
  Set-Content (Join-Path $dir 'propagate-recipes.ps1') ("Write-Output '$PropLine'; exit $PropRc") -Encoding UTF8
}
try {
  Set-Stubs 0 'propagate COMPLETE: 3 published' 0
  $r = Invoke-TcPropagateDrain -PipelineDir $dir -Cv2Ok $true -NoAlert
  T 'CLEAN TWIN  a drain that prints its COMPLETE line returns no REVIEW line' ($null -eq $r) ([string]$r)

  Set-Stubs 0 'propagate published 3' 0
  $r = Invoke-TcPropagateDrain -PipelineDir $dir -Cv2Ok $true -NoAlert
  T 'MUST FIRE  exit 0 WITHOUT the COMPLETE line is not done' (([string]$r) -match 'without its COMPLETE line') ([string]$r)

  Set-Stubs 4 'propagate COMPLETE: 0' 0
  $script:logLines.Clear()
  $r = Invoke-TcPropagateDrain -PipelineDir $dir -Cv2Ok $true -NoAlert
  $ranProp = @($script:logLines | Where-Object { $_ -like 'propagate-drain:*' }).Count
  T 'MUST FIRE  a failed sync-recipesdb-cost names itself and propagate never runs' ((([string]$r) -match 'sync-recipesdb-cost exited 4') -and ($ranProp -eq 0)) ("$r ran=$ranProp")

  Set-Stubs 0 'PROPAGATE-DRAIN-REFUSED: 151 dirty' 2
  $script:alerts = 0
  $r = Invoke-TcPropagateDrain -PipelineDir $dir -Cv2Ok $true
  T 'MUST FIRE  a refused drain (exit 2) returns REVIEW and alerts once' ((([string]$r) -match 'exited 2') -and ($script:alerts -eq 1)) ("$r alerts=$($script:alerts)")

  $script:logLines.Clear()
  $r = Invoke-TcPropagateDrain -PipelineDir $dir -Cv2Ok $true -NoPublish -NoAlert
  T 'MUST NOT FIRE  -NoPublish skips the drain and says so' (($null -eq $r) -and (@($script:logLines) -join '|') -match 'skipped under -NoPublish') (@($script:logLines) -join '|')

  $script:logLines.Clear()
  $r = Invoke-TcPropagateDrain -PipelineDir $dir -Cv2Ok $false -NoAlert
  T 'MUST NOT FIRE  a failed compute-v2 runs nothing' (($null -eq $r) -and ($script:logLines.Count -eq 0)) ([string]$script:logLines.Count)
} catch { $f++; Write-Output ('  FAIL  threw: ' + $_.Exception.Message) }
finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
if ($n -ne 6) { $f++; Write-Output "  FAIL  ran $n of 6 cases" }
if ($f) { Write-Output ("test-propagate-drain self-test FAIL: {0} check(s)" -f $f); exit 1 }
Write-Output 'test-propagate-drain self-test pass: 6 cases (3 must-fire, 2 must-not-fire, 1 clean twin)'
exit 0
