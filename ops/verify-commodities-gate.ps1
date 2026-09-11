<#
  verify-commodities-gate.ps1 - a matching-rule change may not be committed unless the soundness
  baseline was accepted against THOSE rules.

  WHY THIS EXISTS (Brad's ruling 8, 2026-09-07; the case is 2026-09-06).
  Commit b28788fa changed six commodities' matching rules at 05:45 and was committed with neither
  `audit-match-soundness -Accept` nor `guards.ps1` run against the result. The board stopped three
  hours later and three of that day's nine alerts were its footprint. Nothing was broken about the
  tools; the habit simply did not fire at 05:45, which is when habits do not fire.

  WHY A HOOK RATHER THAN A NOTE. A rule change is the single highest-blast-radius edit in this
  estate - commodities.json decides what every product on the board IS - and it is also the edit
  most likely to be made in one line while thinking about something else. The estate already learned
  this shape once: ops/verify-bulk-edit.ps1 existed, was correct, and was flagged DEAD because
  nothing called it, so it became a pre-commit hook. Same repair lane, same reason.

  WHAT IT ASKS, precisely: does grocery\out\audit\match-baseline.json record the rules_hash that the
  STAGED rule files produce? Get-IdentityRulesHash is the same hash the identity table and guard 13
  key on, so a single number answers "were these rules reviewed" for all three at once.

  IT HASHES THE STAGED BYTES, NOT THE WORKING TREE. A partial `git add -p` of commodities.json
  commits something the working tree does not contain, and hashing the file on disk would bless a
  set of rules that is not the set being committed. The staged blobs are materialised into a temp
  grocery root and hashed there.

  WHAT IT DOES NOT DO. It does not run the audit, and it does not run guards. Both take minutes and a
  pre-commit hook that takes minutes gets uninstalled. It checks that somebody already did.

  Usage:
    ops\verify-commodities-gate.ps1              check the staged set (what the pre-commit hook runs)
    ops\verify-commodities-gate.ps1 -SelfTest    frozen fixtures
  Exit: 0 = no rule file staged, or the baseline matches. 1 = staged rules were never reviewed.
        3 = could not evaluate (no git, no repo).
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# The files Get-IdentityRulesHash reads. Named here so the two lists cannot drift apart silently:
# a rule input that this gate does not watch is a rule change that commits unreviewed.
$script:CG_RULE_FILES = @('grocery/commodities.json', 'grocery/recipe-commodities.json',
                          'grocery/category-excludes.json', 'grocery/product-classes.json',
                          'grocery/compare-deals.ps1', 'grocery/global-exclude-lib.ps1')

function Test-StagedTouchesRules {
  <# Pure over a list of staged paths, so the fixture drives the live rule.
     compare-deals.ps1 is in the list because Match-Category lives there, and global-exclude-lib.ps1
     because the term list does - an edit to either changes every assignment exactly as a
     commodities.json edit does. The list used to be block text inside the engine and was hashed from
     there; it moved on 2026-09-09 (backlog I82), and the gate REFUSED rather than waving the commit
     through, because the hash it could no longer compute came back empty. #>
  param([string[]]$Staged)
  $hit = @()
  foreach ($s in @($Staged)) {
    $n = ($s -replace '\\', '/').ToLower()
    if ($script:CG_RULE_FILES -contains $n) { $hit += $n }
  }
  return , $hit
}

function Test-BaselineCoversRules {
  <# The whole verdict, as one pure function over two values so the fixtures are exact.
     A baseline with NO rules_hash is not evidence of anything: it predates this gate, so it cannot
     say which rules it reviewed. Refusing there is the fail-closed direction, and it costs one
     -Accept run once. #>
  param([string]$StagedHash, [string]$BaselineHash)
  if (-not $StagedHash) { return $false }
  if (-not $BaselineHash) { return $false }
  return ($StagedHash -eq $BaselineHash)
}

function Save-GitBlob {
  # RAW BYTES, never the text pipeline. `& git show` comes back through PowerShell as decoded lines:
  # the BOM is eaten, the trailing newline is invented, and the file that lands is not the file that
  # was staged. commodities.json carries a BOM, so the first cut hashed a different artifact and the
  # gate refused a commit whose baseline was in fact correct - a false block, which is how a gate
  # earns --no-verify. Get-IdentityRulesHash folds CRLF pairs but nothing else, so bytes matter.
  param([string]$Repo, [string]$Spec, [string]$Dst)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = ('-C "' + $Repo + '" cat-file blob ' + $Spec)
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi)
  $fs = [IO.File]::Open($Dst, 'Create', 'Write')
  try { $p.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Dispose() }
  [void]$p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return ($p.ExitCode -eq 0)
}

