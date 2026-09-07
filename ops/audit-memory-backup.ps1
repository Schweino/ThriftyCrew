<#
  audit-memory-backup.ps1 - the agent memory store is DATA THIS ESTATE REASONS FROM. Version it, prove the
  history is current, and prove it never reaches the public repo.

  WHY (2026-09-03). Two things happened on the same day.

  FIRST, a memory file was destroyed by an ordinary edit. Repairing three mojibake characters, a string
  replacement went through the shell mis-encoded and performed a GLOBAL single-character substitution
  instead: every 'r' became a different character in budget-tracker.md, and every 'M' became 'e' in
  grocery-browser-exfil.md. 2,035 characters damaged by a 3-character repair. Both writes reported success,
  neither changed the file SIZE, and nothing versioned the directory - so recovery meant reconstructing the
  content out of session transcripts and proving the restore by replaying the damage onto it. With a history
  that is a checkout.

  SECOND, the obvious fix was nearly the wrong one. ops\prompt-backup mirrors the agent prompts INTO this
  repo, so mirroring memory the same way looks like the answer. It is not: this repo is PUBLIC (verified by
  an unauthenticated GitHub API call returning private=False), and the memory store carries the business's
  cost and revenue notes, account identifiers and contact addresses. So memory gets its OWN git history,
  local, with NO REMOTE, and this guard exists as much to keep it out of the public repo as to keep it
  backed up. Those are the same job: "memory and git must not drift" cuts both ways.

  Six checks:
    1. HISTORY EXISTS   - the memory directory is a git repository at all
    2. NO REMOTE        - it has no push target, so it cannot leak to a public host
    3. NOT IN THIS REPO - no memory file is tracked by ThriftyCrew
    4. HISTORY CURRENT  - no uncommitted memory changes (-Sync commits them)
    5. INDEX INTEGRITY  - MEMORY.md and the files on disk agree: no links to files that are gone, no
                          duplicate links, and every memo REACHABLE - named by MEMORY.md, or linked as
                          [[slug]] by a memo MEMORY.md names. Reachability, not flat listing: hub routing
                          is the store's documented convention (2026-09-05, queue 2026-09-05-e42efd)
    6. ENCODING INTACT  - no mojibake, the founding damage of this guard
  Exit 0 clean, 2 a real finding, 3 BLIND (nothing to check - a pass that proves nothing).
  -Sync commits pending memory changes, then re-checks. -SelfTest runs frozen fixtures.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$Sync, [switch]$SelfTest, [string]$MemoryDir = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$REPO = 'C:\Codex\ThriftyCrew'
if (-not $MemoryDir) { $MemoryDir = 'C:\Users\Owner\.claude\projects\C--Codex\memory' }

# Mojibake is UTF-8 bytes decoded as Windows-1252. Built from CODEPOINTS, never typed: a literal non-ASCII
# needle is re-encoded on its way through the shell, which is the exact mechanism that caused the damage
# this guard was written about.
$MOJI = @(
  ([string][char]0x00E2 + [char]0x20AC + [char]0x2122),   # mangled right single quote
  ([string][char]0x00E2 + [char]0x20AC + [char]0x201C),   # mangled left double quote
  ([string][char]0x00C3 + [char]0x00A9),                  # mangled e-acute
  ([string][char]0x00C3 + [char]0x00B1)                   # mangled n-tilde
)

function Get-AllowedRemote {
  <# Is this exact remote URL on the reviewed list?  EXACT, after trimming a trailing slash and
     lowercasing: near-matching a URL is how a lookalike host gets waved through, and there are at
     most a handful of these ever. #>
  param([string]$Url, [string]$AllowFile = '')
  if (-not $AllowFile) { $AllowFile = Join-Path $PSScriptRoot 'memory-remote-allowlist.json' }
  if (-not (Test-Path -LiteralPath $AllowFile)) { return $null }
  $doc = $null
  try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($AllowFile)) } catch { return $null }
  $want = ($Url -replace '/+$', '').ToLower()
  foreach ($e in @($doc.remotes)) {
    if ((([string]$e.url) -replace '/+$', '').ToLower() -eq $want) { return $e }
  }
  return $null
}

