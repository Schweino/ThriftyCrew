<#
  audit-phantom-paths.ps1 - a script path named in standing guidance must exist in the tree.

  WS 10d of design\PLAN-brain-v2-2026-09-09.md.

  THE FOUNDING CASE. ops\audit-hook-installed.ps1 was cited in FIVE places - CLAUDE.md, both git hooks,
  ops\install-hooks.ps1 and ops\test-precommit-hook.ps1 - as the guard asserting that the change-time
  gate is live. It had never existed. Nothing caught it, because ops\audit-memory-citations.ps1 resolves
  `[[memory]]` citations and nothing resolved SCRIPT citations. A citation to a missing artefact reads as
  authority: the reader believes the check is running and proceeds with more confidence than if nothing
  had been cited. That audit's own founding argument, applied to the other kind of reference.

  WHAT COUNTS. A literal path to a .ps1 or .py under ops\, grocery\, lib\, graph\, meal-prep\ or sidecar\,
  in either slash direction, found in the documents a session treats as standing guidance: CLAUDE.md,
  .claude\rules\*.md, .claude\agents\*.md, ops\hooks\*, docs\*.md and design\RULINGS-*.md. A path inside
  a fenced code block counts too - a command you are told to run is the strongest citation there is.

  WHAT DOES NOT. design\PLAN-*, EVAL-* and MEASURE-* documents are records of a moment and legitimately
  name files that were planned, retired or renamed later; holding history to today's tree is a detector
  that is red forever. Retired names that standing guidance deliberately mentions go in $ALLOW with a
  reason.

  SCOPE OF A CLEAN REPORT: UNSOUND. It finds literal paths it can parse. A path assembled with Join-Path,
  named without a directory, or written as prose ("the hook installer") is invisible. A reported phantom
  is real; a clean report proves only that no parseable citation dangles.

  EXIT CODES (lib\guard-contract.ps1): 0 clean, 2 a phantom path, 3 could not evaluate.
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# Retired or intentionally-absent names that standing guidance mentions on purpose. EVERY entry carries
# its reason; an allowlist without one is indistinguishable from a bug somebody hid.
$script:ALLOW = @{
  'grocery\local-llm-lib.ps1' =
    'docs\RUNTIME-MAP.md names it only to record that it was DELETED - "the old PowerShell client grocery/local-llm-lib.ps1 was deleted the same day: it had no callers and Python is the only client." A deletion record must name what was deleted; found by this audit''s first live run on 2026-09-10 and ruled history rather than a phantom.'
}

$script:PATH_RE = '(?<![\w\\/.-])((?:ops|grocery|lib|graph|meal-prep|sidecar)[\\/][\w./\\-]*?[\w-]+\.(?:ps1|py))(?![\w])'

function Get-CitedPaths {
  <# [@{ Path; Line }] for every literal script path in one document. Pure. #>
  param([string]$Text)
  $out = @()
  if (-not $Text) { return ,$out }
  $lines = $Text -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    foreach ($m in [regex]::Matches($lines[$i], $script:PATH_RE)) {
      $p = $m.Groups[1].Value -replace '/', '\'
      $out += @{ Path = $p; Line = $i + 1 }
    }
  }
  return ,$out
}

