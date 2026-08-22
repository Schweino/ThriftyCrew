<#
  input-usage-lib.ps1 - WHICH FILES DID THE BOARD ACTUALLY OPEN?

  BRAD, 2026-08-21, on why grocery\out cannot simply be swept: he asked for the plain version, and it
  is this - the folder holds 870 tracked files, about half a gigabyte, growing ~13 a day, and the files
  the engine STILL NEEDS have exactly the same kind of name as the ones it has finished with.

  Nothing on the outside distinguishes them. compare-deals reads a UNION of dated capture files - up to
  the 90-day capture-policy carry for every store (14 for Walmart until 2026-08-22) - because the rotation only re-prices about 7
  items per store per day. So a file three weeks old can be the only place a given store's price for a
  given commodity exists. Deleting by date bins prices today's board is ranking on, and it does not
  error: the board simply publishes a different store as cheapest and nobody finds out until somebody
  spot-checks a cell, which is exactly how the Hy-Vee store mismatch surfaced the same morning.

  THE FIX IS NOT A SMARTER GUESS, IT IS A RECORD. The engine already knows precisely which files it
  opened - it just never wrote it down. This does that, so "is this file still in use?" stops being a
  judgement call and becomes a lookup.

  ONE ROLLING FILE, NOT ONE PER DAY. A dated manifest per run would add to the very pile it exists to
  measure - the mistake graph\provenance made, at ~200 files a day. So this keeps a single map keyed by
  path, and a file that stops being read simply keeps its old last_used. That is the signal: last_used
  is how you tell a live input from a dead one, and it can only be trusted because it is never
  back-dated or re-stamped for a file the run did not actually open.

  IT RECORDS ONLY REAL BOARD BUILDS. A regression or fixture run reads a PINNED set of inputs, and
  recording those would stamp last_used on files the live board has not touched in weeks - marking dead
  files alive, which is worse than no record at all because it reads as evidence. The caller passes
  -IsLiveBuild only when it is building the published board.

  WHAT IT DELIBERATELY DOES NOT DO: delete anything, or recommend deleting anything. It is a ledger.
  A file being unread today does not make it disposable - the 90-day quarter means a capture can sit
  unused for weeks and then be the freshest thing a commodity has. Read the AGE of last_used against
  the carry window before anyone acts on it, and that is a separate decision with its own evidence.

  Usage:
      . input-usage-lib.ps1
      $u = New-InputUsageTracker
      Add-InputUsed -Tracker $u -Path $file -Role 'everyday'
      Save-InputUsage -Tracker $u -OutDir $OutDir -Today $today -IsLiveBuild:$live
#>

function New-InputUsageTracker {
  # Ordered so the emitted record is diff-friendly rather than hash-ordered.
  return [ordered]@{ used = New-Object System.Collections.Generic.List[object] }
}

function Add-InputUsed {
  <#
    .SYNOPSIS Note that the engine opened this file, and in what role.
    .DESCRIPTION Silently ignores an empty path so callers can pass an optional input straight through
                 without each of them re-implementing the same null check - a check that gets forgotten
                 in exactly one of six call sites and then the record is quietly incomplete.
  #>
  param($Tracker, [string]$Path, [string]$Role)
  if (-not $Tracker -or -not $Path) { return }
  [void]$Tracker.used.Add([pscustomobject]@{ path = [string]$Path; role = [string]$Role })
}

function Save-InputUsage {
  <#
    .SYNOPSIS Merge this run's opened files into the rolling ledger.
    .DESCRIPTION Paths are stored RELATIVE to grocery\out so the ledger is portable and readable, and
                 so the same capture does not appear twice under two spellings of the same location.
                 Returns the number of distinct files recorded, or -1 when it declined to record.
  #>
  param($Tracker, [string]$OutDir, [string]$Today, [switch]$IsLiveBuild, [string]$LedgerPath = '')
  if (-not $Tracker) { return -1 }
  # See the header: a pinned run must never stamp last_used on files the live board did not open.
  if (-not $IsLiveBuild) { return -1 }
  if (-not $Today) { return -1 }

  if (-not $LedgerPath) { $LedgerPath = Join-Path $OutDir 'input-usage.json' }
  $files = [ordered]@{}
  if (Test-Path $LedgerPath) {
    try {
      $prior = ConvertFrom-Json ([IO.File]::ReadAllText($LedgerPath))
      foreach ($p in $prior.files.PSObject.Properties) {
        $files[$p.Name] = [ordered]@{
          role = [string]$p.Value.role; first_used = [string]$p.Value.first_used
          last_used = [string]$p.Value.last_used; uses = [int]$p.Value.uses
        }
      }
    } catch { }
  }

  $outFull = ''
  try { $outFull = (Resolve-Path -LiteralPath $OutDir -ErrorAction Stop).Path } catch { $outFull = $OutDir }
  $seen = @{}
  foreach ($u in $Tracker.used) {
    $rel = [string]$u.path
    try {
      $full = (Resolve-Path -LiteralPath $u.path -ErrorAction Stop).Path
      if ($outFull -and $full.StartsWith($outFull, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($outFull.Length).TrimStart('\', '/')
      } else { $rel = $full }
    } catch { }
    $rel = $rel -replace '\\', '/'
    # ONE COUNT PER RUN, however many times a run touched the same file. `uses` is meant to read as
    # "builds that needed this", and letting a single build increment it twice would make an
    # occasionally-read file look busier than a daily one.
    if ($seen.ContainsKey($rel)) { continue }
    $seen[$rel] = $true
    if ($files.Contains($rel)) {
      $e = $files[$rel]
      # first_used is written ONCE and never moved - the same discipline as the rollback TTL anchor and
      # the sale-without-ad ledger. An age that re-stamps itself measures nothing.
      if ($e.last_used -ne $Today) { $e.uses = [int]$e.uses + 1 }
      $e.last_used = $Today
      if ($u.role) { $e.role = [string]$u.role }
    } else {
      $files[$rel] = [ordered]@{ role = [string]$u.role; first_used = $Today; last_used = $Today; uses = 1 }
    }
  }

  $doc = [ordered]@{
    updated = (Get-Date).ToString('s')
    last_live_build = $Today
    note = 'Which files the LIVE board actually opened, and when. The engine reads a UNION of dated captures (up to the 90-day capture-policy carry for every store (14 for Walmart until 2026-08-22)) because the rotation only re-prices ~7 items per store per day, so a weeks-old file can be the only place a store''s price for a commodity exists - and a dated input is named exactly like a disposable output. last_used is what tells them apart. Recorded ONLY on live builds; a pinned regression run would stamp files the board has not touched. This is a ledger, not a delete list: judge last_used against the carry window before acting.'
    tracked_files = $files.Count
    files = $files
  }
  $tmp = "$LedgerPath.tmp"
  [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $LedgerPath -Force
  return $seen.Count
}
