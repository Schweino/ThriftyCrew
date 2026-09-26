<#
  reconcile-ghost-drift.ps1 - the REPAIR lane for audit-ghost-drift's tool pages (2026-09-23, plan-2026-09-22-9
  item discovered:ghost-drift-reconciler-2026-09-22). It is the resolver of the ghost-drift alert type.

  WHY. audit-ghost-drift says THAT a live tool page and its local source differ, and until now a human had to decide
  which side was right, every time. Three of the four cases are decidable from what we already keep, so they are
  decided here and only the fourth reaches a person:
    match      live equals the committed source (after Ghost's URL and line-ending round trip)  - nothing to do
    republish  live equals an OLDER committed version of the source: nobody edited Ghost, we just never republished
               after the source moved. Republishing loses nothing, because every byte live holds is in git.
    save-back  live equals NO committed version (someone edited Ghost), and the source has not moved since the
               version we last published: the Ghost edit is written back into the local source, so the next publish
               carries it instead of deleting it.
    conflict   live equals no committed version AND the source moved since our last publish (or we hold no record of
               what we last published): both sides changed and no rule can merge them. Alerted ONCE per slug and
               live body, under its own registered subject; a new live body alerts again.
  The record of what we last published is grocery\ghost-tool-published.json (slug -> canonical body hash). This lane
  writes it after every verified republish and save-back, and seeds it for every page it finds in `match`.
  A page with no record and a live edit is a CONFLICT, never a save-back: without the base we cannot tell a Ghost edit
  on top of our last publish from a Ghost edit on top of something older, and guessing wrong deletes local work.

  SAFETY. Dry run by default: it prints the verdict per page and writes nothing. -Apply acts. It never acts on a page
  whose working-tree source differs from HEAD (someone's uncommitted work is not this lane's to publish or overwrite):
  those are BLIND for that page. It never publishes without re-reading live afterwards and checking it now matches.
  SCOPE OF A CLEAN REPORT: the 16 tool pages in grocery\ghost-tool-manifest.json only. Recipe cards are republished
  by meal-prep\engine\publish.ps1 from the publish ledger and are out of reach here.
  Exit 0 = every page matches or was reconciled, 1 = a conflict remains (alerted), 3 = could not evaluate.
  Last line: GHOST-RECONCILE-COMPLETE.   Self-test: -SelfTest (hermetic).
#>
# The self-test is pure over literal page bodies (no git, no Ghost) and reads only its libraries:
# gate-inputs: lib\json-io.ps1, lib\guard-contract.ps1, lib\lf-write.ps1, lib\ghost-drift-lib.ps1, lib\ghost-lib.ps1
[CmdletBinding()]
param([switch]$Apply, [string]$Slug = '', [switch]$NoAlert, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $root -Parent
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')
. (Join-Path $repo 'lib\ghost-drift-lib.ps1')
. (Join-Path $repo 'lib\ghost-lib.ps1')
$API = 'https://map-to-success.ghost.io'
$ledgerPath = Join-Path $root 'ghost-tool-published.json'
$script:ConflictSubject = 'Tools: a live page and its local source both changed'

# ---- pure: the verdict ----------------------------------------------------------------------------------------
# $History: committed versions of the source OLDER than HEAD, newest first. $PublishedHash: the canonical hash this
# lane last recorded for the slug, or '' when there is no record.
function Get-TcReconcileVerdict {
  param([string]$Live, [string]$Head, [string[]]$History, [string]$PublishedHash)
  $cl = Get-CanonicalBody $Live
  if ([string]::Equals($cl, (Get-CanonicalBody $Head), [StringComparison]::Ordinal)) { return 'match' }
  foreach ($v in @($History)) {
    if ([string]::Equals($cl, (Get-CanonicalBody $v), [StringComparison]::Ordinal)) { return 'republish' }
  }
  if ($PublishedHash -and ($PublishedHash -eq (Get-BodyHash (Get-CanonicalBody $Head)))) { return 'save-back' }
  return 'conflict'
}

# ---- pure: alert once per slug and live body --------------------------------------------------------------------
function Test-TcConflictAlertDue { param($Alerted, [string]$Slug, [string]$LiveHash)
  if ($null -eq $Alerted) { return $true }
  $p = $Alerted.PSObject.Properties[$Slug]
  if ($null -eq $p) { return $true }
  return ([string]$p.Value -ne $LiveHash)
}

# The committed bytes of one file at one revision, read from git's own stream (a pipe re-joins lines with CRLF; see
# Get-CommittedToolSource in audit-ghost-drift.ps1 for the measurement).
function Get-TcGitText([string]$RepoRoot, [string]$GitArgs) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'; $psi.Arguments = ('-C "' + $RepoRoot + '" ' + $GitArgs)
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $proc = [System.Diagnostics.Process]::Start($psi)
  $out = $proc.StandardOutput.ReadToEnd(); $null = $proc.StandardError.ReadToEnd(); $proc.WaitForExit()
  if ($proc.ExitCode -ne 0) { return $null }
  return $out
}

if ($SelfTest.IsPresent) {
  $script:fl = 0; $script:n = 0
  function T($m, $c, $g) { $script:n++; if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $g); $script:fl++ } }
  $v1 = "<div>price 1</div>`n<a href=""/x/"">x</a>`n"
  $v2 = "<div>price 2</div>`n<a href=""/x/"">x</a>`n"
  $v3 = "<div>price 3</div>`n<a href=""/x/"">x</a>`n"
  $v3Live = $v3.Replace('href="/x/"', 'href="https://www.thriftycrew.com/x/"').Replace("`n", "`r`n")
  $edited = "<div>price 3 and a note Brad typed in Ghost</div>`n<a href=""/x/"">x</a>`n"
  $h3 = Get-BodyHash (Get-CanonicalBody $v3); $h2 = Get-BodyHash (Get-CanonicalBody $v2)
  $r = Get-TcReconcileVerdict -Live $v3Live -Head $v3 -History @($v2, $v1) -PublishedHash ''
  T 'CLEAN TWIN  live equal to HEAD after the URL and CRLF round trip reads match' ($r -eq 'match') $r
  $r = Get-TcReconcileVerdict -Live $v1 -Head $v3 -History @($v2, $v1) -PublishedHash $h3
  T 'MUST FIRE  live equal to an OLDER committed version is a republish (nothing live-only to lose)' ($r -eq 'republish') $r
  $r = Get-TcReconcileVerdict -Live $edited -Head $v3 -History @($v2, $v1) -PublishedHash $h3
  T 'MUST FIRE  a Ghost edit on top of the version we last published is saved back' ($r -eq 'save-back') $r
  $r = Get-TcReconcileVerdict -Live $edited -Head $v3 -History @($v2, $v1) -PublishedHash $h2
  T 'MUST FIRE  a Ghost edit while the source also moved since our last publish is a conflict' ($r -eq 'conflict') $r
  $r = Get-TcReconcileVerdict -Live $edited -Head $v3 -History @($v2, $v1) -PublishedHash ''
  T 'MUST FIRE  a Ghost edit with NO record of our last publish is a conflict, never a guessed save-back' ($r -eq 'conflict') $r
  $sp = $v3.Replace('price 3', 'price  3')
  $r = Get-TcReconcileVerdict -Live $sp -Head $v3 -History @($v2, $v1) -PublishedHash $h3
  T 'MUST FIRE  one extra space in live is an edit (save-back), never folded away as a round trip' ($r -eq 'save-back') $r
  $al = [pscustomobject]@{ 'my-crew' = 'aaaa' }
  T 'MUST FIRE  a conflict nobody was told about alerts' (Test-TcConflictAlertDue $al 'freezer-math' 'bbbb') 'false'
  T 'MUST NOT FIRE  the same slug and the same live body already alerted stays quiet' (-not (Test-TcConflictAlertDue $al 'my-crew' 'aaaa')) 'true'
  T 'CLEAN TWIN  a NEW live body on an already-alerted slug alerts again' (Test-TcConflictAlertDue $al 'my-crew' 'cccc') 'false'
  if ($script:fl -eq 0) { Write-Output ("reconcile-ghost-drift self-test PASS ($script:n cases)"); exit 0 }
  Write-Output ("reconcile-ghost-drift self-test FAIL ($script:fl of $script:n)"); exit 1
}