function Test-RemoteIsPrivate {
  <# Ask the host, anonymously, whether it will serve this repository to a stranger.

     Returns State = private | public | unverified, and Detail saying how it knows. A git HTTP host
     answers an unauthenticated info/refs with 200 when the repository is public and 401 (GitHub) or
     404 when it is not. Anything else - DNS failure, a timeout, a proxy - is UNVERIFIED, because the
     one answer this must never invent is "safe".

     NO CREDENTIALS ARE SENT, deliberately. A probe carrying the operator's token would get 200 for a
     private repository and report it public, which is the failure mode that would make everyone stop
     believing this check. #>
  param([string]$Url, [int]$TimeoutSec = 15)
  $probe = ($Url -replace '/+$', '') + '/info/refs?service=git-upload-pack'
  try {
    $req = [Net.HttpWebRequest]::Create($probe)
    $req.Method = 'GET'
    $req.Timeout = $TimeoutSec * 1000
    $req.UserAgent = 'thriftycrew-audit-memory-backup'
    $req.Credentials = $null
    $req.PreAuthenticate = $false
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    if ($code -eq 200) { return @{ State = 'public'; Detail = "anonymous GET $probe returned HTTP 200" } }
    return @{ State = 'unverified'; Detail = "anonymous GET $probe returned HTTP $code, which this check does not recognise" }
  } catch [Net.WebException] {
    $we = $_.Exception
    if ($we.Response) {
      $code = [int]([Net.HttpWebResponse]$we.Response).StatusCode
      if ($code -eq 401 -or $code -eq 403 -or $code -eq 404) {
        return @{ State = 'private'; Detail = "anonymous GET returned HTTP $code" }
      }
      return @{ State = 'unverified'; Detail = "anonymous GET returned HTTP $code" }
    }
    return @{ State = 'unverified'; Detail = ('the probe could not reach the host: ' + $we.Message) }
  } catch {
    return @{ State = 'unverified'; Detail = ('the probe threw: ' + $_.Exception.Message) }
  }
}

function Get-GitOut([string]$Dir, [string]$GitArgs) {
  # Read the process stream, never `| Out-String`: PowerShell rejoins native output with CRLF, which on
  # 2026-09-03 added 393 bytes to a 28,965-byte file and silently disabled a comparison in another guard.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = ('-C "' + $Dir + '" ' + $GitArgs)
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  return [pscustomobject]@{ Text = $out; Code = $p.ExitCode }
}

