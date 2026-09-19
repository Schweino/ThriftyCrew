<#
  audit-secrets.ps1 - no tracked file and no commit about to be pushed carries a secret. A gate at ZERO.

  WHY THIS EXISTS (Brad's ruling, 2026-09-19, backlog I166). The estate's Ghost Admin key lives in
  meal-prep\.ghostkey or $env:GHOST_ADMIN_KEY, and the only thing between it and a commit was one .gitignore line.
  The allow-list .gitignore protects a NEW file well; it does nothing about a key pasted into an ALREADY-TRACKED
  file (a .ps1, a design plan, an incident writeup) or into a commit message, and no gate read either. Measured on
  2026-09-12: 0 of 8,477 tracked files and 0 of 2,881 commits carried a secret-scan gate. A naive Cloudflare token
  shape (any 40-character run) gave 653 false positives, so this scanner does NOT match bare shapes except where the
  shape itself is the secret (a Ghost Admin key id:secret, a PEM private key block, a service-account JSON, an
  Anthropic key prefix). Everything else must be a VALUE ASSIGNED TO A NAME that says key, token, secret or password,
  and must look random (a digit, a letter and Shannon entropy at or above $SC_MIN_ENTROPY bits a character).

  THE ONE ALLOWED VALUE (Brad, 2026-09-19): the 32-hex `token` in grocery\pull-grocery-ads.ps1 is the public
  access_token the retailer's own flyer widget sends to dam.flippenterprise.net/flyerkit - a shared retailer
  identifier, not a credential. It is allowlisted on FILE + NAME + a SHA-256 fingerprint of the value (never the
  value itself), with that reason. A different value under the same name in the same file is refused, and an entry
  that no longer matches anything fails as STALE, so the list cannot quietly accumulate permissions.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads the working-tree content of every TRACKED text file (git grep -I skips
  binaries, and this file skips itself), plus the messages of the commits between origin/main and HEAD. A clean
  report means none of the listed shapes and no high-entropy value assigned to a key/token/secret/password name
  appears there. It does not see a secret with no name beside it and no distinctive shape, one split across lines
  or built at run time, an untracked file, or history already pushed. A FINDING is a candidate, not a verdict: an
  assigned random-looking value can be a checksum or a public id, which is exactly what the allowlist is for, with
  a reason. This file never prints a matched value, only its kind, place and a short fingerprint.

  EXIT CODES: 0 clean (allowlisted entries only), 1 a finding or a STALE allowlist entry, 2 self-test regression,
  3 BLIND (not a git work tree, or git grep could not run).

    ops\audit-secrets.ps1              scan the tracked tree and the unpushed commit messages
    ops\audit-secrets.ps1 -SelfTest    planted Ghost key must fire; the allowlisted token and a sha in a doc must not
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [string]$Root = '')
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }   # ...\ops
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# Bits per character below which an assigned value is read as a word or a pattern rather than a random key. A
# random 32-hex value scores about 3.7 and a random 40-character base62 key about 4.9; identifiers and phrases
# carrying one number score lower. First value tried, and the tree measured clean at it on 2026-09-19 apart from
# the allowlisted token (see the backlog's I166 entry); a lower bar only adds candidates for a reader to rule on.
$script:SC_MIN_ENTROPY = 3.3
$script:SC_SELF = 'ops/audit-secrets.ps1'

# THE ALLOWLIST. File (repo-relative, forward slashes), the NAME the value is assigned to, the first 16 hex of the
# value's SHA-256, and the reason. The fingerprint is not the secret and cannot be reversed into it.
$script:SC_ALLOW = @(
  [pscustomobject]@{
    File = 'grocery/pull-grocery-ads.ps1'; Name = 'token'; Sha = '7b19516bf5cca225'
    Reason = 'Brad, 2026-09-19, backlog I166: the public flyerkit access_token the retailer widget sends to dam.flippenterprise.net - a shared retailer identifier, not a credential.'
  }
)

# git grep prefilter (ERE, run with -i). A SUPERSET of what the .NET patterns below decide, so a line the grep
# drops cannot be a finding. ERE has no \b or \s, which is why the precise patterns are a second pass.
$script:SC_GREP = @(
  '[0-9a-f]{24}:[0-9a-f]{64}',
  '(key|token|secret|passw(or)?d|pwd)[a-z_]*["'']?[[:space:]]*[:=][[:space:]]*["'']?[a-z0-9+/_.=-]{20,}',
  'bearer[[:space:]]+[a-z0-9_.-]{30,}',
  '"type"[[:space:]]*:[[:space:]]*"service_account"',
  '-----begin [a-z ]*private key-----',
  'sk-ant-[a-z0-9_-]{20,}',
  'api_key=[a-z0-9]{40}'
)

