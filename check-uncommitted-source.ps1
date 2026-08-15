<#
  check-uncommitted-source.ps1 - answers "is there uncommitted SOURCE work?" reliably.

  The daily pipelines regenerate ~90+ tracked files every run (board data, trend HTML, audit reports,
  recipe caches, logs, the served feed), so a bare `git status` is perpetually noisy and a real
  uncommitted fix hides in it - exactly what happened 2026-07-27 (a Walmart pricing fix sat loose among
  103 dirty files). This classifies every dirty tracked file as REGENERATED (the pipeline/cloud owns it -
  ignore) or SOURCE (durable code/config you must commit), and reports only the SOURCE set.

  IT ALSO CHECKS WHAT GIT WAS NEVER TOLD ABOUT (2026-08-08). The first version of this script asked
  `git status --porcelain`, which by design lists tracked-and-dirty plus untracked, and NEVER lists
  ignored. This repo's .gitignore opens with `/*` - the root is deny-by-default - so an unversioned
  top-level directory is not "untracked", it is IGNORED, and it was invisible to this guard by
  construction. Three of them were real source: lessons\ (the local original of 55 pages live on the
  site), brand\ (the entire visual identity, one copy) and substack\ (71 archived posts). They sat that
  way for two months while this guard reported clean every time it ran, because "nobody added a negation
  for it" and "someone decided not to track it" look identical from outside.

  So the second check enumerates every TOP-LEVEL entry on disk, asks git whether it is ignored, and
  requires that each ignored one appear in IGNORED_BY_DECISION below with a reason. Top-level is the
  right scope precisely because `/*` only applies there: anything inside an already-allowed directory is
  tracked automatically, so a new file under grocery\ cannot hide this way.

  Exit 0 = clean. 2 = uncommitted source and/or an unclassified ignored top-level path (list printed).
  Run before ending any session that touched the estate; it is the model for the triage's clean-tree gate.
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'

# REGENERATED - the pipeline/cloud rebuilds or serves these; not a human's source edit.
$script:REGEN_RX = @(
  'grocery/out/',                       # all pipeline outputs (board, trend, audit, logs, sigs, captures)
  'grocery/ad-cycle-log', 'grocery/alert-log', 'grocery/local-daily-log',
  'grocery/alert-sent-',                 # daily alert-dedup markers (send-alert.ps1); rotate by date
  'grocery/board-price-overrides\.json',# generate-board-overrides regenerates
  'grocery/category-excludes\.json',    # apply-category-excludes rebakes the whole file daily
  'grocery/product-urls\.json',         # link resolvers rewrite daily
  'grocery/price-history\.json', 'grocery/ad-schedule\.json',
  'meal-prep/db/costed\.json', 'meal-prep/db/published-hashes\.json',
  'meal-prep/db/built/',                # rebuilt cards
  'meal-prep/pipeline/v2-perserving', 'meal-prep/pipeline/catalog-digest',
  'meal-prep/ingredient-map\.json', 'meal-prep/dinner-data\.js', 'meal-prep/protein-data',
  'meal-prep/scratch-smpfeed\.json',   # compute-v2's cached download of the public feed
  'meal-prep/recipes-db\.json',         # rotation/index writes (visibility flips)
  'meal-prep/free-rotation\.json',
  'public/',                            # Cloudflare-served, cloud-committed
  '\.sig$', '\.bak', '\.stamp$'
)

