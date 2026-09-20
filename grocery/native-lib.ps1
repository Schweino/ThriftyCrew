<#
  native-lib.ps1 - ONE safe way to run a native child and read what it said.

  THE CLASS THIS FILE EXISTS TO END. In PS 5.1, redirecting a NATIVE child's stderr
  wraps every line in an ErrorRecord (NativeCommandError). Under
  $ErrorActionPreference = 'Stop' - which every scheduled entry point in this estate
  sets - the FIRST such line is a TERMINATING error. The child is fine, its exit code
  is 0, and the CALLER dies mid-script.

  Three outages from this one shape, all in the same fortnight:
    2026-08-22  capture-run -> check-ad-cycles with 2>&1. The downstream chain did its
                whole 25-minute job and capture-run died on the child's first warning:
                no rc line, no CAPTURE-RUN-COMPLETE, exit 1.
    2026-08-22  capture-run's publish stage, `& git add ... 2>$null` on a pathspec
                matching nothing. The commit threw; the day's prices did not ship.
    2026-08-23  capture-run's push stage, `& git fetch origin main 2>$null`. git writes
                "From https://github.com/..." to STDERR on every fetch that moves a ref,
                so it threw on a COMPLETELY NORMAL fetch. Captures were green, the commit
                landed, push was never attempted, the run exited 1.

  *** THE BELIEF THAT KEEPS REINTRODUCING IT. *** check-ad-cycles.ps1 carried a comment
  reading "2>$null keeps a child stderr line from killing the cycle under EAP=Stop".
  That is backwards, and it is the whole bug. `2>$null` does not protect you from the
  terminating error - it CREATES it. Sending stderr to $null still routes it through the
  redirection machinery that mints the ErrorRecord. There is no redirect form that is
  safe under EAP=Stop. Not 2>&1, not 2>$null, not 2>somefile.

  SO THERE ARE EXACTLY TWO LEGAL SHAPES, and no third:
    1. Do not redirect at all. The child's stderr passes straight through to the
       transcript, untouched and non-fatal, and $LASTEXITCODE still reads correctly
       through a ForEach-Object pipe. Use this when you only want the child's output
       echoed into the log.
    2. Call Invoke-Native (this file). Use this when you need the child's output IN A
       VARIABLE, or when you want its stderr suppressed. It performs the redirect with
       EAP forced to 'Continue' for the duration of the call, which is the only context
       in which a redirect cannot terminate anyone, then hands back stdout, stderr and
       the real exit code as separate fields.

  test-native-stderr-eap.ps1 is the fixture for all of this, and it proves its OWN
  scanner still matches a known-bad line - because on 2026-08-23 that scanner was found
  to contain a stray U+0008 in its pattern, making it structurally unable to match
  anything. It had reported green for a day while watching nothing.
#>

