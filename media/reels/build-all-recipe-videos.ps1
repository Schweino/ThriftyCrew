<#
build-all-recipe-videos.ps1 - a reel for every recipe in the catalogue, into one folder.

WHAT THIS IS FOR
  The daily reel picks one recipe a morning and takes 18 months to work through 534 of them. This
  builds the whole catalogue as an archive Brad can post from in any order, at any pace.

WHY IT IS A SEPARATE SCRIPT AND NOT A LOOP IN THE SHELL
  A run this long needs three things a loop does not give you:
    RESUMABLE   it skips any recipe whose mp4 already exists, so a crash, a reboot or a deliberate
                stop costs only the recipe in flight. Just run it again.
    ISOLATED    one bad recipe fails that recipe and nothing else. Over 534 attempts something will
                have a missing macro or an unpriced ingredient, and that must not end the run.
    ACCOUNTED   every attempt lands in a manifest with its outcome, so "did it finish" is a question
                with an answer rather than a folder you have to count.

WHAT IT DELIBERATELY DOES NOT DO
  It never writes reel-state.json. That file exists so the DAILY reel avoids repeating itself; 534
  entries would empty its pool and break the thing it protects. Every build here passes -NoState.

  It also does not stop the daily job from running at 10:00, and the two do not collide: separate
  output folders, and this one touches no shared state. That is not an accident, it is the reason
  -NoState exists.

USAGE
  .\build-all-recipe-videos.ps1                    # build everything missing
  .\build-all-recipe-videos.ps1 -Limit 5           # first 5 only, to sanity-check the output
  .\build-all-recipe-videos.ps1 -OnlyFree          # just this week's free rotation
  .\build-all-recipe-videos.ps1 -Rebuild           # ignore existing files and redo everything
