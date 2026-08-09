<#
  adpages-lib.ps1 - SAFE INSTALL of a downloaded image-flyer page set.

  FOUNDING BUG (2026-08-09, Fareway weekly). pull-fareway-ads.ps1 downloaded straight into
  out\fareway\weekly\ and never cleared it. The 2026-08-02..08 ad had 24 pages; the 2026-08-09..15 ad has
  22. After the pull the folder held weekly-1..22 from the NEW ad plus weekly-23.jpg and weekly-24.jpg
  still sitting there from the EXPIRED one - and nothing on disk distinguishes them. weekly-23.jpg was
  vision-confirmed as page 23 of the old ad (Personal Care / Pets). The documented vision-read step globs
  out\fareway\weekly\*.jpg, so a closed ad's prices could enter the board as if they were current.

  It is the expired-ad-supplement class Brad ruled on 2026-08-07 (compare-deals skips a fareway-deals file
  whose ad_to has passed) - except it BYPASSES that guard completely, because the stale data arrives as an
  IMAGE, before any ad_to header exists to check. The only place it can be caught is here, at install time.

  THE CONTRACT:
    1. Pages download to a STAGING dir, never to the live one.
    2. Nothing is installed unless EVERY intended page arrived. An incomplete download leaves the previous
       ad untouched (better a known-stale folder, stamped as stale, than a store with no ad at all) and
       reports blocked - it never half-swaps.
    3. On install the live dir's own page files are removed FIRST, so a shrinking ad cannot leave orphans.
    4. After the swap the page set on disk is re-counted and must equal what was installed. That assertion
       is what makes the manifest's page count a measured fact instead of a hopeful one.
    5. ad-window.json is stamped INTO the image dir, so a reader can always tell which window the images
       on disk actually belong to - including when the install was refused and they are last week's.

  Deletion is scoped by parsing each filename as <Prefix>-<N>.jpg and removing only those. Never a raw
  wildcard: out\bakers\ also holds bakers-deals-*.json, urls.txt and meta.json.

  Dot-source it:  . (Join-Path $PSScriptRoot 'adpages-lib.ps1')
#>

# Smaller than this and the "download" was an error page or a truncated write, not a flyer page.
$script:AdPageMinBytes = 5000

function Get-AdPageMap {
  # Page number -> FileInfo for every <Prefix>-<N>.jpg in $Dir. Tolerates zero padding (Baker's writes
  # page-01.jpg, Fareway writes weekly-1.jpg) because the number is parsed, not string-matched.
  param([string]$Dir, [string]$Prefix)
  $map = @{}
  if (-not (Test-Path $Dir)) { return $map }
  $rx = '^' + [regex]::Escape($Prefix) + '-(\d+)\.jpg$'
  foreach ($f in @(Get-ChildItem -Path $Dir -Filter '*.jpg' -File -ErrorAction SilentlyContinue)) {
    $m = [regex]::Match($f.Name, $rx, 'IgnoreCase')
    if ($m.Success) { $map[[int]$m.Groups[1].Value] = $f }
  }
  return $map
}

function Test-AdPageSet {
  # THE ASSERTION. What is on disk must be exactly the page set we believe we published - no more, no less.
  # The "no more" half is the founding bug: a 22-page ad over a 24-page one leaves 23 and 24 behind.
  param([string]$Dir, [string]$Prefix, [int[]]$Expected)
  $want = @{}; foreach ($n in @($Expected)) { $want[[int]$n] = $true }
  $have = Get-AdPageMap -Dir $Dir -Prefix $Prefix
  $extra   = @(@($have.Keys)   | Where-Object { -not $want.ContainsKey($_) } | Sort-Object)
  $missing = @(@($want.Keys)   | Where-Object { -not $have.ContainsKey($_) } | Sort-Object)
  $small   = @(@($have.Values) | Where-Object { $_.Length -le $script:AdPageMinBytes } | ForEach-Object { $_.Name } | Sort-Object)
  $bits = @()
  if ($extra.Count)   { $bits += ('ORPHAN pages left from a previous ad: ' + (($extra   | ForEach-Object { "$Prefix-$_.jpg" }) -join ', ')) }
  if ($missing.Count) { $bits += ('MISSING pages: '                       + (($missing | ForEach-Object { "$Prefix-$_.jpg" }) -join ', ')) }
  if ($small.Count)   { $bits += ('TRUNCATED pages (<= ' + $script:AdPageMinBytes + ' bytes): ' + ($small -join ', ')) }
  return [pscustomobject]@{
    ok       = ($bits.Count -eq 0)
    count    = @($have.Keys).Count
    expected = @($Expected).Count
    extra    = $extra
    missing  = $missing
    reason   = $(if ($bits.Count) { $bits -join ' | ' } else { 'page set on disk matches the manifest' })
  }
}