# ---- live --------------------------------------------------------------------------------------------------------
$key = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY } else {
  $kf = Join-Path $repo 'meal-prep\.ghostkey'
  if (Test-Path $kf) { (Get-Content $kf -Raw).Trim() } else { '' }
}
if (-not $key) { Write-Output 'reconcile: COULD NOT EVALUATE - no GHOST_ADMIN_KEY and no meal-prep\.ghostkey'; Exit-Guard -Name 'ghost-reconcile' -Summary 'blind=no-key' -Code 3 }
$manifestPath = Join-Path $root 'ghost-tool-manifest.json'
$manifest = @((Read-JsonFile $manifestPath).tools)
if (-not $manifest.Count) { Write-Output 'reconcile: COULD NOT EVALUATE - the manifest maps zero tools'; Exit-Guard -Name 'ghost-reconcile' -Summary 'blind=no-manifest' -Code 3 }
if ($Slug) { $manifest = @($manifest | Where-Object { $_.slug -eq $Slug }); if (-not $manifest.Count) { Write-Output ("reconcile: {0} is not in the manifest" -f $Slug); Exit-Guard -Name 'ghost-reconcile' -Summary 'blind=unknown-slug' -Code 3 } }
$ledger = [pscustomobject]@{ published = [pscustomobject]@{}; alerted = [pscustomobject]@{} }
if (Test-Path $ledgerPath) { $ledger = Read-JsonFile $ledgerPath }
foreach ($k in 'published', 'alerted') { if (-not $ledger.PSObject.Properties[$k]) { $ledger | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{}) } }
function Set-TcLedgerValue($Obj, [string]$Name, [string]$Value) { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
$publisher = Join-Path $repo 'site\build\publish-tool-post.ps1'

$counts = [ordered]@{ match = 0; republish = 0; 'save-back' = 0; conflict = 0; blind = 0 }
$conflicts = @(); $ledgerDirty = $false
foreach ($t in $manifest) {
  $rel = 'site/tools/' + $t.file
  $lf = Join-Path $repo ('site\tools\' + $t.file)
  $head = Get-TcGitText $repo ('show HEAD:' + $rel)
  if ($null -eq $head -or -not (Test-Path $lf)) { Write-Output ("  BLIND      {0,-28} {1} is not committed" -f $t.slug, $rel); $counts.blind++; continue }
  $work = [IO.File]::ReadAllText($lf)
  if (-not [string]::Equals((Get-CanonicalBody $work), (Get-CanonicalBody $head), [StringComparison]::Ordinal)) {
    Write-Output ("  BLIND      {0,-28} {1} has uncommitted local changes; not this lane's to publish or overwrite" -f $t.slug, $t.file); $counts.blind++; continue
  }
  $live = $null
  try { $live = Get-GhostCardBody -Api $API -Key $key -Slug $t.slug } catch { Write-Output ("  BLIND      {0,-28} {1}" -f $t.slug, $_.Exception.Message); $counts.blind++; continue }
  if ($null -eq $live) { Write-Output ("  BLIND      {0,-28} no html card on the live post" -f $t.slug); $counts.blind++; continue }
  $revs = Get-TcGitText $repo ('log --format=%H -n 200 HEAD -- ' + $rel)
  $history = @()
  foreach ($c in @(([string]$revs).Split("`n") | Where-Object { $_.Trim() } | Select-Object -Skip 1)) { $b = Get-TcGitText $repo ('show ' + $c.Trim() + ':' + $rel); if ($null -ne $b) { $history += $b } }
  $pubP = $ledger.published.PSObject.Properties[$t.slug]
  $pub = if ($pubP) { [string]$pubP.Value } else { '' }
  $verdict = Get-TcReconcileVerdict -Live $live -Head $head -History $history -PublishedHash $pub
  $counts[$verdict]++
  $headHash = Get-BodyHash (Get-CanonicalBody $head); $liveHash = Get-BodyHash (Get-CanonicalBody $live)
  switch ($verdict) {
    'match' {
      if ($pub -ne $headHash) { Set-TcLedgerValue $ledger.published $t.slug $headHash; $ledgerDirty = $true }
      Write-Output ("  match      {0}" -f $t.slug)
    }
    'republish' {
      Write-Output ("  republish  {0,-28} live equals an older committed {1} ({2} older version(s) searched)" -f $t.slug, $t.file, $history.Count)
      if ($Apply) {
        $o = & powershell -NoProfile -File $publisher -Slug $t.slug -File $lf -Force
        $again = Get-GhostCardBody -Api $API -Key $key -Slug $t.slug
        if (-not [string]::Equals((Get-CanonicalBody $again), (Get-CanonicalBody $head), [StringComparison]::Ordinal)) {
          Write-Output ("             REPUBLISH DID NOT LAND: live still differs from HEAD after the PUT. " + (@($o) -join ' ')); $counts.blind++; continue
        }
        Set-TcLedgerValue $ledger.published $t.slug $headHash; $ledgerDirty = $true
        Write-Output '             republished and re-read: live now equals HEAD'
      }
    }
    'save-back' {
      Write-Output ("  save-back  {0,-28} Ghost was edited on top of our last publish; the edit goes into {1}" -f $t.slug, $t.file)
      if ($Apply) {
        $null = Write-TcLfFile -Path $lf -Text ((Get-CanonicalBody $live).TrimEnd("`n")) -NoBom
        Set-TcLedgerValue $ledger.published $t.slug $liveHash; $ledgerDirty = $true
        Write-Output ("             written to {0}; commit it so the next publish carries the edit" -f $rel)
      }
    }
    'conflict' {
      $why = if ($pub) { 'the source moved since the version we last published' } else { 'no record of what we last published' }
      Write-Output ("  CONFLICT   {0,-28} live matches no committed version and {1}" -f $t.slug, $why)
      $conflicts += [pscustomobject]@{ slug = $t.slug; file = $t.file; why = $why; live = $liveHash }
    }
    default { throw ("unknown reconcile verdict: " + $verdict) }
  }
}

$due = @($conflicts | Where-Object { Test-TcConflictAlertDue $ledger.alerted $_.slug $_.live })
if ($Apply -and $due.Count -and -not $NoAlert) {
  . (Join-Path $root 'alert-lib.ps1')
  $body = "reconcile-ghost-drift.ps1 found tool page(s) where BOTH the live Ghost page and the local source changed, so no rule can merge them. Republishing would delete the Ghost edit; saving back would delete the local change. Merge by hand, commit the source, then republish with site\build\publish-tool-post.ps1 -Force.`n`n" +
          (($due | ForEach-Object { '  ' + $_.slug + ' (' + $_.file + '): ' + $_.why }) -join "`n") + "`n`nThis alerts once per page and live body; a further Ghost edit alerts again."
  Send-Alert -Subject $script:ConflictSubject -Body $body | Out-Null
  foreach ($c in $due) { Set-TcLedgerValue $ledger.alerted $c.slug $c.live }; $ledgerDirty = $true
}
if ($Apply -and $ledgerDirty) { $null = Write-TcLfFile -Path $ledgerPath -Text ($ledger | ConvertTo-Json -Depth 5) -NoBom }
$mode = if ($Apply) { 'applied' } else { 'dry run, nothing written' }
Write-Output ("reconcile ({0}): {1} page(s): match={2} republish={3} save-back={4} conflict={5} blind={6}" -f $mode, $manifest.Count, $counts.match, $counts.republish, $counts['save-back'], $counts.conflict, $counts.blind)
$sum = ("pages={0} match={1} republish={2} saveback={3} conflict={4} blind={5}" -f $manifest.Count, $counts.match, $counts.republish, $counts['save-back'], $counts.conflict, $counts.blind)
if ($counts.blind) { Exit-Guard -Name 'ghost-reconcile' -Summary $sum -Code 3 }
Exit-Guard -Name 'ghost-reconcile' -Summary $sum -Code $(if ($counts.conflict) { 1 } else { 0 })