#>
[CmdletBinding()]
param(
  [string] $OutDir  = 'C:\Codex\ThriftyCrew\media\videos',
  [string] $Voice   = 'goku-podcast',
  [int]    $Limit   = 0,
  [switch] $OnlyFree,
  [switch] $Rebuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ReelRoot = $PSScriptRoot
$Income   = Split-Path $ReelRoot -Parent
$Builder  = Join-Path $ReelRoot 'build-reel.ps1'
$Manifest = Join-Path $OutDir 'build-manifest.json'
$LogFile  = Join-Path $OutDir 'build-log.txt'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---------------------------------------------------------------- one run at a time
# Two concurrent runs share this OutDir, and therefore share build-reel's .work directory, where they
# overwrite each other's frames mid-render. The symptom is not a clash, it is "Chrome produced no
# frame for scene 'title'" on a recipe that is perfectly fine, which sends you looking in the wrong
# place. Learned by doing it: a relaunch while the first run was still alive corrupted both.
$LockFile = Join-Path $OutDir '.run.lock'
if (Test-Path $LockFile) {
  $held = 0
  if ([int]::TryParse((Get-Content $LockFile -Raw -ErrorAction SilentlyContinue), [ref]$held)) {
    if (Get-Process -Id $held -ErrorAction SilentlyContinue) {
      throw ("Another run is already building into $OutDir (pid $held). Two runs share one work " +
             "directory and corrupt each other's frames. Wait for it, or stop it first.")
    }
  }
  Write-Warning "Clearing a stale lock from pid $held (no such process)."
  Remove-Item $LockFile -Force
}
Set-Content -Path $LockFile -Value $PID -Encoding ASCII
# Released however the run ends, including Ctrl-C, so a crash does not need a manual cleanup.
$null = Register-EngineEvent PowerShell.Exiting -Action {
  Remove-Item $using:LockFile -Force -ErrorAction SilentlyContinue
} -ErrorAction SilentlyContinue

function Write-Log {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
  Write-Output $line
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------- the work list

$psFile = Join-Path $Income 'meal-prep\pipeline\v2-perserving.json'
$frFile = Join-Path $Income 'meal-prep\free-rotation.json'
$perServing = Get-Content $psFile -Raw | ConvertFrom-Json
$rotation   = Get-Content $frFile -Raw | ConvertFrom-Json
$freeSlugs  = @($rotation.free | ForEach-Object { $_.slug })

# v2-perserving.json is a JSON ARRAY of records. Probe with PSObject.Properties rather than $_.slug,
# because StrictMode turns a missing property into a terminating error instead of a false.
function Test-HasSlug { param($Obj) return ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties['slug'] -and $Obj.slug) }

$all = @($perServing | Where-Object { Test-HasSlug $_ })
if ($all.Count -eq 0) {
  # Tolerate the object-keyed shape too, in case the pipeline ever emits one.
  $all = @($perServing.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { Test-HasSlug $_ })
}
if ($all.Count -eq 0) { throw "Could not read any recipes from $psFile" }
if ($OnlyFree) { $all = @($all | Where-Object { $freeSlugs -contains $_.slug }) }

# Cheapest first: if the run is ever cut short, the recipes left undone are the least compelling
# ones rather than an arbitrary slice of the alphabet.
$all = @($all | Sort-Object { [double]$_.cheapest_ps })
if ($Limit -gt 0) { $all = @($all | Select-Object -First $Limit) }

$done = @{}
if (-not $Rebuild) {
  foreach ($f in Get-ChildItem $OutDir -Filter '*.mp4' -ErrorAction SilentlyContinue) {
    $done[$f.BaseName] = $true
  }
}
$todo = @($all | Where-Object { -not $done.ContainsKey($_.slug) })

Write-Log ("catalogue {0} | already built {1} | to build {2}" -f $all.Count, $done.Count, $todo.Count)
if ($todo.Count -eq 0) { Write-Log 'nothing to do'; return }

# Azure's free tier is 500,000 characters a month and a reel narrates roughly 650 of them. Say so up
# front rather than discovering the ceiling two thirds of the way through an overnight run.
$estChars = $todo.Count * 650
Write-Log ("estimated Azure characters: ~{0:N0} of the 500,000 monthly free allowance" -f $estChars)
if ($estChars -gt 450000) {
  Write-Warning 'This run may exhaust the free tier. Synthesis would fall back to the free endpoint mid-run, which changes the voice.'
}

# ---------------------------------------------------------------- build

$results = New-Object System.Collections.Generic.List[object]
$ok = 0; $failed = 0
$started = Get-Date

for ($i = 0; $i -lt $todo.Count; $i++) {
  $r = $todo[$i]
  $n = $i + 1
  $elapsed = (Get-Date) - $started
  $eta = if ($ok + $failed -gt 0) {
    $per = $elapsed.TotalSeconds / ($ok + $failed)
    ' | eta ' + [timespan]::FromSeconds($per * ($todo.Count - $i)).ToString('hh\:mm')
  } else { '' }
  Write-Log ("[{0}/{1}] {2}{3}" -f $n, $todo.Count, $r.slug, $eta)

  $entry = [ordered]@{ slug = $r.slug; name = $r.name; per_serving = $r.cheapest_ps }
  try {
    # -NoState is the load-bearing flag here. Without it this run empties the daily rotation.
    $out = & $Builder -Slug $r.slug -OutDir $OutDir -Voice $Voice -NoState 2>&1
    $mp4 = Get-ChildItem $OutDir -Filter "*$($r.slug).mp4" -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $mp4) { throw 'builder reported success but produced no mp4' }

    # The builder names files with today's date. This archive is posted over months, so the date is
    # noise that would also break resume; keep one file per recipe, named for the recipe.
    $finalMp4 = Join-Path $OutDir "$($r.slug).mp4"
    $finalTxt = Join-Path $OutDir "$($r.slug).txt"
    Move-Item $mp4.FullName $finalMp4 -Force
    $txt = Get-ChildItem $OutDir -Filter "*$($r.slug).txt" -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -ne $finalTxt } | Select-Object -First 1
    if ($txt) { Move-Item $txt.FullName $finalTxt -Force }

    $voiceLine = ($out | Where-Object { $_ -match '^Voiceover' } | Select-Object -First 1)
    $fellBack  = [bool]($out | Where-Object { $_ -match 'AZURE SYNTHESIS FAILED' })
    $entry.status = 'ok'
    $entry.file   = "$($r.slug).mp4"
    $entry.voice  = if ($voiceLine) { ($voiceLine -replace '^Voiceover\s*:\s*', '') } else { '' }
    $entry.fell_back_to_free_endpoint = $fellBack
    if ($fellBack) { Write-Log "  WARNING: fell back to the free endpoint, this one is NOT in the house voice" }
    $ok++
  } catch {
    $entry.status = 'failed'
    $entry.error  = ($_.Exception.Message -split "`n" | Select-Object -First 1)
    Write-Log ("  FAILED: {0}" -f $entry.error)
    $failed++
  }
  $results.Add([pscustomobject]$entry)

  # Written every time, not at the end: a run this long will be interrupted at some point, and a
  # manifest that only exists on clean completion is a manifest you never get.
  [System.IO.File]::WriteAllText($Manifest,
    ([pscustomobject]@{
       built_at = (Get-Date).ToString('s'); voice = $Voice
       ok = $ok; failed = $failed; total = $todo.Count
       results = $results
     } | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
}

Remove-Item $LockFile -Force -ErrorAction SilentlyContinue

Write-Log ("done: {0} built, {1} failed, {2} elapsed" -f $ok, $failed, ((Get-Date) - $started).ToString('hh\:mm\:ss'))
Write-Log ("folder  : $OutDir")
Write-Log ("manifest: $Manifest")
if ($failed -gt 0) { Write-Log 'rerun the script to retry only the failures; finished recipes are skipped' }
