<#
  push-landable.ps1 - can this push still land? A push that cannot is refused before its gate runs, not after.

  Dot-source:  . (Join-Path $repoRoot 'lib\push-landable.ps1')
  Self-test:   powershell -File lib\push-landable.ps1 -SelfTest

  WHY (2026-09-11). git fixes a push's refs when it connects. The pre-push hook is handed each ref's remote sha on
  stdin, and after the hook exits the remote updates a ref only if it STILL holds that sha. So when the remote
  moves while the hook runs, the push is rejected however the gate came out, and that day the gate was the slow
  part: pushes waited up to 1,010 s for a gate worker slot and then ran at width 1 for 1,046 to 1,864 s
  (design\MEASURE-gate-slot-starvation-2026-09-11.md). 34 session scratch files that day carry a push to main
  rejected because main had moved. That is not a count of wasted gates - a stdout and stderr pair can be one push,
  and a fetch-first rejection comes before the hook - but every rejection after a gate was a slot held for a
  verdict its session could not use.

  THE RULE (Get-TcDoomedPushReason). A push can still land while at least ONE ref it updates still holds, on the
  remote, the sha the hook was given; a ref the remote does not have holds the all-zero sha. When none does, every
  ref would be rejected, and the reason names each moved ref. Deletions carry no code and are skipped, as the hook
  skips them.

  A COULD-NOT-LOOK IS NEVER A REFUSAL. ls-remote failing - no network, a credential prompt, no answer within its
  timeout - answers '' and the gate runs as it always did. Refusing there would block pushes over a network blip,
  and running the gate is the direction that cannot let anything through ungated.

  A REFUSAL IS NOT A PASS. ops\run-gates.ps1 turns one into exit 3, and the hook refuses the push loudly.

  SCOPE OF A CLEAN REPORT: '' proves only that one ref still matched, or that the remote could not be read, at the
  moment of the check. The remote can move a second later, and its own compare-and-swap still rejects that push.
  The self-test drives the rule over fixed ref lines and over a real bare repository in a per-run temp directory.

  NO param() BLOCK: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope (lib\guard-contract.ps1).
#>
$__plSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-TcPushRefUpdates {
  <# The hook's stdin lines, "<local ref> <local sha> <remote ref> <remote sha>", as objects. A deletion (an all-zero
     local sha) and any line that is not four fields with two shas are dropped. Returns an array: assign, then wrap. #>
  param([string[]]$Lines)
  $out = [Collections.Generic.List[object]]::new()
  foreach ($ln in @($Lines)) {
    $parts = @(([string]$ln).Trim() -split '\s+')
    if ($parts.Count -ne 4) { continue }
    if ($parts[1] -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$' -or $parts[3] -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { continue }
    if ($parts[1] -match '^0+$') { continue }
    $out.Add([pscustomobject]@{ LocalRef = $parts[0]; LocalSha = $parts[1]; RemoteRef = $parts[2]; ExpectedSha = $parts[3] })
  }
  return ,$out.ToArray()
}

