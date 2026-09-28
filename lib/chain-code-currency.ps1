# chain-code-currency.ps1 - the daily chain runs on the newest origin code, and an artifact it ships was built by the
# code it ships with.
#
# THE FOUNDING DEFECT (2026-09-23, daily commit cec9779a3). The 08:00 chain's second run started at 09:32 on the main
# checkout at 6f4c4f2b7. 8b8d85ff7 (feed-everyday-ps writes recipe_stats for the homepage) landed on origin while it
# ran. The chain built public\smp-feed.json with the OLD feed-everyday-ps, then its push stage rebased onto origin
# (10:28 and 10:39) and pushed that old-code feed over the newer served one: recipe_stats vanished, the 17 held
# recipes came back and free-chicken-alfredo was missing. Nothing compared the code that BUILT an artifact with the
# code the push was about to ship it beside.
#
# ONE QUESTION, AT PUSH TIME. Get-TcStaleArtifacts, called after the push stage's rebase: for each served artifact the
# bot commit changed, the scripts that PRODUCE it (derived below, never hand-listed), and which of them the range
# <base>..<tip> changed. A non-empty answer means the artifact was built by code older than the code it would ship
# beside: capture-run regenerates it on the rebased code (the feed) or names it and pages (everything else, for now).
# THE START OF THE RUN IS NOT HERE, ON PURPOSE: syncing the checkout before the chain runs is W4.1 of
# design/PLAN-bot-checkout-self-heal-2026-09-23.md, ruled by Brad the same day, whose G2 forbids the bot a rebase or an
# autostash on the shared checkout. A second start-sync built on a rebase would contradict that ruling.
## HOW THE PRODUCER SET IS DERIVED. Roots: every script under the chain manifest's derive_dirs (ops\chain-manifest.json)
# whose code names the artifact's file name on a line that also WRITES (WriteAllText, Set-Content, Out-File,
# Write-TcAtomicFile, Write-TcLfFile, Copy-Item, Move-Item), OR assigns it to a variable ('$p = Join-Path $db
# ''costed.json''') that another code line of the same script writes through (the DATAFLOW root). Then the closure:
# every .ps1 or .js a producer INVOKES (named on a line carrying dot-source, '&', -File, node, Invoke-Native(Script),
# Start-Process, powershell or RunPS), resolved by file name under the same dirs, minus the manifest's exclude_globs.
# For public\smp-feed.json at origin/main on 2026-09-23 that is export-feed.ps1 and what it calls, which includes
# feed-everyday-ps.ps1 and its live-price-fill.js, the change that was missed. Until 2026-09-28 the closure followed
# EVERY name in code, string literals and fixtures included, and 116 to 183 of 650 scripts were producers of each
# served file; with invocation edges and dataflow roots the prototype measured 19 to 82 (queue 2026-09-28-d70062).
# SCOPE OF A CLEAN ANSWER: unsound - a producer whose artifact path arrives as a parameter or is assembled in another
# function (cost-recipes -OutFile), or a script named through a computed string, is outside the set, and a clean answer
# then proves nothing about it. It is also incomplete: a name on a line that happens to carry an invocation token is
# followed whether or not that line calls it, so a finding is a candidate to read, never a proof the artifact changed. Reading an INPUT (the board a builder consumes) is out of scope by design: this asks
# whether the WRITER's code moved.
#
# NO param() BLOCK: dot-sourced into capture-run, which runs under EAP=Stop. Git runs through Invoke-GitCaptured
# (lib\git-blob-lib.ps1), which reads both streams off a Process and never redirects a native child's stderr.
# Self-test: powershell -File lib\chain-code-currency.ps1 -SelfTest   (reads $args, so the dot-source stays inert)
# The self-test builds its own repos in temp; it loads git-blob-lib.ps1 and git-repo-env.ps1 and reads no tracked data.
# gate-inputs: lib\git-blob-lib.ps1, lib\git-repo-env.ps1

