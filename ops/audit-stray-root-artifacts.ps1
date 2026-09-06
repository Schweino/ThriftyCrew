<#
  audit-stray-root-artifacts.ps1 - the repo root is a curated place, so anything new in it is either a
  decision someone defends in a diff or it is debris from a path-construction bug.

  WHY THIS EXISTS (2026-09-06, backlog I2). Two artifacts were found sitting at the repo root:

    "3 cups sliced, for topping"          7,094,631 bytes of scaler TSV. An ingredient BASE AMOUNT used
                                          as a redirect target - a variable that held a measurement
                                          string ended up where a filename belonged.
    "CodexThriftyCrewgroceryoutcaptures_sink"
                                          an empty directory. C:\Codex\ThriftyCrew\grocery\out\captures_sink
                                          with every separator eaten - a path joined by concatenation.

  Two independent writers, two different bugs, the same landing place. And NEITHER WAS VISIBLE TO
  ANYTHING. .gitignore line 3 is `/*`, so the root is ignored by default and allow-listed back one entry
  at a time; debris there is invisible to git status, to every audit, and to the gate. Both sat for days.

  WRITING THIS AS A NAME MATCHER WOULD HAVE BEEN THE WRONG SHAPE, and the tree proved it during the same
  hour. A detector for "measurement-shaped" and "collapsed-path-shaped" names was the obvious build, and
  while checking the allowlist against the real root a THIRD stray turned up that neither pattern
  describes: a directory called `R` holding qa\s1.json, s2.json, s3.json (2026-08-25). Probably a `-R`
  flag or an $R variable that reached a path. A name matcher would have shipped green over it.

  So the rule is structural instead: AN ENTRY AT THE REPO ROOT IS EXPECTED IF IT IS TRACKED, OR IT IS A
  DIRECTORY THAT CONTAINS TRACKED FILES, OR IT IS NAMED IN $ALLOW BELOW. Everything else is a finding.
  That catches debris of a shape nobody has thought of yet, which is the only kind that matters - the two
  shapes we have already seen are the two we would have written a matcher for.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number - see backlog E2 and the note in the five writing agents.

  BOTH HALVES ARE IN run-gates, and that was not the original plan. The first draft registered only the
  -SelfTest, on the reasoning that the live root held four pre-existing strays and gating on them would
  put run-gates permanently red. grocery\audit-guard-contract.ps1 rejected that immediately and it was
  right: "DEAD: audit-stray-root-artifacts.ps1 is a detector that NOTHING in production calls". A
  detector that only ever runs against its own fixtures is not a gate, it is a decoration - so the four
  strays were dealt with (quarantined, see ops\quarantine-log\2026-09-06-stray-root.md) and the live run
  registered. If this file ever needs excluding again, the honest move is to clean the root, not to
  unregister the check.

  Self-test: powershell -File ops\audit-stray-root-artifacts.ps1 -SelfTest
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# EVERY LINE HERE IS A DECISION SOMEONE DEFENDS IN A DIFF, same standard as run-gates' $SKIP. An entry
# that carries no tracked file and is not listed here is a finding, so adding a line is how you say
# "this is meant to be there" - never how you make the gate quiet about something you have not looked at.
$ALLOW = @{
  '.git'         = 'git itself'
  '.wrangler'    = 'Cloudflare Wrangler local state. Generated, gitignored on purpose, and rebuilt on demand.'
  'site-backups' = 'pre-publish snapshots of the live site. Deliberately untracked - they are the undo copy, and committing them would double the repo for no gain.'
}

