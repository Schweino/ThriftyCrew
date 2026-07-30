<#
  coverage-lib.ps1 - THE COVERAGE LEDGER emitter. One shared way for a check to say, on the record and
  across runs, HOW MUCH IT ACTUALLY LOOKED AT.

  WHY THIS EXISTS. The estate's dominant silent failure is not a wrong answer, it is a confident answer
  about nothing:
    - guard 11 reconciled Baker's against a raw capture, its row filter stopped matching when Baker's moved
      to the Kroger API, and it printed "ok ... (0 pack=our-size rows checked)" for FIVE DAYS on the board's
      largest store;
    - guard 3's WRONG-PRODUCT clause examined 0 of 16 pins because its producer read one board and the pins
      all live on the other, while the ok line beside it said "16 checked";
    - audit-ff-carry threw on its own report line before printing anything, so the Family Fare pull-drop
      watch was decorative for 17 days and 'ff-carry' appears ZERO times in 2,716 lines of ad-cycle-log.txt.
  Every one of those was invisible for the same reason: "no violations found" and "nothing examined" print
  the same zero, and nothing anywhere remembered yesterday's number.

  guards.ps1's OkUnlessBlind already forces those apart WITHIN A SINGLE RUN. It cannot see two things:
    (a) a check that DID NOT RUN AT ALL leaves no output to inspect - absence is not a zero;
    (b) a PARTIAL collapse. A check that fell from 2,435 rows to 400 is not blind, it is 84% blind, and
        every in-run test in this tree reads that as a pass.
  A ledger fixes both, because it is a number that persists and can be compared to the number before it.

  CONTRACT
    Write-CoverageRecord -Check <name> -Eligible <n> -Examined <n> [-Skipped <n>] [-Blind] [-Detail <s>]
                         [-OutDir <path>]
    writes/updates one row in <OutDir>\coverage-ledger.json:
      { eligible, examined, skipped, blind, as_of, detail }
    ELIGIBLE  the denominator the check could honestly state. A check with no honest denominator passes
              eligible = examined and says so in -Detail. NEVER inflate it: an eligible number nobody
              measured is the same lie in the other direction.
    EXAMINED  rows the check formed an actual VERDICT about - counted PAST every silent `continue`, not
              the number it looped over. That distinction is the whole point.
    BLIND     derived (examined <= 0) or forced with -Blind. A check that knows it proved nothing says so.

  DESIGN RULES THIS FILE OBEYS, each one a bug this estate has already paid for:
    NO param() BLOCK AT FILE LEVEL. A param() in a dot-sourced lib runs in the CALLER's scope and rewrites
      the caller's variables. Everything here is a function; nothing is assigned at file level, so dot-
      sourcing this file cannot change one variable in guards.ps1.
    IT CANNOT THROW INTO ITS CALLER. guards.ps1 runs under $ErrorActionPreference='Stop'; a logger that
      throws takes the whole publish down, and this estate has already lost a run to exactly that (a locked
      log file under EAP=Stop killed a pipeline and read as a hang). Every path is wrapped, and the caller
      gets nothing back.
    ITS FAILURE IS NOT SILENT, EVEN THOUGH ITS CATCH IS EMPTY. This is the one place a bare catch is
      defensible: if the write fails, the ROW IS MISSING, and a missing row is precisely what
      audit-coverage-ledger.ps1 reports as a finding. The failure surfaces where it can be acted on
      instead of on stderr - which matters, because several harnesses here pipe a native child with 2>&1
      under EAP=Stop, where one stderr line becomes a TERMINATING throw in the parent.
    IT WRITES NOTHING TO THE OUTPUT STREAM. Write-Output inside a function pollutes the function's return
      value, and several callers here match on their own stdout.
    THE WRITE IS ATOMIC. '' | ConvertFrom-Json returns $null WITHOUT throwing in PS 5.1, so a half-written
      ledger read by the auditor would look like an empty-but-valid ledger. Write a temp file, then move.
    IT READS UTF-8 EXPLICITLY. Bare Get-Content reads ANSI in this tree, and ([string]$null).Trim() throws
      on a zero-byte file - hence the (( ... ) + '').Trim() idiom below.
#>

function Get-CoverageLedgerPath {
  <# The ONE definition of where the ledger lives. $PSScriptRoot inside a function resolves to the file
     that DEFINED the function (verified in PS 5.1 under dot-sourcing), not the caller's directory. #>
  param([string]$OutDir = '')
  if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
  return (Join-Path $OutDir 'coverage-ledger.json')
}

function Read-CoverageJson {
  <# The ONE definition of how a coverage file is read, shared by the emitter and the auditor so they can
     never disagree about what "unreadable" means. Returns $null for every not-usable case - missing,
     zero-byte, whitespace, malformed, or the PS 5.1 '' -> $null-without-throwing case. The CALLER must
     treat $null as could-not-evaluate, never as empty-and-therefore-clean. #>
  param([string]$Path)
  if (-not $Path) { return $null }
  if (-not (Test-Path $Path)) { return $null }
  $txt = ''
  try { $txt = ((([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)) + '')).Trim() } catch { return $null }
  if (-not $txt) { return $null }
  $doc = $null
  try { $doc = $txt | ConvertFrom-Json } catch { return $null }
  if ($null -eq $doc) { return $null }
  return $doc
}

function Write-CoverageRecord {
  param(
    [string]$Check,
    [int]$Eligible = -1,
    [int]$Examined = -1,
    [int]$Skipped  = -1,
    [string]$Detail = '',
    [string]$OutDir = '',
    [switch]$Blind
  )
  # Function-scoped: this does NOT change the caller's preference.
  $ErrorActionPreference = 'Stop'
  try {
    if (-not $Check) { return }
    if ($Examined -lt 0) { $Examined = 0 }
    if ($Eligible -lt 0) { $Eligible = $Examined }
    if ($Skipped  -lt 0) { $Skipped  = [math]::Max(0, $Eligible - $Examined) }
    $isBlind = $true
    if ((-not $Blind.IsPresent) -and ($Examined -gt 0)) { $isBlind = $false }

    $path = Get-CoverageLedgerPath $OutDir
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $stamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $enc = New-Object Text.UTF8Encoding($false)

    for ($attempt = 1; $attempt -le 6; $attempt++) {
      $tmp = ''
      try {
        $keep = @{}
        $old = Read-CoverageJson $path
        if ($old -and $old.PSObject.Properties['checks'] -and $old.checks) {
          foreach ($p in $old.checks.PSObject.Properties) {
            if ([string]$p.Name -ne $Check) { $keep[[string]$p.Name] = $p.Value }
          }
        }
        $keep[$Check] = [ordered]@{
          eligible = $Eligible
          examined = $Examined
          skipped  = $Skipped
          blind    = $isBlind
          as_of    = $stamp
          detail   = $Detail
        }
        # sorted keys: a ledger that reorders itself every run is a ledger nobody can diff
        $checks = [ordered]@{}
        foreach ($k in ($keep.Keys | Sort-Object)) { $checks[[string]$k] = $keep[$k] }
        $doc = [ordered]@{ schema = 1; updated = $stamp; checks = $checks }
        $tmp = $path + '.' + $PID + '.tmp'
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 6), $enc)
        Move-Item -LiteralPath $tmp -Destination $path -Force
        return
      } catch {
        if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 150
      }
    }
  } catch { }
  return
}

