<#
  main-checkout.ps1 - which checkout is MAIN, and where a file that lives only there (the triage queue) is.

  WHY THIS EXISTS (2026-09-23, ops lane). grocery\send-alert.ps1 wrote the triage queue next to itself, so from a
  linked worktree (.claude\worktrees\<name>) it wrote that worktree's GITIGNORED copy of grocery\triage-queue.json. On
  2026-09-22 several triage agents minted residuals there and the items had to be moved into the main queue by hand;
  an item nobody moves is an alert nobody triages. triage-close.ps1 and validate-triage-plan.ps1 had the same default.
  The queue is one fact and it lives in one place: the MAIN checkout, the parent of the git common dir.

  THE RULE. A caller with no explicit -QueueFile asks Resolve-TcMainQueueFile. From the main checkout (or anything
  that is not a git checkout at all, like a self-test sandbox under %TEMP%) the answer is the caller's own local path,
  byte for byte what it was before. From a LINKED worktree it is the same repo-relative path under the main checkout.
  An explicit -QueueFile always wins. Nothing here decides WHETHER a send from a worktree is allowed; send-alert's own
  refusal of an automated send from a linked worktree runs before any of this.

  WHAT IT CANNOT DO: a common dir whose leaf is not `.git` (a bare repo, a separate-git-dir checkout) has no main
  working tree to point at, so the caller keeps its local path and .note says why.

  Dot-source:  . (Join-Path $repoRoot 'lib\main-checkout.ps1')
  Self-test:   powershell -NoProfile -File lib\main-checkout.ps1 -SelfTest

  NO param() BLOCK, DELIBERATELY - dot-sourced under PS 5.1 a param() block runs in the CALLER's scope
  (lib\json-io.ps1 has the account).
