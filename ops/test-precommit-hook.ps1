<#
  test-precommit-hook.ps1 - the pre-commit hook actually REFUSES the commits it was written to refuse.

  WHY (2026-09-06, PLAN-top5-2026-09-06 area 3). The hook is the only thing standing in the path of BOTH a
  careless human and an automated one, and until now nothing proved it fires. Two arms, two failure modes:

    verify-bulk-edit        the SHAPE of the staged set (BOM, line endings, a clean parse, resolvable
                            calls). Written 2026-09-05 after a 608-site sweep introduced six defects.
    verify-bot-commit-scope the SCOPE of a commit that identifies itself as the pipeline. Written
                            2026-09-06 after push-data.ps1's `git add -A` put 325 files on main, 192 of
                            them .ps1 mid-edit, and held them there for 59 minutes.

  A HOOK THAT DOES NOT REFUSE IS A COMMENT. It runs in `sh`, it depends on exit codes crossing two process
  boundaries and on `git var` resolving an identity that a `-c user.name` handed down through the
  environment - none of which can be read off the source. So this drives the INSTALLED-SHAPE hook against
  throwaway repos in %TEMP% and reads git's own verdict: did the commit exist afterwards, or not.

  Run:  powershell -NoProfile -File ops\test-precommit-hook.ps1
  Exit: 0 pass, 1 a case failed, 3 BLIND (the hook or a checker is missing - nothing was proven).
#>
param([switch]$SelfTest)   # accepted so ops\run-gates.ps1 discovers this file; the cases run either way
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$hookSrc = Join-Path $PSScriptRoot 'hooks\pre-commit'
# THE CHECKERS THE HOOK SHELLS OUT TO, copied in so the fixture repo is self-contained. A fixture that
# reached back into the real tree for them would pass on a tree where the hook could never find them.
$needed = @('ops\hooks\pre-commit', 'ops\verify-bulk-edit.ps1', 'ops\verify-bot-commit-scope.ps1',
            'lib\bot-paths.ps1', 'lib\guard-contract.ps1')
foreach ($f in $needed) {
  if (-not (Test-Path -LiteralPath (Join-Path $repo $f))) {
    Write-Output ("BLIND: " + $f + " is missing - the hook cannot be proven"); exit 3
  }
}

$n = 0; $bad = 0
function T([string]$m, [bool]$c, [string]$g) {
  $script:n++
  if ($c) { Write-Output "  ok    $m" } else { $script:bad++; Write-Output "  FAIL  $m -> $g" }
}