function Get-StrayRootEntry {
  <# Pure, so the self-test can drive it with a synthetic root and a frozen allowlist rather than
     resting its verdict on whatever happens to be on disk today.
     $Entries : the top-level names present at the root.
     $Tracked : the top-level names git knows about - a tracked root FILE, or the first path segment of
                any tracked file, which is how a directory earns its place.
     $Allow   : the allowlist keys. #>
  param(
    [string[]]$Entries,
    [string[]]$Tracked,
    [string[]]$Allow
  )
  $known = @{}
  foreach ($t in @($Tracked)) { if ($t) { $known[$t] = $true } }
  foreach ($a in @($Allow))   { if ($a) { $known[$a] = $true } }
  $stray = @()
  foreach ($e in @($Entries)) {
    if (-not $e) { continue }
    if ($known.ContainsKey($e)) { continue }
    $stray += $e
  }
  # `,` NOT `@()`. `return @($stray)` does NOT survive: PowerShell unrolls the array on the way out of the
  # function, so a SINGLE finding arrives at the caller as a bare string - and then `.Count` is 1 (the
  # PSObject adapter), `[0]` is its first CHARACTER, and an assertion like `$r[0] -eq 'R'` passes for the
  # wrong reason because 'R'[0] really is 'R'. Written the wrong way first and caught by the arity case
  # below, which is the only reason it is not still in here. The comma operator wraps the array so the
  # unroll hands the array itself back. Sibling of [[ps-null-count-is-one]] and [[ps-json-array-collapse]].
  return ,@($stray)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) {
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }

  # A FROZEN root. Not the live one: a self-test that reads today's disk passes for reasons that have
  # nothing to do with the detector working ([[green-fixture-is-not-production-coverage]] from the other
  # side, and ops\audit-fixture-inputs.ps1 gates exactly this).
  $fxTracked = @('CLAUDE.md', 'README.md', '.gitignore', 'grocery', 'meal-prep', 'ops', 'design', '.claude')
  $fxAllow   = @('.git', '.wrangler', 'site-backups')

  # MUST FIRE 1 - the measurement-shaped filename, frozen verbatim as it was found.
  $r1 = Get-StrayRootEntry -Entries @('CLAUDE.md', 'grocery', '3 cups sliced, for topping') -Tracked $fxTracked -Allow $fxAllow
  T 'MUST FIRE  a measurement string used as a filename is a finding' `
    ($r1.Count -eq 1 -and $r1[0] -eq '3 cups sliced, for topping') ("[" + ($r1 -join ', ') + "]")

  # MUST FIRE 2 - the collapsed path, frozen verbatim.
  $r2 = Get-StrayRootEntry -Entries @('ops', 'CodexThriftyCrewgroceryoutcaptures_sink') -Tracked $fxTracked -Allow $fxAllow
  T 'MUST FIRE  a path with its separators eaten is a finding' `
    ($r2.Count -eq 1 -and $r2[0] -eq 'CodexThriftyCrewgroceryoutcaptures_sink') ("[" + ($r2 -join ', ') + "]")

  # MUST FIRE 3 - THE CASE A NAME MATCHER MISSES, and the reason this detector is structural. `R` is
  # neither measurement-shaped nor path-shaped. If this ever stops firing, someone has narrowed the rule
  # back to matching names and the founding argument in the header has been lost.
  $r3 = Get-StrayRootEntry -Entries @('grocery', 'R') -Tracked $fxTracked -Allow $fxAllow
  T 'MUST FIRE  a stray of NO recognisable shape is still a finding' `
    ($r3.Count -eq 1 -and $r3[0] -eq 'R') ("[" + ($r3 -join ', ') + "]")

  # CLEAN TWINS - the fix must be scoped to the founding bug and must not start flagging the real root.
  $r4 = Get-StrayRootEntry -Entries $fxTracked -Tracked $fxTracked -Allow $fxAllow
  T 'CLEAN TWIN every tracked root entry passes' ($r4.Count -eq 0) ("[" + ($r4 -join ', ') + "]")

  $r5 = Get-StrayRootEntry -Entries @('.git', '.wrangler', 'site-backups') -Tracked $fxTracked -Allow $fxAllow
  T 'CLEAN TWIN every allow-listed entry passes' ($r5.Count -eq 0) ("[" + ($r5 -join ', ') + "]")

  # A digit-leading name that is NOT debris. The name matcher this detector replaced would have had to
  # special-case it; the structural rule never sees it, because it is tracked.
  $r6 = Get-StrayRootEntry -Entries @('2026-09-06-notes.md') -Tracked @('2026-09-06-notes.md') -Allow $fxAllow
  T 'CLEAN TWIN a tracked digit-leading filename is not debris' ($r6.Count -eq 0) ("[" + ($r6 -join ', ') + "]")

  # ARITY, AND IT IS A MUST-FIRE IN ITS OWN RIGHT. The first version of this file returned `@($stray)`,
  # which unrolls, so one finding came back as a bare string. Asserting only on .Count would still have
  # passed (a string's .Count is 1). The type assertion is the one that fails, so it is the one that
  # matters - do not weaken this back to a count check.
  $r7 = Get-StrayRootEntry -Entries @('ops', 'R') -Tracked $fxTracked -Allow $fxAllow
  T 'MUST FIRE  a single finding comes back as an ARRAY, not unrolled to a string' `
    ($r7 -is [array]) ($r7.GetType().FullName)
  T 'a single finding counts as 1, not as the length of its name' ($r7.Count -eq 1) ("Count=" + $r7.Count)

  # EMPTY - nothing at the root at all is a broken enumeration, and the live path below treats it as
  # could-not-evaluate rather than clean. Here we only assert the pure function does not invent a finding.
  $r8 = Get-StrayRootEntry -Entries @() -Tracked $fxTracked -Allow $fxAllow
  T 'an empty enumeration yields no findings' ($r8.Count -eq 0) ("Count=" + $r8.Count)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 4 must-fire cases (3 stray shapes plus the return-arity trap), 3 clean twins, count and empty-enumeration checks'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