#>
$__mcSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-TcMainCheckout {
  <# The checkout $Dir sits in: ok, linked, top (its own toplevel), main (the main checkout's root, '' when there is
     none to name), note. Never throws: a directory git cannot read is ok=$false. #>
  param([string]$Dir)
  $r = [pscustomobject]@{ ok = $false; linked = $false; top = ''; main = ''; note = '' }
  if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { $r.note = 'no such directory'; return $r }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $top = [string](& git -C $Dir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $top) { $r.note = 'not a git checkout'; return $r }
    $gd = [string](& git -C $Dir rev-parse --absolute-git-dir 2>$null)
    $cd = [string](& git -C $Dir rev-parse --git-common-dir 2>$null)
    if (-not $gd -or -not $cd) { $r.note = 'git could not name its dirs'; return $r }
  } catch { $r.note = ('git threw: ' + $_.Exception.Message); return $r } finally { $ErrorActionPreference = $prevEap }
  if (-not [IO.Path]::IsPathRooted($cd)) { $cd = Join-Path $Dir $cd }
  $gdF = ([IO.Path]::GetFullPath($gd.Trim().Replace('/', '\'))).TrimEnd('\')
  $cdF = ([IO.Path]::GetFullPath($cd.Trim().Replace('/', '\'))).TrimEnd('\')
  $r.ok = $true
  $r.top = ([IO.Path]::GetFullPath($top.Trim().Replace('/', '\'))).TrimEnd('\')
  $r.linked = -not [string]::Equals($gdF, $cdF, [StringComparison]::OrdinalIgnoreCase)
  if (-not $r.linked) { $r.main = $r.top; return $r }
  if ([string]::Equals((Split-Path -Leaf $cdF), '.git', [StringComparison]::OrdinalIgnoreCase)) { $r.main = Split-Path -Parent $cdF }
  else { $r.note = ('the common dir ' + $cdF + ' is not a .git directory, so there is no main working tree to name') }
  return $r
}

function Resolve-TcMainQueueFile {
  <# Where a caller with no explicit queue writes: $LocalQueue from the main checkout or outside git, and the same
     repo-relative path under the MAIN checkout from a linked worktree. Returns [pscustomobject]@{ path; routed; note }. #>
  param([Parameter(Mandatory = $true)][string]$Dir, [Parameter(Mandatory = $true)][string]$LocalQueue)
  $mc = Get-TcMainCheckout -Dir $Dir
  if (-not $mc.ok -or -not $mc.linked -or -not $mc.main) {
    return [pscustomobject]@{ path = $LocalQueue; routed = $false; note = $mc.note }
  }
  $localFull = [IO.Path]::GetFullPath($LocalQueue)
  $prefix = $mc.top + '\'
  if (-not $localFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ path = $LocalQueue; routed = $false; note = ('the local queue ' + $localFull + ' is outside the checkout ' + $mc.top) }
  }
  $rel = $localFull.Substring($prefix.Length)
  return [pscustomobject]@{ path = (Join-Path $mc.main $rel); routed = $true; note = ('linked worktree ' + $mc.top + ' routes to the main checkout ' + $mc.main) }
}

if ($__mcSelfTest) {
  $ErrorActionPreference = 'Stop'
  $fail = 0; $cases = 0
  function _T([string]$n, [bool]$c, [string]$g = '') { $script:cases++; if ($c) { Write-Output ('ok    ' + $n) } else { Write-Output ('FAIL  ' + $n + '   got: ' + $g); $script:fail++ } }
  . (Join-Path $PSScriptRoot 'git-repo-env.ps1'); Clear-TcGitRepoEnv
  $mcRoot = Join-Path $env:TEMP ('mc-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $mcMain = Join-Path $mcRoot 'main'; $mcLinked = Join-Path $mcRoot 'linked'; $mcPlain = Join-Path $mcRoot 'plain'
  try {
    New-Item -ItemType Directory -Path (Join-Path $mcMain 'grocery') -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $mcPlain -Force -ErrorAction Stop | Out-Null
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      & git -C $mcMain init -q -b main . 2>$null | Out-Null
      & git -C $mcMain config user.email t@t 2>$null | Out-Null
      & git -C $mcMain config user.name T 2>$null | Out-Null
      [IO.File]::WriteAllText((Join-Path $mcMain 'grocery\a.txt'), 'a')
      & git -C $mcMain add -A -- grocery 2>$null | Out-Null
      & git -C $mcMain commit -q -m a 2>$null | Out-Null
      & git -C $mcMain worktree add -q $mcLinked 2>$null | Out-Null
    } finally { $ErrorActionPreference = $prevEap }
    $lq = Join-Path $mcLinked 'grocery\triage-queue.json'
    $rl = Resolve-TcMainQueueFile -Dir (Join-Path $mcLinked 'grocery') -LocalQueue $lq
    # THE FOUNDING CASE, 2026-09-22: a residual minted from a worktree landed in the worktree's own queue.
    _T 'MUST FIRE  from a linked worktree the queue resolves to the MAIN checkout''s grocery\triage-queue.json' ($rl.routed -and ([IO.Path]::GetFullPath($rl.path) -eq [IO.Path]::GetFullPath((Join-Path $mcMain 'grocery\triage-queue.json')))) ($rl.path + ' | ' + $rl.note)
    $mq = Join-Path $mcMain 'grocery\triage-queue.json'
    $rm = Resolve-TcMainQueueFile -Dir (Join-Path $mcMain 'grocery') -LocalQueue $mq
    _T 'CLEAN TWIN from the main checkout the queue is the caller''s own path, unchanged' ((-not $rm.routed) -and ($rm.path -eq $mq)) ($rm.path)
    $pq = Join-Path $mcPlain 'triage-queue.json'
    $rp = Resolve-TcMainQueueFile -Dir $mcPlain -LocalQueue $pq
    _T 'CLEAN TWIN outside any git checkout (a self-test sandbox) the queue is the caller''s own path' ((-not $rp.routed) -and ($rp.path -eq $pq)) ($rp.path + ' | ' + $rp.note)
    $mcl = Get-TcMainCheckout -Dir $mcLinked
    _T 'the linked worktree names its own top and the main root' ($mcl.ok -and $mcl.linked -and ($mcl.main -eq ([IO.Path]::GetFullPath($mcMain)).TrimEnd('\'))) ($mcl.main)
  } finally {
    $prevEap2 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $mcMain worktree remove --force $mcLinked 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $prevEap2 }
    Remove-Item -LiteralPath $mcRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($cases -ne 4) { Write-Output ('main-checkout SELF-TEST FAIL: expected 4 cases, ran ' + $cases); exit 1 }
  if ($fail -gt 0) { Write-Output ('main-checkout SELF-TEST FAIL: ' + $fail + ' of ' + $cases + ' case(s)'); exit 1 }
  Write-Output ('main-checkout SELF-TEST PASS: ' + $cases + ' of ' + $cases + ' (a linked worktree routes to the main queue; the main checkout and a sandbox keep their own)')
  exit 0
}