function Test-MemoryStore {
  param([string]$Dir)
  $issues = New-Object System.Collections.Generic.List[string]
  # SEPARATE FROM $issues ON PURPOSE. A remote whose visibility could not be PROVEN is not a finding -
  # nothing is known to be wrong - but it is emphatically not clean either. Folding it into $issues
  # would page as a leak on a flaky network; folding it into silence would let an unprovable backup
  # read as verified. It gets its own bucket and its own exit code.
  $blind  = New-Object System.Collections.Generic.List[string]
  $notes  = New-Object System.Collections.Generic.List[string]
  $checked = 0

  if (-not (Test-Path $Dir)) { return @{ rc = 3; issues = @("the memory directory does not exist: $Dir"); checked = 0; blind = @(); notes = @() } }
  $files = @(Get-ChildItem $Dir -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'MEMORY.md' })
  $indexPath = Join-Path $Dir 'MEMORY.md'
  if (-not (Test-Path $indexPath)) { return @{ rc = 3; issues = @('no MEMORY.md - there is no index to check the store against'); checked = 0; blind = @(); notes = @() } }
  if ($files.Count -eq 0) { return @{ rc = 3; issues = @('zero memory files - a clean result here would prove nothing'); checked = 0; blind = @(); notes = @() } }

  # 1. HISTORY EXISTS
  $checked++
  if (-not (Test-Path (Join-Path $Dir '.git'))) {
    $issues.Add('the memory store is NOT a git repository - one bad write is unrecoverable, which is the failure this guard exists for')
    return @{ rc = 2; issues = $issues; blind = $blind; notes = $notes; checked = $checked }
  }

  # 2. NO REMOTE THAT IS NOT A REVIEWED, STILL-PRIVATE ONE (Brad's ruling 2, 2026-09-07).
  #
  # This check was absolute: any remote at all was a violation. That was the right first cut and the
  # wrong permanent rule. The store is ONE DIRECTORY ON ONE MACHINE, and the incident this whole guard
  # was written about is a single bad write destroying 2,035 characters with no history to recover
  # from. Forbidding the offsite copy trades a measured, recurring durability risk for an exposure
  # risk that can actually be measured - so measure it.
  #
  # THE RULE IS STRICTLY STRONGER, NOT WEAKER, AND IN THREE PLACES:
  #   * an UNLISTED remote fails exactly as before. Being private is not enough; somebody has to have
  #     written it down and said why.
  #   * a LISTED remote is RE-PROVEN private on every run, by fetching its info/refs with no
  #     credentials. The old rule could not have noticed a repository being flipped to public, because
  #     it never looked at one. This does.
  #   * a remote that cannot be probed is UNVERIFIED and returns BLIND, never clean. A could-not-look
  #     must not settle the question, and this is the direction that loses the data.
  $checked++
  $rem = Get-GitOut $Dir 'remote -v'
  $remLines = @(($rem.Text) -split "\r?\n" | Where-Object { $_.Trim() })
  $seenUrls = @{}
  foreach ($rl in $remLines) {
    $parts = $rl -split "\s+"
    if ($parts.Count -ge 2) { $seenUrls[$parts[1]] = $true }
  }
  foreach ($u in @($seenUrls.Keys)) {
    $entry = Get-AllowedRemote -Url $u
    if (-not $entry) {
      $issues.Add('the memory store has an UNREVIEWED git REMOTE configured, so it can be pushed off this machine: ' + $u + ' - memory carries cost, revenue and account notes. Remove it, or add it to ops\memory-remote-allowlist.json with evidence that it is private.')
      continue
    }
    $vis = Test-RemoteIsPrivate -Url $u
    if ($vis.State -eq 'public') {
      $issues.Add('the memory store pushes to ' + $u + ', which is REVIEWED but is answering anonymously (' + $vis.Detail + '). It is PUBLIC. Memory carries cost, revenue and account notes - remove the remote or make the repository private now.')
    } elseif ($vis.State -eq 'unverified') {
      $blind.Add('the memory store pushes to the reviewed remote ' + $u + ' and its visibility COULD NOT BE PROVEN this run (' + $vis.Detail + '). That is not a pass: nothing here has shown the backup is still private.')
    } else {
      $notes.Add('remote ' + $u + ' is reviewed and still private (' + $vis.Detail + ')')
    }
  }

  # 3. NOT TRACKED BY THE PUBLIC REPO
  $checked++
  if (Test-Path (Join-Path $REPO '.git')) {
    $tracked = Get-GitOut $REPO 'ls-files'
    $leak = @(($tracked.Text -split "`r?`n") | Where-Object { $_ -match 'projects/C--Codex/memory/' })
    if ($leak.Count) { $issues.Add(("$($leak.Count) memory file(s) are TRACKED BY THE PUBLIC ThriftyCrew REPO, e.g. " + ($leak[0]))) }
  }

  # 4. HISTORY CURRENT
  $checked++
  $st = Get-GitOut $Dir 'status --porcelain'
  $dirty = @(($st.Text -split "`r?`n") | Where-Object { $_.Trim() })
  if ($dirty.Count) {
    $issues.Add("$($dirty.Count) memory file(s) are uncommitted, so the history does not hold what the store currently says - run with -Sync")
  }

  # 5. INDEX INTEGRITY
  $checked++
  $idx = [IO.File]::ReadAllText($indexPath, [Text.Encoding]::UTF8) -split "`r?`n"
  $linked = @()
  foreach ($l in $idx) { $m = [regex]::Match($l, '\]\(([^)]+\.md)\)'); if ($m.Success) { $linked += $m.Groups[1].Value } }
  $names = @($files | ForEach-Object { $_.Name })
  $orphans   = @($linked | Where-Object { $names -notcontains $_ })
  $dupes     = @($linked | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

  # ---- THE CENSUS MEASURES REACHABILITY, NOT DIRECT LISTING (2026-09-05, queue 2026-09-05-e42efd) ------
  # This arm used to ask "does MEMORY.md hold a line for this file", and report every file that did not.
  # On 2026-09-05 it reported 64 files "recall will never surface" and ALL SIXTY-FOUR were wrong: every one
  # of them is one [[wikilink]] hop from a memo MEMORY.md does index. True orphans: 0.
  # The store deliberately stopped honouring the flat-listing contract when HUB memos were introduced, and
  # MEMORY.md's own opening lines say so: "Hub memos carry a Routed from the index section listing sibling
  # memos that no longer hold their own line here. Every memo is still its own file; follow the hub to reach
  # it." The check was never taught the new convention, so it measured listing and called it reachability.
  # The perverse part, and the reason this had to be fixed rather than muted: it got LOUDER the more
  # correctly the store was consolidated. Every memo routed into a hub added one to its count, so keeping
  # the store tidy guaranteed the alert fired forever. A guard that punishes the maintenance it exists to
  # protect gets ignored, and then it is not a guard.
  # ONE HOP ONLY, deliberately. A memo reachable only from a memo that is itself unindexed is still
  # reported, and that is correct: two hops is not recall, it is a chain nobody follows.
  # The counts are reported SEPARATELY (direct / via a hub) so a hub that stops routing its children is
  # still visible - the number that would move is the hub count, and a reader can see it move.
  $hubbed = @{}
  foreach ($l in (@($linked | Sort-Object -Unique))) {
    $p = Join-Path $Dir $l
    if (-not (Test-Path $p)) { continue }
    $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    # [[slug]], [[slug.md]] and [[slug|label]] all name the same memo. The alias and anchor forms are
    # stripped rather than ignored, or a hub that labels its links would read as routing nothing.
    foreach ($m in [regex]::Matches($t, '\[\[([^\]\|#]+?)(?:[|#][^\]]*)?\]\]')) {
      $s = $m.Groups[1].Value.Trim()
      if (-not $s) { continue }
      if ($s -notmatch '(?i)\.md$') { $s = $s + '.md' }
      $hubbed[$s] = $true
    }
  }
  $directCount = @($names | Where-Object { $linked -contains $_ }).Count
  $hubCount    = @($names | Where-Object { ($linked -notcontains $_) -and $hubbed.ContainsKey($_) }).Count
  $unreachable = @($names | Where-Object { ($linked -notcontains $_) -and (-not $hubbed.ContainsKey($_)) })

  if ($orphans.Count)     { $issues.Add("MEMORY.md links $($orphans.Count) file(s) that do not exist: " + (($orphans | Select-Object -First 5) -join ', ')) }
  if ($unreachable.Count) { $issues.Add("$($unreachable.Count) memory file(s) are in no index line and are linked from no indexed memo either, so recall will never surface them: " + (($unreachable | Select-Object -First 5) -join ', ')) }
  if ($dupes.Count)       { $issues.Add("MEMORY.md links the same file more than once: " + (($dupes | Select-Object -First 5) -join ', ')) }

  # 6. ENCODING INTACT - the founding damage
  $checked++
  $bad = New-Object System.Collections.Generic.List[string]
  foreach ($f in @($files + @(Get-Item $indexPath))) {
    $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    foreach ($seq in $MOJI) { if ($t.Contains($seq)) { $bad.Add($f.Name); break } }
  }
  if ($bad.Count) { $issues.Add("$($bad.Count) memory file(s) carry mojibake (UTF-8 read as ANSI): " + (($bad | Select-Object -First 5) -join ', ')) }

  # ORDER MATTERS: a real finding outranks an unproven one. 2 = something is wrong, 3 = something
  # could not be shown to be right, 0 = everything was checked and holds.
  $rc = if ($issues.Count) { 2 } elseif ($blind.Count) { 3 } else { 0 }
  return @{ rc = $rc; issues = $issues; blind = $blind; notes = $notes; checked = $checked; files = $files.Count
            direct = $directCount; hub = $hubCount; unreachable = $unreachable.Count }
}