function Get-ScEntropy {
  param([string]$S)
  if (-not $S) { return 0.0 }
  $counts = @{}
  foreach ($ch in $S.ToCharArray()) { $counts[[string]$ch] = 1 + [int]$counts[[string]$ch] }
  $h = 0.0
  foreach ($v in $counts.Values) { $p = $v / $S.Length; $h -= $p * [Math]::Log($p, 2) }
  return $h
}

function Test-ScRandom {
  # Random-looking: long enough, has a digit AND a letter, and clears the entropy bar.
  param([string]$V)
  if ($V.Length -lt 20) { return $false }
  if ($V -notmatch '[0-9]' -or $V -notmatch '[A-Za-z]') { return $false }
  return ((Get-ScEntropy $V) -ge $script:SC_MIN_ENTROPY)
}

function Get-ScFingerprint {
  param([string]$V)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($V)) } finally { $sha.Dispose() }
  return (-join ($b[0..7] | ForEach-Object { $_.ToString('x2') }))
}

# Every secret-shaped thing on one line of text. Returns Kind, Name (the assigned name, or ''), Fingerprint.
function Get-TcSecretFinding {
  param([string]$Line)
  $out = New-Object System.Collections.Generic.List[object]
  $add = { param($k, $n, $v) $out.Add([pscustomobject]@{ Kind = $k; Name = $n; Fingerprint = (Get-ScFingerprint $v) }) }
  foreach ($m in [regex]::Matches($Line, '\b[0-9a-f]{24}:[0-9a-f]{64}\b')) { & $add 'ghost-admin-key' '' $m.Value }
  foreach ($m in [regex]::Matches($Line, '-----BEGIN [A-Z ]*PRIVATE KEY-----')) { & $add 'private-key-block' '' $m.Value }
  foreach ($m in [regex]::Matches($Line, '"type"\s*:\s*"service_account"')) { & $add 'google-service-account' '' $m.Value }
  foreach ($m in [regex]::Matches($Line, '\bsk-ant-[A-Za-z0-9_-]{20,}')) { & $add 'anthropic-api-key' '' $m.Value }
  foreach ($m in [regex]::Matches($Line, '(?i)[?&]api_key=([A-Za-z0-9]{40})\b')) { & $add 'api-data-gov-key' 'api_key' $m.Groups[1].Value }
  foreach ($m in [regex]::Matches($Line, '(?i)\bbearer\s+([A-Za-z0-9_.-]{30,})')) {
    if (Test-ScRandom $m.Groups[1].Value) { & $add 'bearer-token' 'Bearer' $m.Groups[1].Value }
  }
  # A value ASSIGNED to a key/token/secret/password name: quoted (PowerShell, JSON, Python, JS, YAML) or a bare
  # NAME=value (an env file, a URL query). The name is the evidence; the entropy bar keeps words and paths out.
  $rxs = @(
    '(?i)\b([A-Za-z0-9_]*?(?:key|token|secret|password|passwd|pwd)[A-Za-z0-9_]*)["'']?\s*[:=]\s*["'']([A-Za-z0-9+/_.=-]{20,})["'']',
    '(?i)(?:^|[\s?&;])([A-Za-z0-9_]*?(?:key|token|secret|password|passwd|pwd)[A-Za-z0-9_]*)=([A-Za-z0-9+/_.=-]{20,})(?=$|[\s&;"''])'
  )
  $seen = @{}
  foreach ($rx in $rxs) {
    foreach ($m in [regex]::Matches($Line, $rx)) {
      $name = $m.Groups[1].Value; $val = $m.Groups[2].Value
      if ($seen.ContainsKey($m.Groups[2].Index)) { continue }
      $seen[$m.Groups[2].Index] = 1
      if ($name -match '(?i)^api_key$' -and $val -match '^[A-Za-z0-9]{40}$' -and $Line -match ('(?i)[?&]api_key=' + [regex]::Escape($val))) { continue }   # already named above
      if (-not (Test-ScRandom $val)) { continue }
      $kind = 'named-secret'
      if ($name -match '(?i)(cloudflare|^cf_|_cf_)' -and $val.Length -ge 37 -and $val.Length -le 40) { $kind = 'cloudflare-api-token' }
      elseif ($name -match '(?i)(fdc|data_?gov)') { $kind = 'fdc-api-key' }
      & $add $kind $name $val
    }
  }
  return $out.ToArray()
}

