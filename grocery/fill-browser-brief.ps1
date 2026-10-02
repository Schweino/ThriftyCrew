<#
  fill-browser-brief.ps1 - write one store agent's brief for the morning browser refresh, from the committed templates.

  WHY (2026-10-02, design\PLAN-browser-refresh-hardening-2026-10-02.md W4). The orchestrator composed each store
  agent's brief from the task file's prose every morning, and a re-composed brief is a brief that can be composed
  wrong: on 2026-10-02 it told all four agents to post into a hidden iframe, and 8 of 8 posts failed. The templates
  under grocery\browser-briefs\ carry the method (the inject wrapper, the store assertion, start, wait, finish, the
  report shape); this script fills in only what changes per day and per tab, and refuses a brief it could not fill.

  WHAT IT FILLS, AND FROM WHERE. Nothing here is typed by hand:
    {{STORE}} {{DATE}} {{TABID}} {{SINK}}     the store's label, the date, the tab the orchestrator created, the sink name
    {{TERMS}} {{COMMS}} {{N_TERMS}}           the worklist's own parallel arrays (out\worklists\capture-<key>-<date>.json)
    {{FIRST_TERM_URL}}                        the first term, URL-escaped (Fareway opens its search page on it)
    {{GROCERY}}                               THIS script's directory, so the files an agent is told to Read are the
                                              files the lengths below were measured from, by construction
    {{LEN:<file>}}                            the length the inject wrapper must measure for that pasted file: its text
                                              with line feeds trimmed off both ends, exactly what the wrapper's seg()
                                              measures. A file holding a CR is REFUSED: the Read tool and the paste would
                                              not agree with any number this could print.

  REFUSES (exit 1, nothing written): an unknown store, no worklist, an empty one, terms and commodities that are not
  parallel, a CR in a pasted file, and any {{...}} left after the fill.

    powershell -NoProfile -File grocery\fill-browser-brief.ps1 -Store walmart -TabId 123456 [-Date 2026-10-02] [-Out <file>]
    powershell -NoProfile -File grocery\fill-browser-brief.ps1 -SelfTest
  Stores: walmart, sams, aldi, fareway. Without -Out the brief is printed.
