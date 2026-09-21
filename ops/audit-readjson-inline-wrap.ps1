<#
  audit-readjson-inline-wrap.ps1 - no script wraps a Read-JsonFile call inline as @(Read-JsonFile ...).

  WHY (2026-09-21). lib\json-io.ps1's Read-JsonFile returns ,$x on purpose, so an assigned result keeps its
  array-ness. Wrapped INLINE, `@(Read-JsonFile x)` is a one-element array whose only element is the whole file,
  so `foreach ($r in @(Read-JsonFile x))` runs ONCE over every row at once. .claude\rules\ops-and-gates.md has
  forbidden the inline wrap in prose since 2026-09-06 ("Never wrap a function call inline as @(Get-Thing ...)"),
  and it recurred anyway, silently, in three places found on 2026-09-21:
    meal-prep\pipeline\sync-recipesdb-cost.ps1   the partial-cost gate's costed map, empty on every run: each
                                                 run printed "costed COULD NOT READ" and refused nothing
    meal-prep\pipeline\wave-preaudit.ps1 (x2)    the costed and ingredient maps collapsed to one key
  A rule that recurs despite a memory needs a gate. This holds the shape at ZERO.

  THE DELIBERATE EXCEPTION: a line carrying `# readjson-wrap:allow <reason>` (grocery\test-auditors.ps1 probes
  the trap on purpose). A marker with no reason exempts nothing. This file is excluded from its own scan.
  NOT COVERED, stated: the same trap through any OTHER comma-returning function; only Read-JsonFile is named.

  Exit 0 clean, 1 findings. Last line READJSON-INLINE-WRAP-COMPLETE. Self-test: -SelfTest.
#>
param([switch]$SelfTest, [string]$Root = '')
$ErrorActionPreference = 'Stop'
$repo = if ($Root) { $Root } else { Split-Path -Parent $PSScriptRoot }

function Find-RjwSites { param([string]$Text)
  $out = @(); $n = 0; $inBlock = $false
  foreach ($line in ($Text -split "`n")) {
    $n++
    # a <# ... #> block comment is prose about the trap, not a call
    if ($inBlock) { if ($line -match '#>') { $inBlock = $false }; continue }
    if ($line -match '^\s*<#' -and $line -notmatch '#>') { $inBlock = $true; continue }
    if ($line -notmatch ('@\(\s*' + 'Read-JsonFile\b')) { continue }
    if ($line -match '#[^\n]*readjson-wrap:allow\s+\S') { continue }
    if ($line.TrimStart().StartsWith('#')) { continue }
    $out += $n
  }
  return ,$out
}

if ($SelfTest) {
  $f = 0; $c = 0
  function T($m, $ok, $g) { $script:c++; if ($ok) { "ok    $m" } else { "FAIL  $m   got: $g"; $script:f++ } }
  $fn = 'Read-' + 'JsonFile'
  $r = Find-RjwSites ('try { foreach ($c in @(' + $fn + ' $cdPath)) { $x = 1 } } catch {}')
  T 'MUST FIRE  the founding line from sync-recipesdb-cost (foreach over an inline-wrapped read)' ($r.Count -eq 1) $r.Count
  $r = Find-RjwSites ('$rows = @( ' + $fn + ' $p )')
  T 'MUST FIRE  an inline wrap with inner spaces' ($r.Count -eq 1) $r.Count
  $r = Find-RjwSites ('$rows = ' + $fn + ' $p' + "`n" + 'foreach ($r in $rows) { }' + "`n" + '$n = @($rows).Count')
  T 'MUST NOT FIRE  assign, then iterate or wrap the variable' ($r.Count -eq 0) $r.Count
  $r = Find-RjwSites ('$w = @(' + $fn + ' $probe)   # readjson-wrap:allow deliberate probe of the trap')
  T 'MUST NOT FIRE  a marked line with a reason' ($r.Count -eq 0) $r.Count
  $r = Find-RjwSites ('$w = @(' + $fn + ' $probe)   # readjson-wrap:allow')
  T 'MUST FIRE  a marker with no reason exempts nothing' ($r.Count -eq 1) $r.Count
  $r = Find-RjwSites ('  # never write @(' + $fn + ' x) - it collapses')
  T 'MUST NOT FIRE  a comment describing the trap' ($r.Count -eq 0) $r.Count
  $r = Find-RjwSites ("<#" + "`n" + '  the old reader wrapped @(' + $fn + ' ingredients.json)' + "`n" + '#>' + "`n" + '$x = @(' + $fn + ' y)')
  T 'MUST NOT FIRE / MUST FIRE  prose inside a <# #> block is skipped, and the call after the block is still caught (line 4)' ($r.Count -eq 1 -and $r[0] -eq 4) ($r -join ',')
  # CLEAN TWIN: the trap this guards is still real in this PowerShell, or the gate guards a ghost
  . (Join-Path $repo 'lib\json-io.ps1')
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('rjw-' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($tmp, '[{"a":1},{"a":2},{"a":3}]')
  try { $wrapped = @(Read-JsonFile $tmp); $assigned = Read-JsonFile $tmp } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }   # readjson-wrap:allow the self-test proves the trap
  T 'CLEAN TWIN  the trap is live: inline-wrapped reads 1 element, assigned reads 3' ($wrapped.Count -eq 1 -and @($assigned).Count -eq 3) ("wrapped=" + $wrapped.Count + " assigned=" + @($assigned).Count)
  if ($f -eq 0) { "audit-readjson-inline-wrap self-test PASS ($c cases)"; exit 0 } else { "audit-readjson-inline-wrap self-test FAIL ($f of $c)"; exit 1 }
}

$files = @(Get-ChildItem -Path $repo -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\(\.claude\\worktrees|archive|node_modules|\.git)\\' -and $_.FullName -ne $PSCommandPath })
$hits = @()
foreach ($fi in $files) {
  $t = [IO.File]::ReadAllText($fi.FullName)
  if ($t.IndexOf('Read-JsonFile') -lt 0) { continue }
  foreach ($ln in (Find-RjwSites $t)) { $hits += ($fi.FullName.Substring($repo.Length + 1) + ':' + $ln) }
}
foreach ($h in $hits) { "  INLINE WRAP  $h  - assign the Read-JsonFile result to a variable first, then iterate or wrap the variable" }
"readjson-inline-wrap: scanned $($files.Count) .ps1 file(s), $($hits.Count) inline-wrapped Read-JsonFile call(s)"
"READJSON-INLINE-WRAP-COMPLETE scanned=$($files.Count) findings=$($hits.Count)"
if ($hits.Count) { exit 1 } else { exit 0 }