# Findings split into NEW, ALLOWED and STALE allowlist entries. Pure.
function Split-ScAllowed {
  param($Findings, $Allow)
  $new = New-Object System.Collections.ArrayList; $allowed = New-Object System.Collections.ArrayList
  $used = @{}
  foreach ($f in @($Findings)) {
    $hit = $null
    for ($i = 0; $i -lt @($Allow).Count; $i++) {
      $a = @($Allow)[$i]
      if ([string]::Equals(($f.File -replace '\\', '/'), $a.File, [StringComparison]::OrdinalIgnoreCase) -and
          [string]::Equals($f.Name, $a.Name, [StringComparison]::Ordinal) -and
          [string]::Equals($f.Fingerprint, $a.Sha, [StringComparison]::Ordinal)) { $hit = $i; break }
    }
    if ($null -ne $hit) { $used[$hit] = 1; [void]$allowed.Add($f) } else { [void]$new.Add($f) }
  }
  $stale = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt @($Allow).Count; $i++) { if (-not $used.ContainsKey($i)) { [void]$stale.Add(@($Allow)[$i]) } }
  return [pscustomobject]@{ New = $new.ToArray(); Allowed = $allowed.ToArray(); Stale = $stale.ToArray() }
}

function Format-ScFinding {
  param($F)
  $n = if ($F.Name) { " assigned to '" + $F.Name + "'" } else { '' }
  return ($F.File + ':' + $F.Line + '  ' + $F.Kind + $n + '  (value sha256 ' + $F.Fingerprint + ', not printed)')
}

# The tracked tree through git grep: one line per candidate, file:line:text. Returns $null when git cannot run.
function Get-ScTreeCandidate {
  param([string]$RootFull)
  $args2 = @('-C', $RootFull, 'grep', '-I', '-n', '-i', '-E')
  foreach ($p in $script:SC_GREP) { $args2 += @('-e', $p) }
  $args2 += @('--', '.', (':(exclude)' + $script:SC_SELF))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $lines = @(& git @args2); $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  if ($rc -gt 1) { return $null }   # git grep: 0 matches, 1 none, anything else an error
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($l in $lines) {
    $m = [regex]::Match([string]$l, '^(.*?):(\d+):(.*)$')
    if ($m.Success) { $out.Add([pscustomobject]@{ File = $m.Groups[1].Value; Line = [int]$m.Groups[2].Value; Text = $m.Groups[3].Value }) }
  }
  return ,$out.ToArray()
}