$made = New-Object System.Collections.ArrayList
function New-HookRepo {
  $w = Join-Path $env:TEMP ('hook-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [void]$made.Add($w)
  New-Item -ItemType Directory -Force $w | Out-Null
  & git -C $w init -q -b main .
  & git -C $w config user.email t@t
  & git -C $w config user.name  Session
  & git -C $w config commit.gpgsign false
  foreach ($d in @('ops\hooks', 'lib', 'grocery\out\regular', 'design')) {
    New-Item -ItemType Directory -Force (Join-Path $w $d) | Out-Null
  }
  foreach ($f in $needed) { Copy-Item (Join-Path $repo $f) (Join-Path $w $f) -Force }
  'seed' | Set-Content (Join-Path $w 'grocery\out\regular\day1.json')
  & git -C $w add -A | Out-Null
  & git -C $w -c core.hooksPath=nonexistent commit -q -m seed | Out-Null
  # Install the hook the way ops\install-hooks.ps1 does: LF endings, no BOM. git runs it through sh, and
  # a CRLF shebang fails with a bare "not found" that names nothing useful.
  $hook = Join-Path $w '.git\hooks\pre-commit'
  New-Item -ItemType Directory -Force (Split-Path $hook -Parent) | Out-Null
  [IO.File]::WriteAllText($hook, ([IO.File]::ReadAllText($hookSrc) -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
  return $w
}

function Try-Commit {
  <# Returns whether the commit LANDED, read from git rather than from an exit code we could misread. #>
  param([string]$Work, [switch]$AsBot, [string]$Message = 'fixture commit')
  $before = (@(& git -C $Work rev-parse HEAD) -join '').Trim()
  $out = if ($AsBot) {
    & git -C $Work -c user.name=smp-pipeline-bot -c user.email=bot@x commit -m $Message 2>&1
  } else {
    & git -C $Work commit -m $Message 2>&1
  }
  $after = (@(& git -C $Work rev-parse HEAD) -join '').Trim()
  return [pscustomobject]@{ Landed = ($after -ne $before); Text = ((@($out) | ForEach-Object { [string]$_ }) -join "`n") }
}

try {
  # ---- MUST FIRE: the pipeline identity staging a source file ----------------------------------------
  $w = New-HookRepo
  'x' | Set-Content (Join-Path $w 'grocery\out\regular\day2.json')
  'notes' | Set-Content (Join-Path $w 'design\PLAN-x.md')
  & git -C $w add -A -- 'grocery/out/regular/day2.json' 'design/PLAN-x.md' | Out-Null
  $c = Try-Commit -Work $w -AsBot
  T 'MUST FIRE  a bot-authored commit staging an unowned path is REFUSED' (-not $c.Landed) 'the commit landed'
  T 'MUST FIRE  and the refusal NAMES the offending path' ($c.Text -match 'design/PLAN-x\.md') $c.Text

  # ---- CLEAN TWIN 1: the same staged set, committed by a person --------------------------------------
  # A person committing a design doc is ordinary work. If the scope arm fired here it would be uninstalled
  # within a day, which is the real failure mode of a gate that is right too often.
  $w2 = New-HookRepo
  'x' | Set-Content (Join-Path $w2 'grocery\out\regular\day2.json')
  'notes' | Set-Content (Join-Path $w2 'design\PLAN-x.md')
  & git -C $w2 add -A -- 'grocery/out/regular/day2.json' 'design/PLAN-x.md' | Out-Null
  $c2 = Try-Commit -Work $w2
  T 'CLEAN TWIN the identical staged set from a SESSION author is allowed through' $c2.Landed $c2.Text

  # ---- CLEAN TWIN 2: the bot staging only what it owns ------------------------------------------------
  $w3 = New-HookRepo
  'x' | Set-Content (Join-Path $w3 'grocery\out\regular\day2.json')
  & git -C $w3 add -A -- 'grocery/out/regular/day2.json' | Out-Null
  $c3 = Try-Commit -Work $w3 -AsBot
  T 'CLEAN TWIN the bot staging only pipeline-owned paths commits normally' $c3.Landed $c3.Text

  # ---- THE OTHER ARM IS STILL LIVE: a broken .ps1 is refused whoever commits it ----------------------
  # If this stopped firing, the hook would look installed and be half a hook.
  $w4 = New-HookRepo
  "function f {`r`n  'unclosed" | Set-Content (Join-Path $w4 'ops\broken.ps1')
  & git -C $w4 add -A -- 'ops/broken.ps1' | Out-Null
  $c4 = Try-Commit -Work $w4
  T 'MUST FIRE  a .ps1 that does not parse is still refused by the shape arm (a session author)' `
    (-not $c4.Landed) 'the commit landed'

  # ---- A MISSING CHECKER MUST NOT READ AS A PASS -----------------------------------------------------
  $w5 = New-HookRepo
  Remove-Item (Join-Path $w5 'ops\verify-bot-commit-scope.ps1') -Force
  'x' | Set-Content (Join-Path $w5 'grocery\out\regular\day2.json')
  & git -C $w5 add -A -- 'grocery/out/regular/day2.json' | Out-Null
  $c5 = Try-Commit -Work $w5
  T 'MUST FIRE  a MISSING scope checker refuses the commit rather than reading as clean' `
    ((-not $c5.Landed) -and ($c5.Text -match 'verify-bot-commit-scope')) $c5.Text

  # ---- --no-verify IS STILL THE LOUD BYPASS ----------------------------------------------------------
  # It is deliberate, and audit-hook-installed asserts the hook is present so skipping it is a choice.
  $w6 = New-HookRepo
  'x' | Set-Content (Join-Path $w6 'grocery\out\regular\day2.json')
  'notes' | Set-Content (Join-Path $w6 'design\PLAN-x.md')
  & git -C $w6 add -A | Out-Null
  $b6 = (@(& git -C $w6 rev-parse HEAD) -join '').Trim()
  & git -C $w6 -c user.name=smp-pipeline-bot -c user.email=bot@x commit --no-verify -q -m bypass 2>&1 | Out-Null
  $a6 = (@(& git -C $w6 rev-parse HEAD) -join '').Trim()
  T 'CLEAN TWIN --no-verify is still the stated bypass (a gate with no escape hatch gets uninstalled)' `
    ($a6 -ne $b6) 'the bypass did not work'

  Write-Output ''
  Write-Output ("SELFTEST: {0}/{1} pass" -f ($n - $bad), $n)
  Write-Output ("PRECOMMIT-HOOK-COMPLETE cases={0} failed={1}" -f $n, $bad)
  if ($bad) { exit 1 }
  exit 0
} finally {
  foreach ($d in $made) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