function Get-GuidanceFiles {
  param([string]$Root)
  $files = @()
  foreach ($p in @('CLAUDE.md')) { $f = Join-Path $Root $p; if (Test-Path -LiteralPath $f) { $files += $f } }
  foreach ($g in @('.claude\rules\*.md', '.claude\agents\*.md', 'docs\*.md', 'design\RULINGS-*.md')) {
    $files += @(Get-ChildItem -Path (Join-Path $Root $g) -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  }
  $files += @(Get-ChildItem -Path (Join-Path $Root 'ops\hooks') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  return ,$files
}

if ($SelfTest) {
  $fails = @(); $ran = @()
  function Case {
    param([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:ran += $Name
    if (-not $Ok) { $script:fails += "$Label $Name" }
    '  {0,-14} {1,-58} {2}' -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" })
  }
  # MUST FIRE: the founding citation, in both slash directions and in backticks.
  $fixture = 'asserted live by `ops/audit-' + 'hook-installed.ps1`. It runs once.'
  $c1 = Get-CitedPaths -Text $fixture
  Case 'MUST FIRE' 'a backticked forward-slash script path is captured' `
    ((@($c1).Count -eq 1) -and ($c1[0].Path -eq ('ops\audit-' + 'hook-installed.ps1'))) (($c1 | ForEach-Object { $_.Path }) -join ',')
  $c2Raw = Get-CitedPaths -Text ('# ops\audit-' + 'hook-installed.ps1 asserts this file is live')
  Case 'MUST FIRE' 'a backslash path in a hook comment is captured' (@($c2Raw).Count -eq 1)
  # THE SPLIT NEEDLE ON THE NEXT TWO LINES COST A GATE, and it is marked rather than rewritten. The
  # path is concatenated so THIS audit cannot match its own source; that same split hides the `.py`
  # ending from ops\audit-cross-module-reach.ps1, which exempts an entry-point path only when it can see
  # the extension, so the fixture read as two NEW reaches into graph's internals and blocked a push on
  # 2026-09-10. Neither line opens anything.
  $c3Raw = Get-CitedPaths -Text ('run `python graph/learning/stage2_' + 'review.py --emit-packet`')   # reach-fixture-ok: a quoted citation string for the phantom scanner, split so it cannot match itself
  Case 'MUST FIRE' 'a python path in a command is captured' ((@($c3Raw).Count -eq 1) -and ($c3Raw[0].Path -eq ('graph\learning\stage2_' + 'review.py')))   # reach-fixture-ok: the expected value of the fixture above, not a read
  # MUST NOT FIRE: things that look like paths and are not script citations.
  $c4Raw = Get-CitedPaths -Text 'see grocery/out/comparison-2026-09-08.json and meal-prep/db/recipes.json'   # reach-fixture-ok: a quoted MUST-NOT-FIRE string proving data files are not script citations; nothing here opens either path
  Case 'MUST NOT FIRE' 'a data file is not a script citation' (@($c4Raw).Count -eq 0)
  $c5Raw = Get-CitedPaths -Text 'the gate lives at C:\Codex\ThriftyCrew\opsx\thing.ps1 and xops\y.ps1'
  Case 'MUST NOT FIRE' 'a directory that merely ENDS in ops is not ops\' (@($c5Raw).Count -eq 0) (($c5Raw | ForEach-Object { $_.Path }) -join ',')
  # CLEAN TWIN: line numbers are 1-based, so a finding can be opened directly.
  $c6Raw = Get-CitedPaths -Text ("line one`nline two names lib\guard-" + 'contract.ps1')
  Case 'CLEAN TWIN' 'the reported line is 1-based' ((@($c6Raw).Count -eq 1) -and ($c6Raw[0].Line -eq 2))
  # CLEAN TWIN: the guidance set resolves to real files, so a clean run examined something.
  $gRaw = Get-GuidanceFiles -Root $repo
  Case 'CLEAN TWIN' 'the guidance set resolves to at least CLAUDE.md and the rules files' (@($gRaw).Count -ge 5) ("n=" + @($gRaw).Count)
  ''
  if ($fails.Count) {
    "audit-phantom-paths selftest: $($fails.Count) FAILED of $($ran.Count)"
    $fails | ForEach-Object { "  $_" }
    Exit-Guard -Name 'PHANTOM-PATHS-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count)"
  }
  "audit-phantom-paths selftest: $($ran.Count) of $($ran.Count) cases pass"
  Exit-Guard -Name 'PHANTOM-PATHS-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

Invoke-Guard -Name 'PHANTOM-PATHS' -Body {
  $filesRaw = Get-GuidanceFiles -Root $repo
  $files = @($filesRaw)
  if ($files.Count -lt 5) {
    "phantom-paths: COULD NOT EVALUATE - the guidance set resolved to only $($files.Count) file(s)."
    Exit-Guard -Name 'PHANTOM-PATHS' -Code 3 -Summary "blind=guidance-set n=$($files.Count)"
  }
  $cited = 0; $phantoms = @(); $allowed = 0
  foreach ($f in $files) {
    $rel = $f.Substring($repo.Length).TrimStart('\')
    $pathsRaw = Get-CitedPaths -Text ([IO.File]::ReadAllText($f))
    foreach ($c in @($pathsRaw)) {
      $cited++
      if (Test-Path -LiteralPath (Join-Path $repo $c.Path)) { continue }
      if ($script:ALLOW.ContainsKey($c.Path)) { $allowed++; continue }
      $phantoms += ("{0}:{1} names {2}, which is not in the tree" -f $rel, $c.Line, $c.Path)
    }
  }
  "phantom-paths: examined $cited script citation(s) across $($files.Count) guidance file(s); $allowed allowlisted."
  foreach ($p in $phantoms) { "  PHANTOM  $p" }
  ''
  'SCOPE OF A CLEAN REPORT: UNSOUND. A path built with Join-Path or named without its directory is invisible.'
  if ($phantoms.Count) {
    Exit-Guard -Name 'PHANTOM-PATHS' -Code 2 -Summary "cited=$cited phantoms=$($phantoms.Count)"
  }
  Exit-Guard -Name 'PHANTOM-PATHS' -Code 0 -Summary "cited=$cited phantoms=0"
}