if (-not (Get-Command Invoke-GitCaptured -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'git-blob-lib.ps1') }

# A script naming more than this many others is an orchestrator: first plausible number, not a sweep. Measured 2026-09-23 at
# origin/main: export-feed names 8, feed-everyday-ps 3, build-deals-page 21, capture-run and check-ad-cycles well over 60.
$script:CccHubNames = 25
$script:CccWriteVerb = '(WriteAllText|WriteAllBytes|Set-Content|Out-File|Write-TcAtomicFile|Write-TcLfFile|Copy-Item|Move-Item)'
# A line that names a script AND carries one of these calls it; the reviewer's prototype token set, the first plausible
# list (1 variant), measured over 650 scripts at 812fad5b3 (queue 2026-09-28-d70062).
$script:CccInvokeToken = '(^\s*\.\s)|(&\s*[\(''"$\.])|(-File\b)|(\bnode(\.exe)?\b)|(Invoke-Native(Script)?\b)|(Start-Process\b)|(\bpowershell(\.exe)?\b)|(\bRunPS\b)'

function Invoke-TcCccGit([string]$Repo, [string[]]$GitArgs) {
  $r = Invoke-GitCaptured -Repo $Repo -GitArgs $GitArgs
  return [pscustomobject]@{ Rc = [int]$r.rc; Out = [string]$r.stdout; Err = [string]$r.stderr
    Lines = @(([string]$r.stdout) -split "`r?`n" | Where-Object { $_ -ne '' }) }
}

function Get-TcCccManifest([string]$Repo, [string]$Rev) {
  <# derive_dirs and exclude_globs from ops/chain-manifest.json AT $Rev. Falls back to the dirs the chain lives in when
     the manifest is absent, so a tree older than the manifest still derives a set rather than none. #>
  $m = Invoke-TcCccGit $Repo @('show', ($Rev + ':ops/chain-manifest.json'))
  $dirs = @('grocery/', 'lib/', 'meal-prep/engine/', 'meal-prep/lib/', 'meal-prep/pipeline/', 'ops/'); $ex = @()
  if ($m.Rc -eq 0) {
    try { $doc = $m.Out | ConvertFrom-Json; if ($doc.derive_dirs) { $dirs = @($doc.derive_dirs) }; if ($doc.exclude_globs) { $ex = @($doc.exclude_globs) } } catch { }
  }
  $exRx = @($ex | ForEach-Object { '^' + ([regex]::Escape([string]$_) -replace '\\\*', '[^/]*') + '$' })
  return [pscustomobject]@{ Dirs = @($dirs | ForEach-Object { ([string]$_).TrimEnd('/') + '/' }); Exclude = $exRx }
}

function Test-TcCccExcluded([string]$Path, [string[]]$ExcludeRx) {
  if ($Path -match '(^|/)archive/') { return $true }   # retired one-offs never run in the chain
  foreach ($x in $ExcludeRx) { if ($Path -match $x) { return $true } }
  return $false
}