# ------------------------------------------------------------------------------------------------ self-test
if ($runSelfTest) {
  $script:fail = 0; $script:cases = 0
  function Assert-ScCase {
    param([string]$Name, [bool]$Ok, [string]$Got = '')
    $script:cases++
    if ($Ok) { Write-Output ('  ok    ' + $Name) } else { $script:fail++; Write-Output ('  X     ' + $Name + '   got: ' + $Got) }
  }
  function Get-ScKinds { param($F) return (@($F | ForEach-Object { $_.Kind }) -join ',') }
  # Every planted value is BUILT, never spelled, so this file cannot carry a live match for itself or anyone.
  $h24 = ('5f3a9c' + '1e7b2d' + '4a8f60' + 'c3e1d2')
  $h64 = ('9b4e7a1c' + '3d5f2e8b' + '6a0c4d7e' + '1f3b5a9c' + '2e8d6f0a' + '4c1b3e7d' + '5a9f2c6e' + '8b0d4a1f')
  $ghostLine = '$env:GHOST_ADMIN_KEY = ''' + $h24 + ':' + $h64 + ''''

  # ---- MUST FIRE
  $f1 = @(Get-TcSecretFinding $ghostLine)
  Assert-ScCase 'MUST FIRE      a planted Ghost Admin key (24 hex : 64 hex) is found by its shape' `
    ((Get-ScKinds $f1) -match 'ghost-admin-key') (Get-ScKinds $f1)
  $f1b = @(Get-TcSecretFinding ('Paste this into the header: ' + $h24 + ':' + $h64 + ' and retry'))
  Assert-ScCase 'MUST FIRE      the same key pasted into PROSE with no name beside it is found too' `
    ((Get-ScKinds $f1b) -eq 'ghost-admin-key') (Get-ScKinds $f1b)
  $cf = ('Xk3' + 'p9Qr7Lm2' + 'Tz8Vb4Nw' + '6Yc1Hs5J' + 'd0Fg-Ae_' + 'Ru2')
  $f2 = @(Get-TcSecretFinding ('CLOUDFLARE_API_TOKEN="' + $cf + '"'))
  Assert-ScCase 'MUST FIRE      a Cloudflare API token assigned to its name is named cloudflare-api-token' `
    ((Get-ScKinds $f2) -eq 'cloudflare-api-token') (Get-ScKinds $f2)
  $f3 = @(Get-TcSecretFinding ('  "type": "service' + '_account",'))
  Assert-ScCase 'MUST FIRE      a Google service-account JSON is found by its type line' ((Get-ScKinds $f3) -eq 'google-service-account') (Get-ScKinds $f3)
  $f4 = @(Get-TcSecretFinding ('-----BEGIN ' + 'PRIVATE KEY-----'))
  Assert-ScCase 'MUST FIRE      a PEM private key block is found' ((Get-ScKinds $f4) -eq 'private-key-block') (Get-ScKinds $f4)
  $fdc = ('aB3dE5gH' + '7jK9mN1p' + 'Q2rS4tU6' + 'vW8xY0zA' + 'bC2dE4fG')
  $f5 = @(Get-TcSecretFinding ('https://api.nal.usda.gov/fdc/v1/foods/search?api_key=' + $fdc + '&query=onion'))
  Assert-ScCase 'MUST FIRE      an FDC / api.data.gov key in a URL is found' ((Get-ScKinds $f5) -eq 'api-data-gov-key') (Get-ScKinds $f5)
  $f6 = @(Get-TcSecretFinding ('$fdcApiKey = ''' + $fdc + ''''))
  Assert-ScCase 'MUST FIRE      the same key assigned in PowerShell is found and named for FDC' ((Get-ScKinds $f6) -eq 'fdc-api-key') (Get-ScKinds $f6)
  $f7 = @(Get-TcSecretFinding ('db_password: "' + 'q8Wz3kLp' + '0vNt5rYs' + '2mHc' + '"'))
  Assert-ScCase 'MUST FIRE      a random value assigned to a password name in YAML is found' ((Get-ScKinds $f7) -eq 'named-secret') (Get-ScKinds $f7)

  # ---- MUST NOT FIRE
  $tok = ('a1b2c3' + 'd4e5f60718293a4b5c6d7e8f90')   # shape only; the live token is read from the file below
  $sha40 = ('3a9f5c' + '1e7b2d4a8f60c3e1d29b4e7a1c3d5f2e8b')
  $n1 = @(Get-TcSecretFinding ('Landed as ' + $sha40 + ' on origin/main; the blob id is ' + $sha40.Substring(0, 12) + '.'))
  Assert-ScCase 'MUST NOT FIRE  a commit sha and a blob id in a doc, with no key name beside them, are silent' ($n1.Count -eq 0) (Get-ScKinds $n1)
  $n2 = @(Get-TcSecretFinding '$token = Get-GhostAdminToken -KeyFile $keyPath')
  Assert-ScCase 'MUST NOT FIRE  a token assigned from a CALL, not a literal, is silent' ($n2.Count -eq 0) (Get-ScKinds $n2)
  $n3 = @(Get-TcSecretFinding 'sort_key = "conversion_factor_per_serving_size"')
  Assert-ScCase 'MUST NOT FIRE  a key name holding a WORD (no digit, low entropy) is silent' ($n3.Count -eq 0) (Get-ScKinds $n3)
  $n4 = @(Get-TcSecretFinding '"account_id": "0123456789abcdef0123456789abcdef"')
  Assert-ScCase 'MUST NOT FIRE  a public id under a name that is not key/token/secret/password is silent' ($n4.Count -eq 0) (Get-ScKinds $n4)

  # The allowlisted flyer token, read from its REAL line, must be found and then ALLOWED - never silent by accident.
  $adsPath = Join-Path $repo 'grocery\pull-grocery-ads.ps1'
  $adsLines = @([IO.File]::ReadAllLines($adsPath))
  $tokFind = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $adsLines.Count; $i++) {
    foreach ($x in @(Get-TcSecretFinding $adsLines[$i])) { $x | Add-Member -NotePropertyName File -NotePropertyValue 'grocery/pull-grocery-ads.ps1'; $x | Add-Member -NotePropertyName Line -NotePropertyValue ($i + 1); $tokFind.Add($x) }
  }
  $sp = Split-ScAllowed $tokFind.ToArray() $script:SC_ALLOW
  Assert-ScCase 'MUST NOT FIRE  the flyer token Brad ruled public is FOUND and ALLOWED on file + name + fingerprint' `
    ($tokFind.Count -eq 1 -and $sp.Allowed.Count -eq 1 -and $sp.New.Count -eq 0 -and $sp.Stale.Count -eq 0) ('found=' + $tokFind.Count + ' allowed=' + $sp.Allowed.Count + ' new=' + $sp.New.Count + ' stale=' + $sp.Stale.Count)

  # ---- CLEAN TWIN: the allowlist is keyed tightly enough to refuse its neighbours, and a spent entry goes STALE
  $moved = [pscustomobject]@{ File = 'grocery/other.ps1'; Line = 1; Kind = 'named-secret'; Name = 'token'; Fingerprint = $script:SC_ALLOW[0].Sha }
  $sp2 = Split-ScAllowed @($moved) $script:SC_ALLOW
  Assert-ScCase 'CLEAN TWIN     the allowed value in ANOTHER file is refused, and the unused entry is reported STALE' `
    ($sp2.New.Count -eq 1 -and $sp2.Stale.Count -eq 1) ('new=' + $sp2.New.Count + ' stale=' + $sp2.Stale.Count)
  $swapped = [pscustomobject]@{ File = 'grocery/pull-grocery-ads.ps1'; Line = 26; Kind = 'named-secret'; Name = 'token'; Fingerprint = (Get-ScFingerprint $tok) }
  $sp3 = Split-ScAllowed @($swapped) $script:SC_ALLOW
  Assert-ScCase 'CLEAN TWIN     a DIFFERENT value under the same name in the same file is refused' ($sp3.New.Count -eq 1) ('new=' + $sp3.New.Count)
  Assert-ScCase 'CLEAN TWIN     every allowlist entry carries its reason' (@($script:SC_ALLOW).Count -ge 1 -and @($script:SC_ALLOW | Where-Object { $_.Reason -match 'Brad' }).Count -eq @($script:SC_ALLOW).Count) 'an entry has no reason naming its ruling'

  # The prefilter is a SUPERSET: every planted MUST FIRE line matches at least one git grep pattern (ERE via .NET,
  # which agrees with ERE on these constructs once [[:space:]] is spelled \s).
  $planted = @($ghostLine, ('CLOUDFLARE_API_TOKEN="' + $cf + '"'), ('  "type": "service' + '_account",'), ('-----BEGIN ' + 'PRIVATE KEY-----'),
    ('https://api.nal.usda.gov/fdc/v1/foods/search?api_key=' + $fdc + '&query=onion'), ('$fdcApiKey = ''' + $fdc + ''''), ('db_password: "' + 'q8Wz3kLp' + '0vNt5rYs' + '2mHc' + '"'))
  $kept = @($planted | Where-Object { $l = $_; @($script:SC_GREP | Where-Object { $l -match ('(?i)' + ($_ -replace '\[\[:space:\]\]', '\s')) }).Count -gt 0 })
  Assert-ScCase 'CLEAN TWIN     every must-fire line survives the git grep prefilter, so the second pass can see it' ($kept.Count -eq $planted.Count -and $planted.Count -eq 7) ('kept=' + $kept.Count + ' of ' + $planted.Count)

  # The discovery, pointed at this checkout: git grep resolves and finds the allowlisted line.
  $cand = Get-ScTreeCandidate -RootFull $repo
  Assert-ScCase 'CLEAN TWIN     git grep resolves this checkout and returns the allowlisted line among its candidates' `
    ($null -ne $cand -and @($cand | Where-Object { $_.File -eq 'grocery/pull-grocery-ads.ps1' }).Count -ge 1) ('candidates=' + $(if ($null -eq $cand) { 'null' } else { @($cand).Count }))

  if ($script:cases -eq 0) { $script:fail++ }
  ''
  if ($script:fail) {
    Write-Output ('audit-secrets selftest: {0} FAILED of {1}' -f $script:fail, $script:cases)
    Exit-Guard -Name 'AUDIT-SECRETS-SELFTEST' -Code 2 -Summary ('failed={0} of {1}' -f $script:fail, $script:cases)
  }
  Write-Output ('audit-secrets selftest: {0} of {0} cases pass' -f $script:cases)
  Exit-Guard -Name 'AUDIT-SECRETS-SELFTEST' -Code 0 -Summary ('cases={0}' -f $script:cases)
}

# ------------------------------------------------------------------------------------------------- live run
$rootFull = if ($Root) { (Resolve-Path -LiteralPath $Root).ProviderPath } else { $repo }
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $inside = (& git -C $rootFull rev-parse --is-inside-work-tree); $tracked = @(& git -C $rootFull ls-files).Count } finally { $ErrorActionPreference = $prev }
if ([string]$inside -ne 'true' -or $tracked -eq 0) {
  Write-Output ('audit-secrets: BLIND - ' + $rootFull + ' is not a git work tree with tracked files')
  Exit-Guard -Name 'AUDIT-SECRETS' -Code 3 -Summary 'blind=no-work-tree'
}
$cand = Get-ScTreeCandidate -RootFull $rootFull
if ($null -eq $cand) {
  Write-Output 'audit-secrets: BLIND - git grep did not run cleanly, so the tree was not read'
  Exit-Guard -Name 'AUDIT-SECRETS' -Code 3 -Summary ('blind=git-grep-failed tracked={0}' -f $tracked)
}
$findings = New-Object System.Collections.Generic.List[object]
foreach ($c in @($cand)) {
  foreach ($x in @(Get-TcSecretFinding $c.Text)) {
    $x | Add-Member -NotePropertyName File -NotePropertyValue $c.File
    $x | Add-Member -NotePropertyName Line -NotePropertyValue $c.Line
    $findings.Add($x)
  }
}
# The commits this push would carry: their MESSAGES are published too, and no file scan reads them.
$msgCommits = 0
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try {
  $null = & git -C $rootFull rev-parse --verify --quiet 'origin/main'
  if ($LASTEXITCODE -eq 0) {
    $log = @(& git -C $rootFull log '--format=%x40%x40C %h%n%B' 'origin/main..HEAD')
    $cur = ''; $ln = 0
    foreach ($l in $log) {
      if ([string]$l -match '^@@C (\w+)$') { $cur = $Matches[1]; $ln = 0; $msgCommits++; continue }
      $ln++
      foreach ($x in @(Get-TcSecretFinding ([string]$l))) {
        $x | Add-Member -NotePropertyName File -NotePropertyValue ('commit message ' + $cur)
        $x | Add-Member -NotePropertyName Line -NotePropertyValue $ln
        $findings.Add($x)
      }
    }
  }
} finally { $ErrorActionPreference = $prev }

$split = Split-ScAllowed $findings.ToArray() $script:SC_ALLOW
Write-Output ('audit-secrets: {0} tracked file(s) read through git grep -I, {1} candidate line(s), {2} unpushed commit message(s); {3} finding(s), {4} allowlisted, {5} stale allowlist entr(y/ies)' -f $tracked, @($cand).Count, $msgCommits, $split.New.Count, $split.Allowed.Count, $split.Stale.Count)
foreach ($a in $split.Allowed) { Write-Output ('  allowed  ' + (Format-ScFinding $a)) }
foreach ($f in $split.New) { Write-Output ('  SECRET   ' + (Format-ScFinding $f)) }
foreach ($s in $split.Stale) { Write-Output ('  STALE    allowlist entry ' + $s.File + ' name=' + $s.Name + ' sha=' + $s.Sha + ' matches nothing - remove it or restore the value it permits') }
$summary = 'tracked={0} candidates={1} commits={2} findings={3} allowed={4} stale={5}' -f $tracked, @($cand).Count, $msgCommits, $split.New.Count, $split.Allowed.Count, $split.Stale.Count
if ($split.New.Count -or $split.Stale.Count) {
  if ($split.New.Count) {
    Write-Output '  A value that looks like a credential is in a tracked file or an unpushed commit message. If it is real,'
    Write-Output '  ROTATE it first (a push is not needed for it to be exposed if it was ever shared), then remove it and'
    Write-Output '  read it from the environment or a gitignored file as lib\ghost-lib.ps1 does. If it is genuinely public,'
    Write-Output '  add an allowlist entry in ops\audit-secrets.ps1 with Brad''s reason. Never bypass the push to land it.'
  }
  Exit-Guard -Name 'AUDIT-SECRETS' -Code 1 -Summary $summary
}
Exit-Guard -Name 'AUDIT-SECRETS' -Code 0 -Summary $summary
