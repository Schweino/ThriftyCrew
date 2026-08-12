param(
  [string]$Today = '',
  [string]$QueueRoot = '',
  [switch]$Json,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$requiredSources = @(
  'direct-aldi-browser',
  'direct-fareway-browser',
  'direct-sams-browser',
  'direct-walmart-browser'
)
$strictCoverageStart = [datetime]'2026-08-12'

function Get-OmahaDate([datetime]$Instant) {
  $zone = [TimeZoneInfo]::FindSystemTimeZoneById('Central Standard Time')
  return [TimeZoneInfo]::ConvertTimeFromUtc($Instant.ToUniversalTime(), $zone).Date
}

function Get-MostRecentWednesday([datetime]$Date) {
  $daysSinceWednesday = (([int]$Date.DayOfWeek - [int][DayOfWeek]::Wednesday) + 7) % 7
  return $Date.Date.AddDays(-$daysSinceWednesday)
}

function Get-BrowserCaptureState([string]$Root, [datetime]$AsOf) {
  $weekStart = Get-MostRecentWednesday $AsOf
  $latestBySource = @{}

  if (Test-Path -LiteralPath $Root) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
      $manifestFile = Join-Path $directory.FullName 'manifest.json'
      $artifactFile = Join-Path $directory.FullName 'artifact.json'
      if (-not (Test-Path -LiteralPath $manifestFile) -or -not (Test-Path -LiteralPath $artifactFile)) { continue }
      try {
        $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $artifact = Get-Content -LiteralPath $artifactFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($requiredSources -notcontains [string]$artifact.sourceId) { continue }
        $capturedInstant = [datetime]::Parse([string]$artifact.capturedTo).ToUniversalTime()
        $capturedDate = Get-OmahaDate $capturedInstant
        $candidate = [pscustomobject]@{
          sourceId = [string]$artifact.sourceId
          capturedTo = $capturedInstant.ToString('o')
          capturedDate = $capturedDate.ToString('yyyy-MM-dd')
          status = [string]$manifest.status
          enqueuedAt = [string]$manifest.enqueuedAt
          attempts = [int]$manifest.attempts
          id = [string]$manifest.id
          coverageMode = [string]$artifact.coverageMode
          remoteStatus = [string]$manifest.receipt.remote.status
          matchStatus = [string]$manifest.receipt.remote.matching.status
        }
        $prior = $latestBySource[$candidate.sourceId]
        if ($null -eq $prior -or [datetime]$candidate.capturedTo -gt [datetime]$prior.capturedTo) {
          $latestBySource[$candidate.sourceId] = $candidate
        }
      } catch {
        # A corrupt job can never prove freshness. The queue watchdog owns the
        # detailed alert; this gate simply leaves the source due.
      }
    }
  }

  $sources = foreach ($source in $requiredSources) {
    $latest = $latestBySource[$source]
    $thisWeek = $latest -and ([datetime]$latest.capturedDate -ge $weekStart)
    $strict = $latest -and ([datetime]$latest.capturedDate -ge $strictCoverageStart)
    $remoteReady = @('promoted','superseded') -contains $latest.remoteStatus -and $latest.matchStatus -eq 'passed'
    $fresh = $thisWeek -and $latest.status -eq 'completed' -and (-not $strict -or ($latest.coverageMode -eq 'full' -and $remoteReady))
    $inflight = $thisWeek -and (@('pending', 'retrying') -contains $latest.status -or ($latest.status -eq 'completed' -and -not $fresh))
    [pscustomobject]@{
      sourceId = $source
      state = if ($fresh) { 'fresh' } elseif ($inflight) { 'inflight' } else { 'due' }
      latest = $latest
    }
  }
  $due = @($sources | Where-Object state -eq 'due' | ForEach-Object sourceId)
  $inflight = @($sources | Where-Object state -eq 'inflight' | ForEach-Object sourceId)
  $status = if ($due.Count -gt 0) { 'DUE' } elseif ($inflight.Count -gt 0) { 'INFLIGHT' } else { 'FRESH' }
  return [pscustomobject]@{
    ok = $status -eq 'FRESH'
    status = $status
    asOf = $AsOf.ToString('yyyy-MM-dd')
    weekStart = $weekStart.ToString('yyyy-MM-dd')
    due = $due
    inflight = $inflight
    sources = @($sources)
  }
}