# TOP-LEVEL PATHS THAT ARE IGNORED ON PURPOSE. A line here is a decision someone defends in a diff, which
# is the whole point: without it, a deliberate exclusion and a two-month oversight are the same thing.
# Adding a new top-level file or folder to this repo means either allow-listing it in .gitignore or
# adding it here with the reason. There is no third option that leaves this guard quiet.
$script:IGNORED_BY_DECISION = @{
  '.claude'              = 'Claude worktree metadata and local agent state. The agent prompts that actually drive the estate are backed up under ops\, which is tracked.'
  # 2026-08-15 restructure: facebook\, out\ and seo-backlink-plan.md are no longer top-level entries.
  # facebook\ folded into brand\social\, out\ became site\build\out\, the plan doc moved to docs\.
  # They are kept out of this table deliberately - a decision recorded for a path that no longer exists
  # is a rule that can never fire again, and this table's whole value is that every line is live.
  # Not present at this root today, listed so they never become a finding. These are covered by the
  # "never commit, anywhere in the tree" block in .gitignore; a guard that nags about a correctly
  # excluded secret is a guard people start ignoring, and secrets are the last thing that should train
  # that habit. In CI they are GitHub Actions secrets, never files.
  '.ghostkey'            = 'Ghost Admin API key. Local only, never committed anywhere.'
  '.krogerkey'           = 'Kroger/Bakers developer client id + secret. Local only, never committed anywhere.'
  'ghost-config.ps1'     = 'Local Ghost connection config. Local only, never committed anywhere.'
}

# --- check 1: dirty TRACKED files that are not pipeline output -------------------------------------
function Get-UncommittedSource {
  param([string]$Root)
  Push-Location $Root
  try { $dirty = @(git status --porcelain | Where-Object { $_ }) } finally { Pop-Location }
  $src = @()
  foreach ($line in $dirty) {
    $path = $line.Substring(3).Trim('"')
    $isRegen = $false
    foreach ($rx in $script:REGEN_RX) { if ($path -match $rx) { $isRegen = $true; break } }
    if (-not $isRegen) { $src += $line }
  }
  [pscustomobject]@{ Source = $src; DirtyCount = $dirty.Count }
}

# --- check 2: top-level paths git has been told to ignore, that nobody has classified ---------------
function Find-UnclassifiedIgnored {
  param([string]$Root, [hashtable]$Allow)
  $found = @()
  Push-Location $Root
  try {
    foreach ($e in @(Get-ChildItem -Force | Where-Object { $_.Name -ne '.git' })) {
      if ($Allow.ContainsKey($e.Name)) { continue }
      # -q is silent and carries the answer in the exit code: 0 = ignored, 1 = not. A native exe's
      # non-zero exit does not throw under EAP=Stop, and check-ignore writes nothing to stderr here,
      # so this needs no redirection - which is the trap that has killed other guards in this estate.
      git check-ignore -q -- $e.Name
      if ($LASTEXITCODE -ne 0) { continue }
      $files = if ($e.PSIsContainer) { @(Get-ChildItem $e.FullName -Recurse -File -ErrorAction SilentlyContinue) } else { @($e) }
      $bytes = ($files | Measure-Object Length -Sum).Sum
      $found += [pscustomobject]@{
        Name  = $e.Name
        Kind  = $(if ($e.PSIsContainer) { 'dir' } else { 'file' })
        Files = $files.Count
        KB    = [Math]::Round(([double]$bytes) / 1KB, 1)
      }
    }
  } finally { Pop-Location }
  # NO leading comma. `,$found` on an EMPTY $found returns an array whose single element is the empty
  # array, so `@(...)` at the call site unrolls to Count=1 and the guard reports one finding with a blank
  # name - a false alarm on a clean tree, which is the one failure mode a guard must never have. Every
  # caller already wraps in @(), which preserves the single-element case correctly on its own.
  $found
}