function Get-AdPageGaps {
  # A source-numbering oddity, NOT our failure: the ad offered pages 1..N with one missing. Reported so it
  # is visible, never blocking - a guard that deletes a live ad over the vendor's numbering is worse than
  # the gap it was watching for.
  param([int[]]$Pages)
  $ns = @(@($Pages) | Sort-Object)
  if ($ns.Count -eq 0) { return @() }
  $gaps = @()
  for ($i = 1; $i -le $ns[$ns.Count - 1]; $i++) { if ($ns -notcontains $i) { $gaps += $i } }
  return @($gaps)
}

function Read-AdWindowStamp {
  # What window do the images CURRENTLY on disk belong to? Absent stamp = written before this contract
  # existed, so the honest answer is unknown.
  param([string]$Dir)
  $p = Join-Path $Dir 'ad-window.json'
  if (-not (Test-Path $p)) { return $null }
  try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Install-AdPages {
  <#
    Swap $Staging into $Dir, all-or-nothing.
      -Expected : the page numbers we INTENDED to download (from the source markup / URL list).
      -Stamp    : hashtable folded into ad-window.json (from/to/store/...).
    Returns { ok, installed, on_disk, reason }. On failure $Dir is left exactly as it was.
  #>
  param(
    [string]$Dir,
    [string]$Staging,
    [string]$Prefix,
    [int[]]$Expected,
    [hashtable]$Stamp = @{}
  )
  $expCount = @($Expected).Count
  if ($expCount -eq 0) {
    return [pscustomobject]@{ ok=$false; installed=0; on_disk=@(Get-AdPageMap -Dir $Dir -Prefix $Prefix).Keys.Count; reason='no pages were intended - nothing to install' }
  }

  # GATE: the staging dir must hold the complete set before the live dir is touched at all.
  $stage = Test-AdPageSet -Dir $Staging -Prefix $Prefix -Expected $Expected
  if (-not $stage.ok) {
    $onDisk = Get-AdPageMap -Dir $Dir -Prefix $Prefix
    return [pscustomobject]@{
      ok=$false; installed=0; on_disk=@($onDisk.Keys).Count
      reason=('download incomplete (' + $stage.count + ' of ' + $expCount + ' pages staged: ' + $stage.reason + ') - the previous ad was left in place, NOT overwritten')
    }
  }

  if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }

  # CLEAR FIRST - this is the fix. Scoped to parsed <Prefix>-<N>.jpg names so sibling data files survive.
  foreach ($f in @((Get-AdPageMap -Dir $Dir -Prefix $Prefix).Values)) { Remove-Item $f.FullName -Force -ErrorAction Stop }
  $oldStamp = Join-Path $Dir 'ad-window.json'
  if (Test-Path $oldStamp) { Remove-Item $oldStamp -Force -ErrorAction SilentlyContinue }

  foreach ($kv in (Get-AdPageMap -Dir $Staging -Prefix $Prefix).GetEnumerator()) {
    Move-Item $kv.Value.FullName (Join-Path $Dir $kv.Value.Name) -Force -ErrorAction Stop
  }

  # POST-SWAP ASSERTION: re-measure, do not assume the moves did what they were asked to.
  $after = Test-AdPageSet -Dir $Dir -Prefix $Prefix -Expected $Expected
  if (-not $after.ok) {
    return [pscustomobject]@{ ok=$false; installed=$after.count; on_disk=$after.count; reason=('post-install assertion FAILED: ' + $after.reason) }
  }

  $rec = [ordered]@{}
  foreach ($k in @($Stamp.Keys)) { $rec[$k] = $Stamp[$k] }
  $rec['prefix'] = $Prefix
  $rec['pages']  = $after.count
  $rec['page_numbers'] = @(@($Expected) | Sort-Object)
  ($rec | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $Dir 'ad-window.json') -Encoding UTF8

  # Staging is cleared on success only. After a REFUSED install it stays put: those partial pages are the
  # evidence for why the swap did not happen, and the next run clears it before staging anything new.
  if ((Test-Path $Staging) -and @(Get-ChildItem $Staging -File -ErrorAction SilentlyContinue).Count -eq 0) {
    Remove-Item $Staging -Recurse -Force -ErrorAction SilentlyContinue
  }
  return [pscustomobject]@{ ok=$true; installed=$after.count; on_disk=$after.count; reason=('OK (' + $after.count + ' pages installed, folder cleared first)') }
}

function New-AdStagingDir {
  # Cleared every run: a leftover partial from LAST run's failed download would otherwise be counted as
  # this run's staged pages and installed as if complete.
  param([string]$Path)
  if (Test-Path $Path) { Remove-Item (Join-Path $Path '*') -Recurse -Force -ErrorAction SilentlyContinue }
  else { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
  return $Path
}