# ------------------------------------------------------------------ self-test
if ($SelfTest) {
  $fail = 0
  # Counted, not typed: a hand-maintained case tally is one more copy of a fact, and it is always the copy
  # nobody re-derives that goes stale.
  $cases = 0
  function T([string]$label, [bool]$cond, [string]$detail) {
    $script:cases++
    if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label  - $detail"; $script:fail++ } }

  $fx = Join-Path $env:TEMP ('memaudit-selftest-' + $PID)
  function NewStore {
    if (Test-Path $fx) { Remove-Item $fx -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $fx | Out-Null
    Set-Content (Join-Path $fx 'alpha.md') "---`nname: alpha`n---`nbody" -Encoding UTF8
    Set-Content (Join-Path $fx 'beta.md')  "---`nname: beta`n---`nbody" -Encoding UTF8
    Set-Content (Join-Path $fx 'MEMORY.md') "- [Alpha](alpha.md) - a`n- [Beta](beta.md) - b" -Encoding UTF8
    $null = Get-GitOut $fx 'init'
    $null = Get-GitOut $fx 'config user.name t'
    $null = Get-GitOut $fx 'config user.email t@t'
    $null = Get-GitOut $fx 'add -A'
    $null = Get-GitOut $fx 'commit -m base'
  }

  # CLEAN TWIN: a healthy store passes. Without this the must-fires prove only that it says no to everything.
  NewStore
  $r = Test-MemoryStore $fx
  T 'CLEAN TWIN a committed, fully indexed, well-encoded store passes' ($r.rc -eq 0) ("rc=$($r.rc) " + ($r.issues -join '; '))

  # MUST-FIRE 1: no history at all - the founding condition, an unrecoverable store
  NewStore; Remove-Item (Join-Path $fx '.git') -Recurse -Force
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE a store with no git history is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'NOT a git repository')) ("rc=$($r.rc)")

  # MUST-FIRE 2: an UNREVIEWED REMOTE - the leak path this guard exists to block. Unchanged by the
  # 2026-09-07 ruling: being private is not sufficient, somebody has to have written it down.
  NewStore; $null = Get-GitOut $fx 'remote add origin https://github.com/someone/public.git'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE an unreviewed remote is reported as a leak path' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'UNREVIEWED git REMOTE')) ("rc=$($r.rc)")

  # ---- THE REVIEWED-REMOTE PATH (Brad's ruling 2, 2026-09-07) --------------------------------------
  # These drive the two pure helpers directly. The visibility probe is NETWORK, and a fixture that
  # depends on the network is a fixture that fails on a train - so the probe's DECISION is fixtured
  # here against frozen inputs, and the live path is what actually calls it.
  $allowFx = Join-Path $env:TEMP ('memallow-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
  try {
    '{ "remotes": [ { "url": "https://github.com/Schweino/codex-memory.git", "approved_by": "Brad" } ] }' |
      Set-Content -LiteralPath $allowFx -Encoding UTF8
    $e1 = Get-AllowedRemote -Url 'https://github.com/Schweino/codex-memory.git' -AllowFile $allowFx
    T 'CLEAN TWIN a reviewed URL is found on the allowlist' ($null -ne $e1) 'not found'
    $e2 = Get-AllowedRemote -Url 'https://github.com/Schweino/codex-memory.git/' -AllowFile $allowFx
    T 'CLEAN TWIN a trailing slash is the same remote' ($null -ne $e2) 'not found'
    $e3 = Get-AllowedRemote -Url 'https://github.com/someone-else/codex-memory.git' -AllowFile $allowFx
    T 'MUST-FIRE a LOOKALIKE URL under a different owner is NOT on the allowlist' ($null -eq $e3) 'a lookalike was accepted'
    $e4 = Get-AllowedRemote -Url 'https://github.com/Schweino/codex-memory.git' -AllowFile (Join-Path $env:TEMP 'no-such-allowlist-file.json')
    T 'MUST-FIRE a MISSING allowlist allows nothing (it must not read as permission)' ($null -eq $e4) 'a missing file granted permission'
  } finally { Remove-Item -LiteralPath $allowFx -Force -ErrorAction SilentlyContinue }

  # The probe's own decision table, exercised through a real HTTP call to hosts that cannot change
  # meaning under us. This is the assertion the whole ruling rests on: the check can TELL public from
  # private, so a 401 is a measurement rather than a probe that always says no.
  $pubProbe = Test-RemoteIsPrivate -Url 'https://github.com/Schweino/ThriftyCrew.git'
  $privProbe = Test-RemoteIsPrivate -Url 'https://github.com/Schweino/codex-memory.git'
  if ($pubProbe.State -eq 'unverified' -and $privProbe.State -eq 'unverified') {
    # No network. Say so - a skipped case must never read as a passed one.
    T 'NETWORK  the visibility probe could not run at all, so it proved nothing this run (not a pass)' $true ''
    Write-Output '  (both probes returned unverified - offline. The live path treats that as BLIND, never clean.)'
  } else {
    T 'MUST-FIRE  a PUBLIC repository is detected as public (the control - without this a 401 proves nothing)' `
      ($pubProbe.State -eq 'public') ("got " + $pubProbe.State + ': ' + $pubProbe.Detail)
    T 'CLEAN TWIN a PRIVATE repository is detected as private' `
      ($privProbe.State -eq 'private') ("got " + $privProbe.State + ': ' + $privProbe.Detail)
  }
  $bad = Test-RemoteIsPrivate -Url 'https://no-such-host-thriftycrew-probe.invalid/x.git' -TimeoutSec 5
  T 'MUST-FIRE an unreachable host is UNVERIFIED, never private - a could-not-look must not settle it' `
    ($bad.State -eq 'unverified') ("got " + $bad.State)

  # MUST-FIRE 3: uncommitted change - the history no longer holds what the store says
  NewStore; Add-Content (Join-Path $fx 'alpha.md') 'edited after the commit'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE an uncommitted memory edit is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'uncommitted')) ("rc=$($r.rc)")

  # MUST-FIRE 4: an unindexed file - present on disk, invisible to recall
  NewStore; Set-Content (Join-Path $fx 'gamma.md') 'x' -Encoding UTF8; $null = Get-GitOut $fx 'add -A'; $null = Get-GitOut $fx 'commit -m g'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE a file in no index line is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'no index line')) ("rc=$($r.rc)")

  # MUST-FIRE 5: an orphan index line - a link to a file that is gone
  NewStore; Remove-Item (Join-Path $fx 'beta.md'); $null = Get-GitOut $fx 'add -A'; $null = Get-GitOut $fx 'commit -m rm'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE an index line pointing at a missing file is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'do not exist')) ("rc=$($r.rc)")

  # MUST-FIRE 6: MOJIBAKE - the damage that caused this guard to be written
  NewStore
  $moji = 'Member' + [string][char]0x00E2 + [char]0x20AC + [char]0x2122 + 's Mark'
  [IO.File]::WriteAllText((Join-Path $fx 'alpha.md'), $moji, (New-Object System.Text.UTF8Encoding($false)))
  $null = Get-GitOut $fx 'add -A'; $null = Get-GitOut $fx 'commit -m moji'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE mojibake in a memory file is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'mojibake')) ("rc=$($r.rc)")

  # ---- HUB ROUTING (2026-09-05, queue 2026-09-05-e42efd) ----------------------------------------------
  # FOUNDING BUG, frozen: the census asked whether MEMORY.md held a LINE for each file and called the answer
  # reachability. On 2026-09-05 it named 64 files "recall will never surface" and every one of them was one
  # [[wikilink]] hop from an indexed memo - the store's own documented hub convention. True orphans: 0.
  # This fixture is that shape at minimum size: an indexed hub, a child the hub routes, and a memo nothing
  # points at. The CLEAN TWIN is the same store with the lonely memo deleted - today's code reports 1 there,
  # which is exactly the false positive, so that twin is the case that could not have passed before.
  function NewHubStore([bool]$WithLonely) {
    if (Test-Path $fx) { Remove-Item $fx -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $fx | Out-Null
    Set-Content (Join-Path $fx 'MEMORY.md') "Hub memos route siblings that no longer hold their own line here.`n`n- [Hub](hub.md) - the family index" -Encoding UTF8
    Set-Content (Join-Path $fx 'hub.md') "Routed from the index:`n`n- [[child]] - the routed sibling" -Encoding UTF8
    Set-Content (Join-Path $fx 'child.md') 'holds no line in MEMORY.md; reached through its hub' -Encoding UTF8
    if ($WithLonely) { Set-Content (Join-Path $fx 'lonely.md') 'nothing points at this one' -Encoding UTF8 }
    $null = Get-GitOut $fx 'init'
    $null = Get-GitOut $fx 'config user.name t'
    $null = Get-GitOut $fx 'config user.email t@t'
    $null = Get-GitOut $fx 'add -A'
    $null = Get-GitOut $fx 'commit -m hub'
  }

  NewHubStore $true
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE a memo that neither MEMORY.md nor any indexed memo links is reported, BY NAME' `
    (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'lonely\.md') -and ([int]$r.unreachable -eq 1)) `
    ("rc=$($r.rc) unreachable=$($r.unreachable) " + ($r.issues -join '; '))
  T '  ...and the hub-routed child is NOT reported - it is counted as reached in one hop' `
    ((($r.issues -join ' ') -notmatch 'child\.md') -and ([int]$r.hub -eq 1) -and ([int]$r.direct -eq 1)) `
    ("direct=$($r.direct) hub=$($r.hub) " + ($r.issues -join '; '))

  NewHubStore $false
  $r = Test-MemoryStore $fx
  T 'CLEAN TWIN a store whose only unindexed memo is hub-routed reports ZERO findings (today it reports 1)' `
    (($r.rc -eq 0) -and ([int]$r.unreachable -eq 0)) ("rc=$($r.rc) " + ($r.issues -join '; '))

  # BLIND: an empty store must never read as clean
  if (Test-Path $fx) { Remove-Item $fx -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $fx | Out-Null
  Set-Content (Join-Path $fx 'MEMORY.md') '' -Encoding UTF8
  $r = Test-MemoryStore $fx
  T 'BLIND a store with zero memory files reports rc 3, never a clean pass' ($r.rc -eq 3) ("rc=$($r.rc)")

  if (Test-Path $fx) { Remove-Item $fx -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output "SELF-TEST PASS ($cases memory-store cases)"
  exit 0
}

# ------------------------------------------------------------------ live
if ($Sync) {
  if (Test-Path (Join-Path $MemoryDir '.git')) {
    $st = Get-GitOut $MemoryDir 'status --porcelain'
    if ((($st.Text) -split "`r?`n" | Where-Object { $_.Trim() }).Count) {
      $null = Get-GitOut $MemoryDir 'add -A'
      $msg = 'Memory sync ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
      $c = Get-GitOut $MemoryDir ('commit -m "' + $msg + '"')
      Write-Output ('memory-backup: committed pending memory changes (' + $msg + ')')
    } else { Write-Output 'memory-backup: nothing to commit' }
  } else { Write-Output 'memory-backup: -Sync cannot commit - the store is not a git repository yet' }
}

$res = Test-MemoryStore $MemoryDir
Write-Output ("memory-backup: {0} memory file(s), {1} check(s) run against {2}" -f [int]$res.files, [int]$res.checked, $MemoryDir)
# THE TWO ROUTES ARE PRINTED SEPARATELY, CLEAN OR NOT (2026-09-05). Hub routing is the store's convention,
# so "reached via a hub" is a normal, healthy number - but it is also the number that would fall if a hub
# stopped routing its children, and a count nobody prints is a change nobody sees.
if ($null -ne $res.direct) {
  Write-Output ("  index: {0} memo(s) named directly in MEMORY.md, {1} reached in one hop from a hub memo it names, {2} reachable by neither" -f [int]$res.direct, [int]$res.hub, [int]$res.unreachable)
}
foreach ($nte in @($res.notes)) { Write-Output ('  ok - ' + $nte) }
if ($res.rc -eq 3) {
  foreach ($i in $res.issues) { Write-Output ('  BLIND  ' + $i) }
  foreach ($i in @($res.blind)) { Write-Output ('  BLIND  ' + $i) }
  Write-GuardComplete -Name 'memory-backup' -Summary 'blind'
  exit 3
}
if ($res.issues.Count -eq 0) {
  Write-Output '  ok - the memory store is versioned locally, has no remote this run could not account for, is absent from the public repo, is fully committed, its index agrees with the files on disk, and nothing is mojibaked'
  Write-GuardComplete -Name 'memory-backup' -Summary ("files={0} clean" -f [int]$res.files)
  exit 0
}
foreach ($i in $res.issues) { Write-Output ('  ' + $i) }
Write-Output '  Fix: run this with -Sync to commit pending memory changes. An UNREVIEWED remote, or a memory file tracked by ThriftyCrew, must be removed by hand - that repo is PUBLIC. A remote that is a deliberate private backup goes in ops\memory-remote-allowlist.json with its evidence, and is re-proven private on every run.'
Write-GuardComplete -Name 'memory-backup' -Summary ("files={0} issues={1}" -f [int]$res.files, $res.issues.Count)
exit 2