if ($SelfTest) {
  # The byte-fidelity case below builds a temp repo, so the repository environment goes first - HERE and never on
  # the live path, which runs under pre-commit and judges the staged set through GIT_INDEX_FILE (lib\git-repo-env.ps1).
  . (Join-Path $repo 'lib\git-repo-env.ps1'); Clear-TcGitRepoEnv
  $script:bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  # ---- which staged sets are in scope -------------------------------------------------------------
  $s = Test-StagedTouchesRules @('grocery/commodities.json', 'grocery/guards.ps1')
  T 'MUST FIRE  a staged commodities.json is in scope (the b28788fa shape)' (@($s).Count -eq 1) ([string]@($s).Count)
  $s = Test-StagedTouchesRules @('grocery/compare-deals.ps1')
  T 'MUST FIRE  compare-deals.ps1 is in scope - Match-Category lives in its source' (@($s).Count -eq 1) ([string]@($s).Count)
  $s = Test-StagedTouchesRules @('grocery/global-exclude-lib.ps1')
  T 'MUST FIRE  global-exclude-lib.ps1 is in scope - the term list moved there and a rule change must still be gated' (@($s).Count -eq 1) ([string]@($s).Count)
  $s = Test-StagedTouchesRules @('grocery\commodities.json')
  T 'MUST FIRE  a Windows-separator path is the same file (git reports forward slashes, humans type back)' (@($s).Count -eq 1) ([string]@($s).Count)
  $s = Test-StagedTouchesRules @('grocery/known-wrong.json', 'ops/run-gates.ps1', 'public/board.json')
  T 'MUST NOT FIRE  a commit that touches no rule input is not gated (known-wrong is a per-cell corrector, not a rule)' (@($s).Count -eq 0) ([string]@($s).Count)
  $s = Test-StagedTouchesRules @()
  T 'MUST NOT FIRE  an empty staged set is not a rule change' (@($s).Count -eq 0) ([string]@($s).Count)
  # PS 5.1: @($null).Count is 1, so an empty result must not score 1 ([[ps-null-count-is-one]]).
  T 'an empty in-scope list counts 0, not the PS 5.1 @($null) 1' ((@((Test-StagedTouchesRules @()))).Count -eq 0) ([string](@((Test-StagedTouchesRules @()))).Count)
  # ---- the verdict --------------------------------------------------------------------------------
  T 'MUST NOT FIRE  a baseline accepted against exactly these rules passes' (Test-BaselineCoversRules 'abc123' 'abc123') 'refused'
  T 'MUST FIRE  a baseline accepted against DIFFERENT rules is refused (this is b28788fa)' (-not (Test-BaselineCoversRules 'abc123' 'def456')) 'allowed'
  T 'MUST FIRE  a baseline with NO rules_hash cannot say what it reviewed, so it is refused' (-not (Test-BaselineCoversRules 'abc123' '')) 'allowed'
  T 'MUST FIRE  an unhashable staged set is refused rather than waved through' (-not (Test-BaselineCoversRules '' 'abc123')) 'allowed'
  # CLEAN TWIN: the two rules compose the way the live path uses them - out of scope means the hash is
  # never consulted at all, so a stale baseline cannot block an unrelated commit.
  $s = Test-StagedTouchesRules @('meal-prep/db/costed.json')
  T 'CLEAN TWIN  an unrelated commit is untouched by a stale baseline, because scope is decided first' `
    ((@($s).Count -eq 0)) 'an unrelated commit entered the hash comparison'
  # ---- BYTE FIDELITY OF THE STAGED COPY (the false block this gate shipped with, 2026-09-07) --------
  # The hash is over BYTES. The first cut materialised the staged blob through `& git show`, which
  # comes back as decoded LINES: the BOM was eaten and a trailing newline invented, so the gate hashed
  # an artifact nobody had staged and refused a commit whose baseline was in fact correct. A gate that
  # false-blocks is a gate somebody routes around with --no-verify, so this is the case that matters.
  $g = Join-Path $env:TEMP ('cgfx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [void](New-Item -ItemType Directory -Path $g -Force)
  try {
    & git -C $g init -q -b main . 2>&1 | Out-Null
    & git -C $g config user.email t@t 2>&1 | Out-Null
    & git -C $g config user.name T 2>&1 | Out-Null
    $src = Join-Path $g 'withbom.json'
    [IO.File]::WriteAllBytes($src, ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{"a":1}')))
    & git -C $g add withbom.json 2>&1 | Out-Null
    $dst = Join-Path $g 'copy.json'
    $okSave = Save-GitBlob -Repo $g -Spec ':withbom.json' -Dst $dst
    $orig = [IO.File]::ReadAllBytes($src)
    $copy = if (Test-Path $dst) { [IO.File]::ReadAllBytes($dst) } else { @() }
    $same = ($okSave -and $orig.Length -eq $copy.Length -and (Compare-Object $orig $copy -SyncWindow 0).Count -eq 0)
    T 'MUST FIRE  the staged copy is BYTE-identical, BOM included (through the text pipeline it was not, and the gate false-blocked)' `
      $same ("orig=$($orig.Length)B copy=$($copy.Length)B")
    $missing = Save-GitBlob -Repo $g -Spec ':nosuchfile.json' -Dst (Join-Path $g 'x.json')
    T 'CLEAN TWIN  a file that is not staged reports failure rather than writing an empty one that hashes as real' `
      (-not $missing) 'reported success on a missing blob'
  } finally { Remove-Item -LiteralPath $g -Recurse -Force -ErrorAction SilentlyContinue }

  if ($bad -eq 0) { Write-Output 'COMMODITIES-GATE SELF-TEST PASS'; Write-GuardComplete -Name 'commodities-gate' -Summary 'selftest ok'; exit 0 }
  Write-Output ("COMMODITIES-GATE SELF-TEST FAILED ($bad)"); Write-GuardComplete -Name 'commodities-gate' -Summary "selftest failed=$bad"; exit 2
}

# ---- live path -------------------------------------------------------------------------------------
$staged = @()
try { $staged = @(& git -C $repo diff --cached --name-only --diff-filter=ACM 2>$null) } catch { }
$inScope = Test-StagedTouchesRules $staged
if (@($inScope).Count -eq 0) {
  Write-Output 'commodities-gate: no matching-rule input is staged - not applicable to this commit'
  Exit-Guard -Name 'commodities-gate' -Summary 'not-applicable' -Code 0
}
Write-Output ("commodities-gate: {0} matching-rule input(s) staged: {1}" -f @($inScope).Count, (@($inScope) -join ', '))

# Materialise the STAGED bytes into a temp grocery root and hash THOSE.
$tmp = Join-Path $env:TEMP ('cgate-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$tmpG = Join-Path $tmp 'grocery'
[void](New-Item -ItemType Directory -Path $tmpG -Force)
$stagedHash = ''
try {
  foreach ($rel in $script:CG_RULE_FILES) {
    $leaf = Split-Path $rel -Leaf
    $dst = Join-Path $tmpG $leaf
    if (-not (Save-GitBlob -Repo $repo -Spec (':' + $rel) -Dst $dst)) {
      # not in the index at all: fall back to HEAD, and if that is missing too the file genuinely
      # does not exist (product-classes.json does not yet) - Get-IdentityRulesHash skips absent files.
      if (-not (Save-GitBlob -Repo $repo -Spec ('HEAD:' + $rel) -Dst $dst)) {
        Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
        continue
      }
    }
  }
  . (Join-Path $repo 'grocery\identity-lib.ps1')
  try { $stagedHash = Get-IdentityRulesHash -GroceryRoot $tmpG } catch { $stagedHash = '' }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$baseHash = ''
$baseF = Join-Path $repo 'grocery\out\audit\match-baseline.json'
if (Test-Path -LiteralPath $baseF) {
  try { $baseHash = [string]((Get-Content $baseF -Raw | ConvertFrom-Json).rules_hash) } catch { $baseHash = '' }
}
$sh = if ($stagedHash) { $stagedHash.Substring(0, [Math]::Min(12, $stagedHash.Length)) } else { '(unhashable)' }
$bh = if ($baseHash) { $baseHash.Substring(0, [Math]::Min(12, $baseHash.Length)) } else { '(none recorded)' }
Write-Output ("  staged rules_hash   : $sh")
Write-Output ("  baseline rules_hash : $bh")

if (Test-BaselineCoversRules $stagedHash $baseHash) {
  Write-Output '  ok - the soundness baseline was accepted against exactly these rules'
  Exit-Guard -Name 'commodities-gate' -Summary "staged=$sh baseline=$bh ok" -Code 0
}
Write-Output ''
Write-Output 'commodities-gate: BLOCKED. These matching rules have not been reviewed.'
Write-Output '  A rule change decides what every product on the board IS, and on 2026-09-06 one committed'
Write-Output '  unreviewed at 05:45 stopped the board by 08:14. Run, in this order, then re-stage:'
Write-Output '    powershell -File grocery\audit-match-soundness.ps1            (read MOVED and DROPPED)'
Write-Output '    powershell -File grocery\audit-match-soundness.ps1 -Accept    (only once you agree with them)'
Write-Output '    powershell -File grocery\guards.ps1                           (must exit 0)'
Write-Output '    git add grocery\out\audit\match-baseline.json'
Exit-Guard -Name 'commodities-gate' -Summary "staged=$sh baseline=$bh BLOCKED" -Code 1