$entries = @(Get-ChildItem -LiteralPath $repo -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
if (-not $entries.Count) {
  Write-Output 'STRAY-ROOT AUDIT BLIND: enumerated zero entries at the repo root, which means this enumeration is broken rather than the root being empty. Nothing was checked, so nothing was proven.'
  Write-GuardComplete -Name 'stray-root' -Summary 'blind=no-entries'
  exit 3
}

# NO 2>&1 on a native exe: merging git's stderr under EAP=Stop turns its first stderr line into a
# terminating throw in THIS script, which has bitten three other guards in this estate.
$lsOut = & git -C $repo ls-files
$rc = $LASTEXITCODE
if ($rc -ne 0) {
  Write-Output ("STRAY-ROOT AUDIT BLIND: git ls-files exited {0}, so the set of tracked entries is unknown and every root entry would look stray. Unknown is not a finding and it is not a pass." -f $rc)
  Write-GuardComplete -Name 'stray-root' -Summary ("blind=git-rc-$rc")
  exit 3
}
$lsFiles = @($lsOut | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -ne '' })
if (-not $lsFiles.Count) {
  Write-Output 'STRAY-ROOT AUDIT BLIND: git reported zero tracked files. In a repo with thousands that is a broken read, not a clean tree.'
  Write-GuardComplete -Name 'stray-root' -Summary 'blind=no-tracked-files'
  exit 3
}
# A tracked root file contributes its own name; a tracked file deeper in contributes its first segment,
# which is how a directory earns its place without being listed by hand.
$tracked = @($lsFiles | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)

$stray = Get-StrayRootEntry -Entries $entries -Tracked $tracked -Allow @($ALLOW.Keys)

if ($stray.Count) {
  Write-Output ("STRAY-ROOT AUDIT FAILED: {0} entr(ies) at the repo root are neither tracked, nor a directory holding tracked files, nor allow-listed:" -f $stray.Count)
  foreach ($s in $stray) {
    $p = Join-Path $repo $s
    $what = 'file'
    $size = ''
    try {
      $i = Get-Item -LiteralPath $p -Force -ErrorAction Stop
      if ($i.PSIsContainer) {
        $what = 'directory'
        $n = @(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue).Count
        $size = "$n file(s) inside"
      } else {
        $size = ("{0:N0} bytes" -f $i.Length)
      }
    } catch { $size = 'unreadable' }
    Write-Output ("  STRAY  {0,-45} {1}, {2}" -f $s, $what, $size)
  }
  Write-Output '  Find the WRITER before deleting any of these - the artifact is the only evidence of the bug that made it.'
  Write-Output '  If an entry belongs at the root, add it to $ALLOW in this file with the reason, which is a line someone defends in a diff.'
  Write-GuardComplete -Name 'stray-root' -Summary ("stray={0}" -f $stray.Count)
  exit 2
}

Write-Output ("stray-root: PASSED - all {0} root entr(ies) are tracked, hold tracked files, or are allow-listed." -f $entries.Count)
Write-GuardComplete -Name 'stray-root' -Summary ("entries={0} stray=0" -f $entries.Count)
exit 0