function Invoke-Native {
  <#
    Runs a native command (or a powershell child) and returns:
      .Output    [string[]]  the child's stdout, one line per element
      .Error     [string[]]  the child's stderr, one line per element
      .Lines     [string[]]  Output + Error, in the order they arrived
      .ExitCode  [int]       the child's real exit code
    It NEVER throws on child stderr and NEVER throws on a non-zero exit code -
    callers decide what a failure means by reading .ExitCode.
  #>
  # *** NO param() BLOCK, AND THAT ABSENCE IS LOAD-BEARING (2026-09-20). ***
  # This used to declare [string]$Command plus a ValueFromRemainingArguments $Arguments, and
  # PowerShell matches a parameter name by any unambiguous PREFIX. So a native flag that is a
  # prefix of "Command" was never an argument at all - the BINDER took it:
  #     Invoke-Native git -C $repo -c rebase.autoStash=true rebase -X theirs origin/main
  # bound -C to -Command, then hit -c and threw "Cannot bind parameter because parameter
  # 'Command' is specified more than once". The throw happens at BINDING time, before one line
  # of this function runs, so nothing inside could have caught it. It killed capture-run's push
  # stage on 2026-09-20 (grocery\out\logs\capture-run-ad-2026-09-20.log): the day's prices were
  # committed and never pushed, and the run exited 1 - the same shape as the three 2026-08 outages
  # this file was written to end, one layer up. `git -C <dir>` is the commonest git form there is.
  # With no param() block the binder declares nothing, so EVERY token arrives in $args verbatim
  # and no flag of any child can be stolen. Quoting the flag at the call site fixes one call;
  # this fixes every call that will ever be written.
  # Named-form callers would now break, so they are refused LOUDLY rather than silently mis-read.
  # Census at this commit over grocery\, ops\, lib\, meal-prep\: zero named-form call sites.
  if ($args.Count -eq 0) { throw 'Invoke-Native needs a command: Invoke-Native <command> [args...]' }
  if (([string]$args[0]) -eq '-Command' -or ([string]$args[0]) -eq '-Arguments') {
    throw ('Invoke-Native takes its command POSITIONALLY (Invoke-Native <command> [args...]); ' +
           'the -Command/-Arguments parameters were removed so a child flag like git -C can never bind to them.')
  }
  $Command = [string]$args[0]
  $Arguments = @(if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() })
  # THE ENTIRE POINT OF THIS FUNCTION IS THIS ONE ASSIGNMENT. EAP is scoped, so setting
  # it here makes the redirect below non-terminating no matter what the caller set, and
  # the finally restores the caller's value even if the child crashes the runspace.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $raw = @()
  $rc = $null
  try {
    $raw = & $Command @Arguments 2>&1
    $rc = $LASTEXITCODE
  } catch {
    # A MISTYPED COMMAND MUST NOT KILL A SCHEDULED RUN. CommandNotFoundException is a
    # caller bug, not child stderr, so it escapes the EAP='Continue' above and would
    # terminate the pipeline exactly like the class this file exists to end. Report it
    # as rc=-1 with the message in .Error so it is LOUD but not fatal - every caller
    # already branches on ExitCode, and -1 matches no success path.
    $ErrorActionPreference = $prev
    return [pscustomobject]@{
      Output   = @()
      Error    = @('Invoke-Native could not start ' + $Command + ': ' + $_.Exception.Message)
      Lines    = @('Invoke-Native could not start ' + $Command + ': ' + $_.Exception.Message)
      ExitCode = -1
    }
  } finally {
    $ErrorActionPreference = $prev
  }
  $out = New-Object System.Collections.ArrayList
  $err = New-Object System.Collections.ArrayList
  $all = New-Object System.Collections.ArrayList
  foreach ($r in @($raw)) {
    if ($null -eq $r) { continue }
    $s = [string]$r
    # An ErrorRecord here is a stderr line, not a failure of ours - NativeCommandError
    # wraps them one per line. Anything else is real stdout.
    if ($r -is [System.Management.Automation.ErrorRecord]) { [void]$err.Add($s) } else { [void]$out.Add($s) }
    [void]$all.Add($s)
  }
  return [pscustomobject]@{
    Output   = @($out.ToArray())
    Error    = @($err.ToArray())
    Lines    = @($all.ToArray())
    ExitCode = $(if ($null -eq $rc) { -1 } else { [int]$rc })
  }
}

function Invoke-NativeScript {
  <#
    The common case in this estate: run a .ps1 as a fresh powershell child and read it
    back. Same contract as Invoke-Native.
  #>
  # No param() block, for the reason Invoke-Native's own comment gives: [string]$Path would be
  # bound by any unambiguous prefix, so an unquoted child flag -P / -Pa / -Pat / -Path would be
  # eaten by the binder instead of reaching the script being run.
  if ($args.Count -eq 0) { throw 'Invoke-NativeScript needs a script path: Invoke-NativeScript <path> [args...]' }
  if (([string]$args[0]) -eq '-Path' -or ([string]$args[0]) -eq '-Arguments') {
    throw 'Invoke-NativeScript takes its script path POSITIONALLY (Invoke-NativeScript <path> [args...]).'
  }
  $Path = [string]$args[0]
  $rest = @(if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() })
  $argv = @('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $rest
  return Invoke-Native @argv
}