function Get-TcArtifactProducers {
  <# The producer closure of each artifact at $Rev: a hashtable artifact -> sorted repo-relative script paths. An
     artifact with no writer found maps to an empty list (said, never guessed). #>
  param([string]$Repo, [string]$Rev, [string[]]$Artifacts)
  $mf = Get-TcCccManifest $Repo $Rev
  $ls = Invoke-TcCccGit $Repo (@('ls-tree', '-r', '--name-only', $Rev, '--') + @($mf.Dirs))
  $byLeaf = @{}
  foreach ($p in $ls.Lines) {
    if ($p -notmatch '\.(ps1|js)$') { continue }
    if (Test-TcCccExcluded $p $mf.Exclude) { continue }
    $leaf = ($p -split '/')[-1].ToLowerInvariant()
    if (-not $byLeaf.ContainsKey($leaf)) { $byLeaf[$leaf] = New-Object Collections.ArrayList }
    [void]$byLeaf[$leaf].Add($p)
  }
  # CODE ONLY: block comments, whole-line comments and a trailing " # ..." are dropped before names are read, so a
  # script a producer merely MENTIONS (its history, a sibling it is compared with) does not join the closure. Measured
  # 2026-09-23 with comments read: the feed's closure was 522 scripts, nearly the whole tree.
  $codeCache = @{}
  $getCode = { param($p)
    if (-not $codeCache.ContainsKey($p)) {
      $t = Invoke-TcCccGit $Repo @('show', ($Rev + ':' + $p))
      $c = [regex]::Replace($(if ($t.Rc -eq 0) { $t.Out } else { '' }), '(?s)<#.*?#>', '')
      $codeCache[$p] = @($c -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') -and -not $_.TrimStart().StartsWith('//') } | ForEach-Object { $_ -replace '\s#\s.*$', '' })
    }
    , $codeCache[$p] }
  $result = @{}
  $leaves = @{}
  foreach ($a in @($Artifacts)) { $leaves[$a] = (($a -replace '\\', '/') -split '/')[-1] }
  # ONE git grep for every leaf: the lines that name an artifact file AND write on the same line.
  $gArgs = @('grep', '-n', '-F', '-I')
  foreach ($l in ($leaves.Values | Select-Object -Unique)) { $gArgs += @('-e', $l) }
  $gArgs += @($Rev, '--') + @($mf.Dirs)
  $gr = Invoke-TcCccGit $Repo $gArgs
  foreach ($a in @($Artifacts)) {
    $leaf = $leaves[$a]
    $roots = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($ln in $gr.Lines) {
      $m = [regex]::Match($ln, '^[^:]+:([^:]+):\d+:(.*)$')
      if (-not $m.Success) { continue }
      $path = $m.Groups[1].Value; $code = $m.Groups[2].Value
      if ($path -notmatch '\.(ps1|js)$' -or (Test-TcCccExcluded $path $mf.Exclude)) { continue }
      if ($code.TrimStart().StartsWith('#')) { continue }
      # The leaf is a whole FILE NAME: 'recipe-board.json' is not board.json (measured 2026-09-28: without the boundary
      # audit-ingredient-identity's sandbox '$rbf = Join-Path $tmp ''recipe-board.json''' became a board.json root).
      if ($code -notmatch ('(?i)(?<![A-Za-z0-9_.-])' + [regex]::Escape($leaf))) { continue }
      if ($code -match $script:CccWriteVerb) { [void]$roots.Add($path); continue }
      # DATAFLOW ROOT: the real builders write through a path variable ('$costedPath = Join-Path $db ''costed.json'''
      # then WriteAllText($costedPath, ...)), so a line assigning the leaf to $<var> makes a root when another code line
      # of the same script writes and names $<var> whole-word. Without it costed.json's roots were all self-test
      # sandbox writes and cost-recipes.ps1 was reached only by accident (queue 2026-09-28-d70062).
      $am = [regex]::Match($code, '^\s*\$([A-Za-z_][A-Za-z0-9_]*)\s*=')
      if (-not $am.Success) { continue }
      $vRx = '\$' + [regex]::Escape($am.Groups[1].Value) + '\b'
      $body = & $getCode $path
      if (@($body | Where-Object { $_ -match $script:CccWriteVerb -and $_ -match $vRx }).Count) { [void]$roots.Add($path) }
    }
    $seen = New-Object 'Collections.Generic.HashSet[string]'
    $queue = New-Object Collections.Queue
    foreach ($r in $roots) { if ($seen.Add($r)) { $queue.Enqueue($r) } }
    while ($queue.Count) {
      $p = [string]$queue.Dequeue()
      $lines = & $getCode $p
      # INVOCATION EDGES ONLY: a name is followed when the line naming it also INVOKES (dot-source, '&', -File, node,
      # Invoke-Native(Script), Start-Process, powershell, RunPS). A name in a string literal, a fixture or doc text is
      # not a call: on 2026-09-28 such names chained alert-lib -> send-alert -> verify-price-flags -> flag-verify-lib
      # -> audit-flag-verification into every served artifact's set (116 to 183 of 650 scripts each). The hub test
      # below still counts ALL names, as before.
      $allNamed = New-Object 'Collections.Generic.HashSet[string]'
      $invNamed = New-Object 'Collections.Generic.HashSet[string]'
      foreach ($l in $lines) {
        $ms = [regex]::Matches($l, '[A-Za-z0-9_.-]+\.(ps1|js)\b')
        if ($ms.Count -eq 0) { continue }
        $isInv = ($l -match $script:CccInvokeToken)
        foreach ($mm in $ms) { $v = $mm.Value.ToLowerInvariant(); [void]$allNamed.Add($v); if ($isInv) { [void]$invNamed.Add($v) } }
      }
      # AN ORCHESTRATOR IS A PRODUCER BUT NOT A PATH: a script that names more than $script:CccHubNames others (the
      # chain's own runners, check-ad-cycles with its ~150 audits) joins the set when it writes the artifact, and its
      # own edits count, but the closure does not walk through it. Walking through it made every script a producer
      # (404 of the tree for the feed, measured 2026-09-23), and a set that is everything decides nothing.
      if ($allNamed.Count -gt $script:CccHubNames) { continue }
      foreach ($nm in $invNamed) {
        $k = $nm
        if (-not $byLeaf.ContainsKey($k)) { continue }
        foreach ($q in $byLeaf[$k]) { if ($seen.Add([string]$q)) { $queue.Enqueue([string]$q) } }
      }
    }
    $result[$a] = @($seen | Sort-Object)
  }
  return $result
}

function Get-TcStaleArtifacts {
  <# Which of $Artifacts were built by code that $Base..$Tip changed. Returns Blind ('' or why), Rows (artifact,
     producers, changed) for every artifact whose producer set the range touched, and Producers (the whole map). #>
  param([string]$Repo, [string]$Base, [string]$Tip, [string[]]$Artifacts)
  $out = [ordered]@{ Blind = ''; Rows = @(); Producers = @{} }
  if (-not $Base) { $out.Blind = 'no base: the commit the run started on was not recorded'; return [pscustomobject]$out }
  $d = Invoke-TcCccGit $Repo @('diff', '--name-only', $Base, $Tip)
  if ($d.Rc -ne 0) { $out.Blind = ('git diff ' + $Base + ' ' + $Tip + ' exited ' + $d.Rc + ': ' + $d.Err.Trim()); return [pscustomobject]$out }
  $changed = New-Object 'Collections.Generic.HashSet[string]'
  foreach ($c in $d.Lines) { [void]$changed.Add($c) }
  if (@($Artifacts).Count -eq 0) { return [pscustomobject]$out }
  $prod = Get-TcArtifactProducers -Repo $Repo -Rev $Tip -Artifacts $Artifacts
  $out.Producers = $prod
  $rows = New-Object Collections.ArrayList
  foreach ($a in @($Artifacts)) {
    $hit = @($prod[$a] | Where-Object { $changed.Contains([string]$_) })
    if ($hit.Count) { [void]$rows.Add([pscustomobject]@{ Artifact = $a; Producers = @($prod[$a]).Count; Changed = $hit }) }
  }
  $out.Rows = $rows.ToArray()
  return [pscustomobject]$out
}