# --- self-test: the founding bug, frozen, plus its clean twin ---------------------------------------
# The founding bug is lessons\: a deny-by-default root, a directory of real source with no negation for
# it, and a guard that reported clean. The fixture rebuilds exactly that shape in a scratch repo rather
# than reading the live tree, so it keeps testing the 2026-08-08 defect after the live tree is fixed.
if ($SelfTest) {
  $fail = 0
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("cus-selftest-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    Push-Location $tmp
    git init -q 2>$null | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmp 'lessons') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmp 'grocery') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmp 'lessons\lesson-04-the-gap-is-the-score.md'), "# Week 4`n")
    [IO.File]::WriteAllText((Join-Path $tmp 'grocery\build.ps1'), "# tracked`n")
    Pop-Location

    $denyRoot = "/*`n!/.gitignore`n!/grocery/`n"
    [IO.File]::WriteAllText((Join-Path $tmp '.gitignore'), $denyRoot)

    # MUST FIRE: lessons\ is ignored by the /* rule and classified nowhere.
    $hit = @(Find-UnclassifiedIgnored -Root $tmp -Allow @{})
    if ($hit.Name -contains 'lessons') {
      Write-Output '  ok   must-fire: an unclassified ignored top-level dir is reported'
    } else {
      Write-Output ('  FAIL must-fire: lessons\ was NOT reported (got: ' + (($hit | ForEach-Object { $_.Name }) -join ',') + ')')
      $fail++
    }

    # CLEAN TWIN A: the same tree, once .gitignore allow-lists it. This is the fix, and it must silence
    # the guard - a detector that still fires after the repair teaches everyone to ignore it.
    [IO.File]::WriteAllText((Join-Path $tmp '.gitignore'), $denyRoot + "!/lessons/`n")
    $twin = @(Find-UnclassifiedIgnored -Root $tmp -Allow @{})
    # COUNT, not just absence. The first version asserted `-notcontains 'lessons'`, which a phantom
    # element satisfies: `,$found` on an empty result returned Count=1 holding an empty array, and the
    # guard printed a blank-named finding on a clean tree. Absence tests cannot see a false positive.
    if ($twin.Count -eq 0) {
      Write-Output '  ok   clean twin: allow-listing it in .gitignore clears the finding, count is 0'
    } else { Write-Output ('  FAIL clean twin: expected 0 findings, got ' + $twin.Count); $fail++ }

    # CLEAN TWIN B: still ignored, but named in IGNORED_BY_DECISION. The other legitimate resolution.
    [IO.File]::WriteAllText((Join-Path $tmp '.gitignore'), $denyRoot)
    $twin2 = @(Find-UnclassifiedIgnored -Root $tmp -Allow @{ 'lessons' = 'deliberate' })
    if ($twin2.Name -notcontains 'lessons') {
      Write-Output '  ok   clean twin: a recorded decision clears the finding'
    } else { Write-Output '  FAIL clean twin: a recorded decision did not clear the finding'; $fail++ }

    # AND IT MUST NOT SWALLOW THE TRACKED CASE: grocery\ is allow-listed, so it is not ignored and must
    # never appear. Without this, "report nothing" and "report everything" both pass the twins above.
    if ($twin2.Name -notcontains 'grocery') {
      Write-Output '  ok   an allow-listed directory is not reported as ignored'
    } else { Write-Output '  FAIL a tracked, allow-listed directory was reported as ignored'; $fail++ }
  } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if ($fail) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $fail); exit 1 }
  Write-Output 'check-uncommitted-source self-test: 4/4 ok'
  exit 0
}

# --- main -------------------------------------------------------------------------------------------
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew' }
$r = Get-UncommittedSource -Root $root
$ignored = @(Find-UnclassifiedIgnored -Root $root -Allow $script:IGNORED_BY_DECISION)

$bad = 0
if ($r.Source.Count) {
  $bad++
  Write-Output ("UNCOMMITTED SOURCE: {0} file(s) (of {1} dirty) need review/commit:" -f $r.Source.Count, $r.DirtyCount)
  $r.Source | ForEach-Object { Write-Output ("  " + $_) }
}
if ($ignored.Count) {
  $bad++
  Write-Output ("UNCLASSIFIED IGNORED TOP-LEVEL PATH: {0}. Each is invisible to git and to this guard." -f $ignored.Count)
  Write-Output "  Resolve by allow-listing it in .gitignore (if it is source) or adding it to"
  Write-Output "  IGNORED_BY_DECISION in this script with the reason (if it is not)."
  $ignored | ForEach-Object { Write-Output ("  {0,-24} {1,-5} {2,4} file(s) {3,9} KB" -f $_.Name, $_.Kind, $_.Files, $_.KB) }
}
if ($bad) { exit 2 }
Write-Output ("clean: no uncommitted SOURCE ({0} regenerated/output files ignored), no unclassified ignored top-level paths" -f $r.DirtyCount)
exit 0