function Get-TcRemoteRefs {
  <# git ls-remote for the named refs: a hashtable of ref -> sha, where a ref the remote does not have is absent. $null
     when it could not look - git missing, a non-zero exit, or no answer within TimeoutSec. Never prompts. #>
  param([string]$Remote, [string[]]$Refs, [string]$WorkingDirectory = '', [int]$TimeoutSec = 30)
  if (-not $Remote -or $Remote.StartsWith('-')) { return $null }
  $p = $null
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $argv = @('ls-remote', $Remote) + @($Refs | Where-Object { $_ })
    $psi.Arguments = (@($argv | ForEach-Object { if ([string]$_ -match '[\s"]') { '"' + ([string]$_ -replace '"', '\"') + '"' } else { [string]$_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $p = [Diagnostics.Process]::Start($psi)
    # BOTH STREAMS ARE READ BEFORE THE WAIT, or a child that fills a pipe blocks while this blocks on its exit.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $null = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill() } catch { }
      return $null
    }
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { return $null }
    $map = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($line in ([string]$outTask.Result -split "`n")) {
      $l = $line.Trim()
      if ($l -match '^([0-9a-f]{40}(?:[0-9a-f]{24})?)\s+(\S+)$') { $map[$Matches[2]] = $Matches[1] }
    }
    return $map
  } catch {
    return $null
  } finally {
    if ($p) { $p.Dispose() }
  }
}

function Get-TcDoomedPushReason {
  <# '' when at least one ref this push updates can still land; a sentence naming every moved ref when none can.
     A $null RemoteRefs means the remote could not be read, and that is '' too. #>
  param([object[]]$Updates, [hashtable]$RemoteRefs)
  if ($null -eq $RemoteRefs) { return '' }
  $u = @($Updates | Where-Object { $_ })
  if ($u.Count -eq 0) { return '' }
  $moved = @()
  foreach ($x in $u) {
    $zero = '0' * ([string]$x.ExpectedSha).Length
    $now = if ($RemoteRefs.ContainsKey([string]$x.RemoteRef)) { [string]$RemoteRefs[[string]$x.RemoteRef] } else { $zero }
    if ([string]::Equals($now, [string]$x.ExpectedSha, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    $moved += ('{0} moved from {1} to {2}' -f $x.RemoteRef, ([string]$x.ExpectedSha).Substring(0, 9), $now.Substring(0, [Math]::Min(9, $now.Length)))
  }
  return ('the remote no longer holds what this push was built on: ' + ($moved -join '; '))
}

function Get-TcPushCannotLandReason {
  <# The whole check for a hook's refs file: '' when the push can still land or the answer is unknown. #>
  param([string]$RefsFile, [string]$Remote, [string]$WorkingDirectory = '', [int]$TimeoutSec = 30)
  if (-not $RefsFile -or -not [IO.File]::Exists($RefsFile)) { return '' }
  $lines = [IO.File]::ReadAllLines($RefsFile)
  $updates = Get-TcPushRefUpdates -Lines $lines
  $updates = @($updates)
  if ($updates.Count -eq 0) { return '' }
  $names = @($updates | ForEach-Object { [string]$_.RemoteRef } | Select-Object -Unique)
  $remoteRefs = Get-TcRemoteRefs -Remote $Remote -Refs $names -WorkingDirectory $WorkingDirectory -TimeoutSec $TimeoutSec
  return (Get-TcDoomedPushReason -Updates $updates -RemoteRefs $remoteRefs)
}

if ($__plSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:plCases = 0; $script:plFail = 0
  function Check([string]$Label, [bool]$Ok, [string]$Got = '') {
    $script:plCases++
    if ($Ok) { Write-Output ('ok    ' + $Label) } else { Write-Output ('FAIL  ' + $Label + '   got: ' + $Got); $script:plFail++ }
  }
  function Invoke-SandboxGit {
    $ErrorActionPreference = 'Continue'
    $o = & git @args 2>$null
    return [pscustomobject]@{ Rc = $LASTEXITCODE; Out = ((@($o) -join "`n").Trim()) }
  }
  $sb = Join-Path $env:TEMP ('tc-pl-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  try {
    # ---- the rule over fixed ref lines ----
    $z = '0' * 40; $a = 'a' * 40; $b = 'b' * 40; $c = 'c' * 40
    $u = Get-TcPushRefUpdates -Lines @("HEAD $a refs/heads/main $b", "refs/heads/gone $z refs/heads/gone $c", 'not a ref line')
    $u = @($u)
    Check 'CLEAN TWIN  the hook''s ref lines parse into one update, with the deletion and the malformed line dropped' `
      ($u.Count -eq 1 -and $u[0].RemoteRef -eq 'refs/heads/main' -and $u[0].ExpectedSha -eq $b) ("count={0}" -f $u.Count)
    $r = Get-TcDoomedPushReason -Updates $u -RemoteRefs @{ 'refs/heads/main' = $c }
    Check 'MUST FIRE  the only ref this push updates has moved on the remote: refused, naming the ref' `
      ($r.Contains('refs/heads/main moved from ' + $b.Substring(0, 9))) $r
    $r = Get-TcDoomedPushReason -Updates $u -RemoteRefs @{ 'refs/heads/main' = $b }
    Check 'MUST NOT FIRE  the ref still holds the sha the push was built on: not refused' ($r -eq '') $r
    $two = Get-TcPushRefUpdates -Lines @("HEAD $a refs/heads/main $b", "HEAD $a refs/heads/side $z")
    $r = Get-TcDoomedPushReason -Updates $two -RemoteRefs @{ 'refs/heads/main' = $c }
    Check 'MUST NOT FIRE  one ref moved and another can still land: not refused, because git would still land that one' ($r -eq '') $r
    $created = Get-TcPushRefUpdates -Lines @("HEAD $a refs/heads/side $z")
    $r = Get-TcDoomedPushReason -Updates $created -RemoteRefs @{ 'refs/heads/side' = $c }
    Check 'MUST FIRE  a NEW branch the remote has since been given is refused - a ref the remote lacks holds the zero sha' ($r -ne '') $r
    $deleteOnly = Get-TcPushRefUpdates -Lines @("(delete) $z refs/heads/side $c")
    $r = Get-TcDoomedPushReason -Updates $deleteOnly -RemoteRefs @{}
    Check 'MUST NOT FIRE  a push that only deletes is never refused here' ($r -eq '') $r
    $r = Get-TcDoomedPushReason -Updates $u -RemoteRefs $null
    Check 'MUST NOT FIRE  a remote that could not be read refuses nothing - a could-not-look is not a verdict' ($r -eq '') $r

    # ---- a real bare remote, driven through git ----
    $null = New-Item -ItemType Directory -Path $sb -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'git-repo-env.ps1')
    Clear-TcGitRepoEnv
    $bare = Join-Path $sb 'remote.git'
    $work = Join-Path $sb 'work'
    $null = Invoke-SandboxGit init -q --bare $bare
    $null = Invoke-SandboxGit init -q $work
    $null = Invoke-SandboxGit -C $work config user.email t@t
    $null = Invoke-SandboxGit -C $work config user.name t
    $null = Invoke-SandboxGit -C $work config commit.gpgsign false
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $work 'a.txt'), "one`n", $utf8)
    $null = Invoke-SandboxGit -C $work add a.txt
    $null = Invoke-SandboxGit -C $work commit -q -m one
    $sha1 = (Invoke-SandboxGit -C $work rev-parse HEAD).Out
    $null = Invoke-SandboxGit -C $work push -q $bare HEAD:refs/heads/main
    $seen = Get-TcRemoteRefs -Remote $bare -Refs @('refs/heads/main') -WorkingDirectory $sb
    Check 'CLEAN TWIN  a real ls-remote reads the sha the remote holds' ($null -ne $seen -and $sha1.Length -eq 40 -and $seen['refs/heads/main'] -eq $sha1) ("sha1={0} seen={1}" -f $sha1, $(if ($seen) { $seen['refs/heads/main'] } else { 'null' }))
    [IO.File]::WriteAllText((Join-Path $work 'a.txt'), "two`n", $utf8)
    $null = Invoke-SandboxGit -C $work commit -q -am two
    $sha2 = (Invoke-SandboxGit -C $work rev-parse HEAD).Out
    $refsFile = Join-Path $sb 'refs.txt'
    [IO.File]::WriteAllText($refsFile, ("HEAD {0} refs/heads/main {1}`n" -f $sha2, $sha1), $utf8)
    $r = Get-TcPushCannotLandReason -RefsFile $refsFile -Remote $bare -WorkingDirectory $sb
    Check 'MUST NOT FIRE  a push built on what the real remote still holds is not refused' ($r -eq '') $r
    # Another session's push lands first: the remote's main moves to sha2, and a push still built on sha1 is doomed.
    $null = Invoke-SandboxGit -C $work push -q $bare HEAD:refs/heads/main
    [IO.File]::WriteAllText((Join-Path $work 'a.txt'), "three`n", $utf8)
    $null = Invoke-SandboxGit -C $work commit -q -am three
    $sha3 = (Invoke-SandboxGit -C $work rev-parse HEAD).Out
    [IO.File]::WriteAllText($refsFile, ("HEAD {0} refs/heads/main {1}`n" -f $sha3, $sha1), $utf8)
    $r = Get-TcPushCannotLandReason -RefsFile $refsFile -Remote $bare -WorkingDirectory $sb
    Check 'MUST FIRE  THE ONE THIS EXISTS FOR - once another push lands on the real remote, a push built on the old main is refused before any gate runs' `
      ($r.Contains('refs/heads/main moved from ' + $sha1.Substring(0, 9) + ' to ' + $sha2.Substring(0, 9))) $r
    $gone = Join-Path $sb 'no-such-remote.git'
    $m = Get-TcRemoteRefs -Remote $gone -Refs @('refs/heads/main') -WorkingDirectory $sb
    $r = Get-TcPushCannotLandReason -RefsFile $refsFile -Remote $gone -WorkingDirectory $sb
    Check 'MUST NOT FIRE  a real remote that cannot be reached answers could-not-look and refuses nothing' ($null -eq $m -and $r -eq '') ("map={0} reason={1}" -f ($null -ne $m), $r)
  } catch {
    $script:plFail++
    Write-Output ('FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:plCases -lt 11) { $script:plFail++; Write-Output ('FAIL  only {0} of 11 cases ran' -f $script:plCases) }
  if ($script:plFail) { Write-Output ('push-landable SELF-TEST FAIL: {0} failure(s) over {1} case(s)' -f $script:plFail, $script:plCases); exit 1 }
  Write-Output ('push-landable SELF-TEST PASS: {0} cases - led by a push built on a main that another push has since moved being refused against a real remote, and a remote that cannot be read refusing nothing' -f $script:plCases)
  exit 0
}