#>
# Self-test: fills every committed template from a temp worklist and runs each filled inject wrapper in node with the real files pasted in; reads the templates and the pasted scripts.
# gate-inputs: grocery\fill-browser-brief.ps1, grocery\browser-briefs\_common.md, grocery\browser-briefs\walmart.md, grocery\browser-briefs\sams.md, grocery\browser-briefs\aldi.md, grocery\browser-briefs\fareway.md, grocery\pull-agent-lib.js, grocery\pull-walmart-instore.js, grocery\pull-sams-instore.js, grocery\pull-aldi-instore.js, grocery\pull-fareway-instore.js, grocery\pull-fareway-shop.js
[CmdletBinding()]
param(
    [string] $Store = '',
    [string] $TabId = '',
    [string] $Date = '',
    [string] $Worklist = '',
    [string] $Sink = '',
    [string] $Out = '',
    # Test seams: where the templates and the pasted scripts are read from. Default: this script's own directory.
    [string] $TemplateDir = '',
    [string] $ScriptDir = '',
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Get-BriefStore {
    param([string] $Name)
    switch ($Name.ToLowerInvariant()) {
        'walmart' { return @{ key = 'walmart';  label = 'Walmart';    template = 'walmart.md'; sink = 'walmart-capture-{0}' } }
        'sams'    { return @{ key = 'samsclub'; label = "Sam's Club"; template = 'sams.md';    sink = 'sams-capture-{0}' } }
        'aldi'    { return @{ key = 'aldi';     label = 'Aldi';       template = 'aldi.md';    sink = 'aldi-capture-{0}' } }
        'fareway' { return @{ key = 'fareway';  label = 'Fareway';    template = 'fareway.md'; sink = 'fareway-shop-{0}' } }
        default   { throw "unknown store: '$Name' (walmart, sams, aldi or fareway)" }
    }
}

# The length the inject wrapper's seg() measures for a pasted file: line feeds trimmed off both ends.
function Get-PasteLength {
    param([string] $Path)
    $t = [IO.File]::ReadAllText($Path)
    if ($t.Contains("`r")) { throw ("$Path holds a CR: the checkout is CRLF, so no printed length would match the paste. " +
                                    'Fill the brief from an LF checkout.') }
    return $t.Trim("`n").Length
}

function New-BrowserBrief {
    param([string] $Store, [string] $TabId, [string] $Date, [string] $Worklist, [string] $Sink,
          [string] $TemplateDir, [string] $ScriptDir)
    $s = Get-BriefStore $Store
    if (-not $TabId) { throw 'no -TabId: the orchestrator creates the tab and passes its id' }
    if (-not (Test-Path -LiteralPath $Worklist)) { throw "no worklist at $Worklist (run capture-policy.ps1 -Emit first)" }
    $wl = ConvertFrom-Json ([IO.File]::ReadAllText($Worklist))
    $terms = @($wl.terms | ForEach-Object { [string]$_ })
    $comms = @($wl.commodities | ForEach-Object { [string]$_ })
    if ($terms.Count -eq 0) { throw "the worklist $Worklist has no terms" }
    if ($terms.Count -ne $comms.Count) { throw ("terms ($($terms.Count)) and commodities ($($comms.Count)) in $Worklist are not parallel arrays") }
    if (-not $Sink) { $Sink = $s.sink -f $Date }

    $text = [IO.File]::ReadAllText((Join-Path $TemplateDir '_common.md')) + [IO.File]::ReadAllText((Join-Path $TemplateDir $s.template))
    $text = [regex]::Replace($text, '(?s)<!--.*?-->\n?', '')   # the templates' notes are for their maintainers, not the agent
    $text = [regex]::Replace($text, '\{\{LEN:([A-Za-z0-9._-]+)\}\}', {
        param($m) [string](Get-PasteLength (Join-Path $ScriptDir $m.Groups[1].Value)) })
    $fill = [ordered]@{
        STORE = $s.label; DATE = $Date; TABID = $TabId; SINK = $Sink; GROCERY = $ScriptDir
        TERMS = (ConvertTo-Json -InputObject @($terms) -Compress); COMMS = (ConvertTo-Json -InputObject @($comms) -Compress)
        N_TERMS = [string]$terms.Count; FIRST_TERM_URL = [uri]::EscapeDataString($terms[0])
    }
    foreach ($k in $fill.Keys) { $text = $text.Replace('{{' + $k + '}}', [string]$fill[$k]) }
    $left = @([regex]::Matches($text, '\{\{[^}]*\}\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($left.Count) { throw ('the brief still holds unfilled placeholder(s): ' + ($left -join ', ')) }
    return $text.Replace("`r`n", "`n")
}

if ($SelfTest) {
    $fail = 0; $ran = 0
    function Check([string] $Label, [bool] $Ok, [string] $Got) {
        $script:ran++
        if ($Ok) { Write-Output ('ok    ' + $Label) } else { Write-Output ('FAIL  ' + $Label + '   got: ' + $Got); $script:fail++ }
    }
    function Find-Node {
        $c = Get-Command node -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        foreach ($d in @(Get-ChildItem 'C:\Codex' -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue)) {
            $p = Join-Path $d.FullName 'node.exe'; if (Test-Path -LiteralPath $p) { return $p }
        }
        foreach ($d in @(Get-ChildItem 'C:\Codex\tools' -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue)) {
            $p = Join-Path $d.FullName 'node.exe'; if (Test-Path -LiteralPath $p) { return $p }
        }
        return $null
    }
    $tpl = Join-Path $here 'browser-briefs'
    $tmp = Join-Path $env:TEMP ('fbb-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $blind = 0
    try {
        New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
        $u8 = New-Object Text.UTF8Encoding($false)
        $wlPath = Join-Path $tmp 'wl.json'
        $odd = 'Sam' + [char]39 + 's "best" ' + [char]0x00E9 + 'clair'
        [IO.File]::WriteAllText($wlPath, (@{ terms = @('whole milk', $odd); commodities = @('milk', 'eclair') } | ConvertTo-Json), $u8)

        # CLEAN TWIN: every committed template fills completely, and its TERMS and lengths are the real ones.
        foreach ($st in 'walmart', 'sams', 'aldi', 'fareway') {
            $b = $null; $err = ''
            try { $b = New-BrowserBrief -Store $st -TabId '4242' -Date '2026-10-02' -Worklist $wlPath -Sink '' -TemplateDir $tpl -ScriptDir $here } catch { $err = $_.Exception.Message }
            $tl = if ($b) { [regex]::Match($b, '(?m)^const TERMS = (.+);$') } else { $null }
            $back = @(); if ($tl -and $tl.Success) { $bk = ConvertFrom-Json $tl.Groups[1].Value; $back = @($bk) }
            $libLen = ([IO.File]::ReadAllText((Join-Path $here 'pull-agent-lib.js'))).Length - 1
            Check ("CLEAN TWIN  $st fills completely: tab, sink name, the terms round-trip (apostrophe, quote, accent), the lib length is the file's length minus its final LF") (
                $b -and $b.Contains('tabId: 4242') -and $b.Contains("-2026-10-02'") -and $back.Count -eq 2 -and
                [string]::Equals([string]$back[1], $odd, [StringComparison]::Ordinal) -and $b.Contains('lib: ' + $libLen + ',')) ($err + ' terms=' + ($back -join ' / '))
        }

        # MUST FIRE: the refusals.
        $bad = Join-Path $tmp 'bad.json'
        [IO.File]::WriteAllText($bad, (@{ terms = @('a', 'b'); commodities = @('a') } | ConvertTo-Json), $u8)
        $e = ''; try { New-BrowserBrief -Store 'walmart' -TabId '1' -Date 'd' -Worklist $bad -Sink '' -TemplateDir $tpl -ScriptDir $here | Out-Null } catch { $e = $_.Exception.Message }
        Check 'MUST FIRE  terms and commodities that are not parallel are refused' ($e -like '*not parallel*') $e
        $e = ''; try { Get-BriefStore 'costco' | Out-Null } catch { $e = $_.Exception.Message }
        Check 'MUST FIRE  an unknown store is refused, never defaulted' ($e -like 'unknown store*') $e
        $tdir = Join-Path $tmp 'tpl'; New-Item -ItemType Directory -Path $tdir -ErrorAction Stop | Out-Null
        [IO.File]::WriteAllText((Join-Path $tdir '_common.md'), "# {{STORE}}`n", $u8)
        [IO.File]::WriteAllText((Join-Path $tdir 'walmart.md'), ('tab {{TABID}} ' + '{{' + 'BOGUS}}' + "`n"), $u8)
        $e = ''; try { New-BrowserBrief -Store 'walmart' -TabId '1' -Date 'd' -Worklist $wlPath -Sink '' -TemplateDir $tdir -ScriptDir $here | Out-Null } catch { $e = $_.Exception.Message }
        Check 'MUST FIRE  a placeholder the fill does not know is refused, not shipped' ($e -like '*unfilled placeholder*BOGUS*') $e
        $sdir = Join-Path $tmp 'js'; New-Item -ItemType Directory -Path $sdir -ErrorAction Stop | Out-Null
        [IO.File]::WriteAllText((Join-Path $sdir 'pull-agent-lib.js'), "const a = 1;`r`n", $u8)
        [IO.File]::WriteAllText((Join-Path $tdir 'walmart.md'), ('{{' + 'LEN:pull-agent-lib.js}}' + "`n"), $u8)
        $e = ''; try { New-BrowserBrief -Store 'walmart' -TabId '1' -Date 'd' -Worklist $wlPath -Sink '' -TemplateDir $tdir -ScriptDir $sdir | Out-Null } catch { $e = $_.Exception.Message }
        Check 'MUST FIRE  a pasted file holding a CR is refused (a CRLF checkout cannot be measured)' ($e -like '*holds a CR*') $e
        [IO.File]::WriteAllText((Join-Path $sdir 'pull-agent-lib.js'), "`nconst a = 1;`n`n", $u8)
        $b2 = New-BrowserBrief -Store 'walmart' -TabId '1' -Date 'd' -Worklist $wlPath -Sink '' -TemplateDir $tdir -ScriptDir $sdir
        Check 'CLEAN TWIN  the length trims line feeds off both ends and nothing else (12 for "const a = 1;")' ($b2 -match '(?m)^12$') $b2

        # END TO END, in node: each filled wrapper with the REAL files pasted in exactly as an agent would. The
        # wrapper's own seg() must measure what the fill printed (MUST NOT FIRE its refusal), and one deleted
        # comment must trip it (MUST FIRE). The assert-and-start tail is cut at its first line, because it needs a
        # store page; the measurement above it is the template's own text.
        $node = Find-Node
        if (-not $node) {
            Write-Output 'BLIND  node was not found, so the 8 wrapper cases did NOT run. This run proves nothing about them.'
            $blind = 8
        } else {
            foreach ($st in 'walmart', 'sams', 'aldi', 'fareway') {
                $b = New-BrowserBrief -Store $st -TabId '4242' -Date '2026-10-02' -Worklist $wlPath -Sink '' -TemplateDir $tpl -ScriptDir $here
                $code = [regex]::Match($b, '(?s)```js\n(\(function __tcInject\(\) \{.*?)\n```').Groups[1].Value
                $cut = $code.IndexOf("`n  if (typeof window.farewaySweep")
                if ($cut -lt 0) { $cut = $code.IndexOf("`n  const identity") }
                $code = $code.Substring(0, $cut) + "`n  return { ok: true, got, want };`n})()"
                foreach ($arm in 'exact', 'stripped') {
                    $js = [regex]::Replace($code, '<<< paste (\S+) here, exactly >>>', {
                        param($m)
                        $t = [IO.File]::ReadAllText((Join-Path $here $m.Groups[1].Value)).Trim("`n")
                        if ($arm -eq 'stripped' -and $m.Groups[1].Value -eq 'pull-agent-lib.js') { $t = $t.Replace('const sleep = ms =>', 'const sleep=ms =>') }
                        $t })
                    $runner = "global.window = {};`nconst r = $js;`nconsole.log(JSON.stringify(r));`n"
                    $jsPath = Join-Path $tmp ("$st-$arm.js"); $outPath = Join-Path $tmp ("$st-$arm.out")
                    [IO.File]::WriteAllText($jsPath, $runner, $u8)
                    $p = Start-Process -FilePath $node -ArgumentList @(('"' + $jsPath + '"')) -Wait -PassThru -NoNewWindow `
                             -RedirectStandardOutput $outPath -RedirectStandardError ($outPath + '.err')
                    $o = (Get-Content -LiteralPath $outPath -Raw -ErrorAction SilentlyContinue)
                    $r = $null; try { $r = ConvertFrom-Json $o } catch { }
                    if ($arm -eq 'exact') {
                        Check "MUST NOT FIRE  $st wrapper with the real files pasted measures exactly what the fill printed" ($p.ExitCode -eq 0 -and $r -and $r.ok) ([string]$o + ' ' + (Get-Content -LiteralPath ($outPath + '.err') -Raw -ErrorAction SilentlyContinue))
                    } else {
                        Check "MUST FIRE  $st wrapper refuses to start when two spaces were taken out of the lib" ($p.ExitCode -eq 0 -and $r -and $r.refused -like 'PASTE LENGTH MISMATCH*') ([string]$o)
                    }
                }
            }
        }
    } catch {
        Write-Output ('FAIL  the self-test could not complete: ' + $_.Exception.Message); $fail++
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $want = 17
    if ($ran + $blind -ne $want) { Write-Output ("FAIL  the suite ran $ran case(s) and $blind were blind, not the $want it lists"); $fail++ }
    if ($fail) { Write-Output ("fill-browser-brief SELF-TEST FAIL ($fail)"); exit 1 }
    if ($blind) { Write-Output ("fill-browser-brief SELF-TEST BLIND ($blind of $want did not run)"); exit 3 }
    Write-Output ("fill-browser-brief SELF-TEST PASS ($want of $want)")
    exit 0
}

try {
    if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
    $s = Get-BriefStore $Store
    if (-not $Worklist) { $Worklist = Join-Path $here ('out\worklists\capture-' + $s.key + '-' + $Date + '.json') }
    $td = if ($TemplateDir) { $TemplateDir } else { Join-Path $here 'browser-briefs' }
    $sd = if ($ScriptDir) { $ScriptDir } else { $here }
    $brief = New-BrowserBrief -Store $Store -TabId $TabId -Date $Date -Worklist $Worklist -Sink $Sink -TemplateDir $td -ScriptDir $sd
} catch {
    Write-Output ('REFUSED: ' + $_.Exception.Message + ' No brief was written.')
    exit 1
}
if ($Out) { [IO.File]::WriteAllText($Out, $brief, (New-Object Text.UTF8Encoding($false))); Write-Output ("brief: $Out") }
else { Write-Output $brief }
exit 0