$__cccSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
if ($__cccSelfTest) {
  $ErrorActionPreference = 'Stop'
  . (Join-Path $PSScriptRoot 'git-repo-env.ps1')
  Clear-TcGitRepoEnv
  $script:cf = 0; $script:cn = 0
  function CcT([string]$m, [bool]$c, [string]$g = '') { $script:cn++; if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $g); $script:cf++ } }
  $sb = Join-Path $env:TEMP ('tc-ccc-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $sb
  try {
    $up = Join-Path $sb 'up.git'; $w = Join-Path $sb 'w'; $o = Join-Path $sb 'o'
    $g = { param($d, [string[]]$a) $x = Invoke-TcCccGit $d $a; if ($x.Rc -ne 0) { throw ('git ' + ($a -join ' ') + ' in ' + $d + ': ' + $x.Err) }; $x }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $put = { param($root, $rel, $text) $p = Join-Path $root $rel; $null = New-Item -ItemType Directory -Force (Split-Path $p -Parent); [IO.File]::WriteAllText($p, $text, $utf8) }
    $null = & $g $sb 'init', '-q', '--bare', '-b', 'main', $up
    $null = & $g $sb 'clone', '-q', $up, $w
    foreach ($d in @($w)) { $null = & $g $d 'config', 'user.name', 't'; $null = & $g $d 'config', 'user.email', 't@t'; $null = & $g $d 'config', 'core.autocrlf', 'false' }
    # The founding shape, in miniature: export-feed writes the feed and names feed-everyday-ps; an unrelated audit reads it.
    & $put $w 'ops/chain-manifest.json' '{"derive_dirs":["grocery/","meal-prep/pipeline/","lib/"],"exclude_globs":["grocery/test-*.ps1"]}'
    & $put $w 'grocery/export-feed.ps1' ('# builds the feed' + "`n" + '[IO.File]::WriteAllText((Join-Path $pub ''smp-feed.json''), $json, $enc)' + "`n" + '& (Join-Path $mp ''feed-everyday-ps.ps1'')' + "`n")
    & $put $w 'meal-prep/pipeline/feed-everyday-ps.ps1' ('$stats = 1' + "`n")
    & $put $w 'grocery/audit-feed-reader.ps1' ('$f = Get-Content (Join-Path $pub ''smp-feed.json'')' + "`n")
    & $put $w 'grocery/test-feed.ps1' ('Set-Content ''smp-feed.json'' x' + "`n")
    & $put $w 'public/smp-feed.json' '{}'
    $null = & $g $w 'add', '-A'; $null = & $g $w 'commit', '-q', '-m', 'A'; $null = & $g $w 'push', '-q', 'origin', 'main'
    $baseA = (& $g $w 'rev-parse', 'HEAD').Out.Trim()
    $pr = Get-TcArtifactProducers -Repo $w -Rev 'HEAD' -Artifacts @('public/smp-feed.json')
    $set = @($pr['public/smp-feed.json'])
    CcT 'MECHANISM  the feed''s producers are its WRITER and what the writer names (export-feed, feed-everyday-ps), never a reader or an excluded test' ($set.Count -eq 2 -and $set -contains 'grocery/export-feed.ps1' -and $set -contains 'meal-prep/pipeline/feed-everyday-ps.ps1') ($set -join ',')
    # MUST FIRE: the range brings a change to feed-everyday-ps (8b8d85ff7's shape).
    & $put $w 'meal-prep/pipeline/feed-everyday-ps.ps1' ('$stats = 2   # recipe_stats' + "`n")
    $null = & $g $w 'commit', '-q', '-am', 'B: feed-everyday-ps writes recipe_stats'
    $tipB = (& $g $w 'rev-parse', 'HEAD').Out.Trim()
    $s1 = Get-TcStaleArtifacts -Repo $w -Base $baseA -Tip $tipB -Artifacts @('public/smp-feed.json')
    CcT 'MUST FIRE  a rebase that brings in a change to feed-everyday-ps (cec9779a3''s case) names the feed as built by stale code' (-not $s1.Blind -and @($s1.Rows).Count -eq 1 -and @($s1.Rows)[0].Artifact -eq 'public/smp-feed.json' -and (@(@($s1.Rows)[0].Changed) -contains 'meal-prep/pipeline/feed-everyday-ps.ps1')) (($s1 | ConvertTo-Json -Depth 4 -Compress))
    # CLEAN TWIN: an unrelated range (a reader and a test change) ships the feed unchanged.
    & $put $w 'grocery/audit-feed-reader.ps1' ('$f = Get-Content (Join-Path $pub ''smp-feed.json'') # v2' + "`n")
    & $put $w 'grocery/test-feed.ps1' ('Set-Content ''smp-feed.json'' y' + "`n")
    & $put $w 'grocery/unrelated.ps1' ('1' + "`n")
    $null = & $g $w 'add', '-A'; $null = & $g $w 'commit', '-q', '-m', 'C: unrelated'
    $tipC = (& $g $w 'rev-parse', 'HEAD').Out.Trim()
    $s2 = Get-TcStaleArtifacts -Repo $w -Base $tipB -Tip $tipC -Artifacts @('public/smp-feed.json')
    CcT 'MUST NOT FIRE  a rebase over unrelated commits (a feed READER, an excluded test, a new script) leaves the feed current: no stale row, producers still derived' (-not $s2.Blind -and @($s2.Rows).Count -eq 0 -and @($s2.Producers['public/smp-feed.json']).Count -eq 2) (($s2 | ConvertTo-Json -Depth 4 -Compress))
    $s3 = Get-TcStaleArtifacts -Repo $w -Base '' -Tip $tipC -Artifacts @('public/smp-feed.json')
    CcT 'MUST FIRE  no recorded base is BLIND, never a clean answer' ([bool]$s3.Blind) (($s3 | ConvertTo-Json -Compress))
    # The 2026-09-28 shape (queue 2026-09-28-d70062), frozen: the real builder writes costed.json only through a path
    # VARIABLE, dot-sources its lib and an alert lib; the alert lib's self-test holds a JSON string literal naming
    # verify-price-flags.ps1, which dot-sources flag-verify-lib, whose doc text names audit-flag-verification.ps1.
    $costRel = 'meal-prep/pipeline/cost-recipes.ps1'
    $costV1 = '$costedPath = Join-Path $db ''costed.json''' + "`n" + '. (Join-Path $here ''cost-lib.ps1'')' + "`n" + '. (Join-Path $here ''alert-lib.ps1'')' + "`n" + '[IO.File]::WriteAllText($costedPath, $json, $enc)' + "`n"
    & $put $w $costRel $costV1
    & $put $w 'lib/cost-lib.ps1' ('function Get-Cost { 1 }' + "`n")
    & $put $w 'lib/alert-lib.ps1' ('$fixture = ''{"type":"x","route":"lane:grocery/verify-price-flags.ps1"}''' + "`n")
    & $put $w 'grocery/verify-price-flags.ps1' ('. (Join-Path $PSScriptRoot ''flag-verify-lib.ps1'')' + "`n")
    & $put $w 'grocery/flag-verify-lib.ps1' ('$usage = ''the lib that audit-flag-verification.ps1 reads''' + "`n")
    & $put $w 'grocery/audit-flag-verification.ps1' ('$q = 1' + "`n")
    & $put $w 'meal-prep/pipeline/audit-recipe-costed.ps1' ('$rcf = Join-Path $tmp ''recipe-costed.json''' + "`n" + 'Set-Content $rcf x' + "`n")
    & $put $w 'meal-prep/db/costed.json' '{}'
    $null = & $g $w 'add', '-A'; $null = & $g $w 'commit', '-q', '-m', 'D: cost builder'
    $tipD = (& $g $w 'rev-parse', 'HEAD').Out.Trim()
    $pc = Get-TcArtifactProducers -Repo $w -Rev 'HEAD' -Artifacts @('meal-prep/db/costed.json')
    $cset = @($pc['meal-prep/db/costed.json'])
    CcT 'MECHANISM  costed.json''s producers are its path-variable WRITER (a dataflow root) and the two libs it dot-sources, never a script named only inside a string literal, nor a writer of recipe-costed.json (a longer file name ending in the leaf)'($cset.Count -eq 3 -and $cset -contains $costRel -and $cset -contains 'lib/cost-lib.ps1' -and $cset -contains 'lib/alert-lib.ps1') ($cset -join ',')
    # MUST NOT FIRE: the 09-28 range changed only the audit and its lib.
    & $put $w 'grocery/audit-flag-verification.ps1' ('$q = 2' + "`n")
    & $put $w 'grocery/flag-verify-lib.ps1' ('$usage = ''the lib that audit-flag-verification.ps1 reads, v2''' + "`n")
    $null = & $g $w 'commit', '-q', '-am', 'E: an unverified new-product crown quarantines itself'
    $tipE = (& $g $w 'rev-parse', 'HEAD').Out.Trim()
    $s4 = Get-TcStaleArtifacts -Repo $w -Base $tipD -Tip $tipE -Artifacts @('meal-prep/db/costed.json', 'public/smp-feed.json')
    CcT 'MUST NOT FIRE  a range changing only an audit reached through a string literal and doc text (the 2026-09-28 page) names no artifact' (-not $s4.Blind -and @($s4.Rows).Count -eq 0) (($s4 | ConvertTo-Json -Depth 4 -Compress))
    # MUST FIRE: a change to the path-variable writer itself (the old same-line root rule missed it).
    & $put $w $costRel ($costV1 + '$v = 2' + "`n")
    $null = & $g $w 'commit', '-q', '-am', 'F: cost builder changes'
    $tipF = (& $g $w 'rev-parse', 'HEAD').Out.Trim()
    $s5 = Get-TcStaleArtifacts -Repo $w -Base $tipE -Tip $tipF -Artifacts @('meal-prep/db/costed.json')
    CcT 'MUST FIRE  a range changing a builder that writes costed.json only through ''$p = Join-Path $db ''''costed.json'''''' names costed.json' (-not $s5.Blind -and @($s5.Rows).Count -eq 1 -and (@(@($s5.Rows)[0].Changed) -contains $costRel)) (($s5 | ConvertTo-Json -Depth 4 -Compress))
    # CLEAN TWIN: a lib the builder DOT-SOURCES changes, and the artifact is still named (the invocation filter kept a real edge).
    & $put $w 'lib/cost-lib.ps1' ('function Get-Cost { 2 }' + "`n")
    $null = & $g $w 'commit', '-q', '-am', 'G: cost lib changes'
    $tipG = (& $g $w 'rev-parse', 'HEAD').Out.Trim()
    $s6 = Get-TcStaleArtifacts -Repo $w -Base $tipF -Tip $tipG -Artifacts @('meal-prep/db/costed.json')
    CcT 'CLEAN TWIN  a range changing a lib the builder dot-sources still names costed.json' (-not $s6.Blind -and @($s6.Rows).Count -eq 1 -and (@(@($s6.Rows)[0].Changed) -contains 'lib/cost-lib.ps1')) (($s6 | ConvertTo-Json -Depth 4 -Compress))
  } catch {
    CcT ('the suite ran to the end without throwing') $false $_.Exception.Message
  } finally { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }
  $want = 8
  if ($script:cn -ne $want) { Write-Output ('FAIL  the suite ran {0} case(s), expected {1}' -f $script:cn, $want); $script:cf++ }
  if ($script:cf) { Write-Output ('chain-code-currency self-test FAIL: {0} of {1}' -f $script:cf, $script:cn); exit 1 }
  Write-Output ('chain-code-currency self-test PASS: {0} of {0} cases - led by the feed-everyday-ps change of cec9779a3 being named as a stale producer' -f $script:cn)
  exit 0
}