if ($SelfTest) {
  $fixture = Join-Path ([IO.Path]::GetTempPath()) ('tc-browser-due-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $fixture -Force | Out-Null
  try {
    $asOf = [datetime]'2026-08-13'
    $empty = Get-BrowserCaptureState $fixture $asOf
    if ($empty.status -ne 'DUE' -or $empty.due.Count -ne 4) { throw 'empty queue must make all four browser sources due' }
    $index = 0
    foreach ($source in $requiredSources) {
      $index++
      $job = Join-Path $fixture ('capture-' + $index)
      New-Item -ItemType Directory -Path $job | Out-Null
      @{ sourceId = $source; capturedTo = '2026-08-12T11:00:00.000Z'; coverageMode = 'full' } | ConvertTo-Json | Set-Content (Join-Path $job 'artifact.json') -Encoding UTF8
      @{ id = 'capture-' + $index; status = if ($index -eq 4) { 'retrying' } else { 'completed' }; enqueuedAt = '2026-08-12T11:01:00.000Z'; attempts = 1; receipt = @{ remote = @{ status = 'promoted'; matching = @{ status = 'passed' } } } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $job 'manifest.json') -Encoding UTF8
    }
    $waiting = Get-BrowserCaptureState $fixture $asOf
    if ($waiting.status -ne 'INFLIGHT' -or $waiting.inflight.Count -ne 1) { throw 'a current retrying job must report INFLIGHT without recapturing it' }
    $lastManifest = Join-Path (Join-Path $fixture 'capture-4') 'manifest.json'
    $m = Get-Content $lastManifest -Raw | ConvertFrom-Json
    $m.status = 'completed'
    $m | ConvertTo-Json -Depth 5 | Set-Content $lastManifest -Encoding UTF8
    $fresh = Get-BrowserCaptureState $fixture $asOf
    if ($fresh.status -ne 'FRESH') { throw 'four completed current-week captures must report FRESH' }
    Write-Output 'browser-capture-due SELF-TEST PASS'
    exit 0
  } finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# The persistent controller and its SQLite journal are the operational
# freshness authority. The filesystem implementation above remains only as a
# bootstrap/recovery fallback when the controller is unavailable.
try {
  $configFile = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\pc-capture-client.json'
  if (Test-Path -LiteralPath $configFile) {
    $config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'ThriftyCrew.GroceryV3.CaptureController', [IO.Pipes.PipeDirection]::InOut)
    try {
      $pipe.Connect(1500)
      $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
      $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
      $writer.AutoFlush = $true
      $body = if ($Today) { @{ now = ([datetime]::ParseExact($Today, 'yyyy-MM-dd', $null).ToUniversalTime().ToString('o')) } } else { @{} }
      $writer.WriteLine((@{ token = [string]$config.controllerToken; pathname = '/v1/cycle/status'; body = $body } | ConvertTo-Json -Compress))
      $controller = $reader.ReadLine() | ConvertFrom-Json
      if ($controller.ok -eq $true) {
        $controller.status = ([string]$controller.status).ToUpperInvariant()
        if ($Json) { $controller | ConvertTo-Json -Depth 8 }
        else { Write-Output ($controller.status + ' - week of ' + $controller.weekStart + '; controller/journal authority') }
        if ($controller.status -eq 'FRESH') { exit 0 }
        if ($controller.status -eq 'INFLIGHT') { exit 2 }
        exit 1
      }
    } finally { $pipe.Dispose() }
  }
} catch {
  Write-Verbose ('Capture controller unavailable; using the recovery filesystem scan: ' + $_.Exception.Message)
}

if (-not $QueueRoot) {
  $QueueRoot = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\capture-queue'
}
$asOfDate = if ($Today) { [datetime]::ParseExact($Today, 'yyyy-MM-dd', $null).Date } else { Get-OmahaDate ([datetime]::UtcNow) }
$result = Get-BrowserCaptureState $QueueRoot $asOfDate
if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  $detail = if ($result.status -eq 'DUE') { 'missing/stale: ' + ($result.due -join ', ') }
    elseif ($result.status -eq 'INFLIGHT') { 'waiting on queue: ' + ($result.inflight -join ', ') }
    else { 'all four required browser sources completed for this week' }
  Write-Output ($result.status + ' - week of ' + $result.weekStart + '; ' + $detail)
}
if ($result.status -eq 'FRESH') { exit 0 }
if ($result.status -eq 'INFLIGHT') { exit 2 }
exit 1
