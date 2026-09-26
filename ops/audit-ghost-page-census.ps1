<#
  audit-ghost-page-census.ps1 - is every LIVE Ghost page either produced by a tracked source or declared?

  WHY (2026-09-19, backlog I167, Brad's ruling option 1). grocery\audit-ghost-drift.ps1 compares sixteen
  named tool posts against their local files, and its -Discover pass reads every post Ghost holds and then
  throws the unmatched remainder away without listing it. A read-only census on 2026-09-18 counted that
  remainder: of 1,089 live objects, 197 public web pages were produced by nothing in this repo, so no audit
  here could read the numbers on them. They are now DECLARED in ops\ghost-page-estate.json (the shape
  ops\cloudflare-estate.json uses) and their bodies are exported under content\ghost-adopted\. This is the
  check that keeps the set closed: a page that appears live tomorrow with no source and no declaration is
  a finding, not a silence.

  WHAT IT READS. Every published post and page, and every sent post, through read-only Admin API GETs
  (lib\ghost-lib.ps1 Invoke-GhostApi, paged by Invoke-TcGhostPaged). The write journal is cleared for the
  run. There is no PUT, POST or DELETE anywhere in this file, and -Export writes only local files.

  WHAT "PRODUCED BY A TRACKED SOURCE" MEANS, AND IT IS WEAK ON PURPOSE. The slug appears as a WHOLE token
  ([a-z0-9] runs joined by single hyphens, case-sensitive) in at least one tracked text file, except this
  census's own registry and export directory - which name every declared slug and would otherwise make the
  test vacuous. That is the test the 2026-09-18 measurement used and Brad ruled on. It cannot tell a
  producer from a mention: a slug named only in a backlog line or a crawl log counts as produced. So it
  can miss an unowned page, and it never invents one.

  SCOPE OF A CLEAN REPORT: UNSOUND. A clean report means every live page's slug is declared or NAMED
  somewhere in the tracked tree; it does not prove anything produces the page. A finding is COMPLETE for
  UNDECLARED (the slug is live and no tracked file outside the census's own files contains it as a whole
  token, which is exactly the defect) and for the three declaration findings (each is a direct comparison
  of a declared field with the live one).

  FINDINGS, each exits 1:
    UNDECLARED          a published post or page whose slug is neither named nor declared
    DECLARED-NOT-LIVE   a declared slug that is no longer published
    VISIBILITY-MOVED    a declared page whose live visibility differs from the declared one. Public declared
                        and paid live, or the reverse: the reverse is the direction that loses money, and
                        both are a change nobody recorded
    EDITED-SINCE-EXPORT a declared page whose live updated_at differs from its exported copy, so the copy
                        under content\ghost-adopted\ no longer says what readers see (or has no copy at all)
  COUNTED, never failed: status=sent posts. Those are email-only (the public URL of one answered 404 on
  2026-09-19), so there is no page to own; grocery\send-price-alerts.ps1 makes them with generated slugs.
  Drafts are out of scope: nothing reads them.

  Exit 0 = clean, 1 = at least one finding, 3 = could not evaluate (no key, Ghost unreadable, a registry that
  does not parse, or a tracked-file scan that read nothing). BLIND IS NEVER CLEAN.
  Daily, from grocery\check-ad-cycles.ps1, advisory: it never holds the board. Not in run-gates, which runs
  only this file's -SelfTest: a push must not depend on the live site answering.

  Usage: .\audit-ghost-page-census.ps1 | -Export | -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$Export, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ghost-lib.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')
$registryPath = Join-Path $here 'ghost-page-estate.json'
$API = 'https://map-to-success.ghost.io'

# ---- the whole-token scanner. C# because the tracked tree is about 1.3 GB and 8,600 files (2026-09-19), and a
# PowerShell match loop over that is minutes per run where this is seconds. The token rule is the regex
# [a-z0-9]+(?:-[a-z0-9]+)* on the raw bytes, and a file with a NUL in its first 8,000 bytes is binary and skipped.
$script:ScanSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public class TcCensusScanResult { public string[] Found; public int Text; public int Binary; public int Unreadable; }
public static class TcCensusScan {
  static bool T(byte c) { return (c >= 97 && c <= 122) || (c >= 48 && c <= 57); }
  public static TcCensusScanResult Named(string[] paths, string[] slugs) {
    var want = new HashSet<string>(slugs, StringComparer.Ordinal);
    var found = new HashSet<string>(StringComparer.Ordinal);
    int maxLen = 0; foreach (var s in slugs) { if (s.Length > maxLen) maxLen = s.Length; }
    var r = new TcCensusScanResult();
    foreach (var p in paths) {
      byte[] b;
      try { b = File.ReadAllBytes(p); } catch { r.Unreadable++; continue; }
      int lim = Math.Min(b.Length, 8000); bool bin = false;
      for (int i = 0; i < lim; i++) { if (b[i] == 0) { bin = true; break; } }
      if (bin) { r.Binary++; continue; }
      r.Text++;
      int n = b.Length, j = 0;
      while (j < n) {
        if (!T(b[j])) { j++; continue; }
        int st = j; j++;
        while (j < n) {
          if (T(b[j])) { j++; continue; }
          if (b[j] == 45 && j + 1 < n && T(b[j + 1])) { j += 2; continue; }
          break;
        }
        int len = j - st;
        if (len <= maxLen) { string t = Encoding.ASCII.GetString(b, st, len); if (want.Contains(t)) found.Add(t); }
      }
    }
    r.Found = new List<string>(found).ToArray();
    return r;
  }
}
'@
if (-not ('TcCensusScan' -as [type])) { Add-Type -TypeDefinition $script:ScanSource -Language CSharp }

function Get-TcCensusTrackedFiles {
  <# Every tracked path under $Root, minus the census's own registry and export directory. Read through the
     process stream rather than a PowerShell pipe, which splits and rejoins lines. #>
  param([string]$Root, [string[]]$ExcludePrefixes)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'; $psi.Arguments = ('-C "' + $Root + '" ls-files -z')
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $proc = [System.Diagnostics.Process]::Start($psi)
  $out = $proc.StandardOutput.ReadToEnd(); $null = $proc.StandardError.ReadToEnd(); $proc.WaitForExit()
  if ($proc.ExitCode -ne 0) { throw ('git ls-files exited ' + $proc.ExitCode) }
  $keep = New-Object System.Collections.Generic.List[string]
  foreach ($rel in $out.Split([char]0)) {
    if (-not $rel) { continue }
    $skip = $false
    foreach ($x in $ExcludePrefixes) { if ($rel.StartsWith($x, [StringComparison]::Ordinal)) { $skip = $true; break } }
    if (-not $skip) { $keep.Add((Join-Path $Root $rel)) }
  }
  return ,$keep.ToArray()
}

function Get-TcCensusLive {
  <# Every published post and page and every sent post, as flat rows. $Fetch takes (resource, page) and
     returns Ghost's parsed list response, so the self-test drives this with no network. A pager fault
     throws (Invoke-TcGhostPaged), and the caller turns that into BLIND. #>
  param([Parameter(Mandatory)][scriptblock]$Fetch, [int]$MaxPages = 40)
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($res in @('posts', 'pages')) {
    $one = { param($pg) & $Fetch $res $pg }.GetNewClosure()
    $resps = Invoke-TcGhostPaged -Fetch $one -MaxPages $MaxPages
    foreach ($r in @($resps)) {
      foreach ($p in @($r.$res)) {
        if ($null -eq $p) { continue }
        $rows.Add([pscustomobject]@{ kind = $res.TrimEnd('s'); slug = [string]$p.slug; status = [string]$p.status
                                     visibility = [string]$p.visibility; updated_at = [string]$p.updated_at })
      }
    }
  }
  return ,$rows.ToArray()
}

function Get-TcCensusVerdict {
  <# Pure: live rows + declared pages + the set of named slugs + exported updated_at per slug -> findings.
     $Declared maps slug -> object with .visibility; $Exported maps slug -> updated_at string. #>
  param($Live, [hashtable]$Declared, $Named, [hashtable]$Exported)
  $findings = New-Object System.Collections.Generic.List[string]
  $produced = 0; $declaredLive = 0; $emailOnly = 0; $pagesSeen = 0
  $liveBySlug = @{}
  foreach ($r in @($Live)) {
    if ($r.status -eq 'sent') { $emailOnly++; continue }
    if ($r.status -ne 'published') { continue }
    $pagesSeen++
    $liveBySlug[$r.slug] = $r
    if ($Declared.ContainsKey($r.slug)) {
      $declaredLive++
      $d = $Declared[$r.slug]
      if (-not [string]::Equals([string]$d.visibility, $r.visibility, [StringComparison]::Ordinal)) {
        $findings.Add(("VISIBILITY-MOVED    {0}: declared {1}, live {2}" -f $r.slug, $d.visibility, $r.visibility))
      }
      $ex = if ($Exported.ContainsKey($r.slug)) { [string]$Exported[$r.slug] } else { $null }
      if ($null -eq $ex) { $findings.Add(("EDITED-SINCE-EXPORT {0}: declared but no exported copy exists" -f $r.slug)) }
      elseif (-not [string]::Equals($ex, $r.updated_at, [StringComparison]::Ordinal)) {
        $findings.Add(("EDITED-SINCE-EXPORT {0}: exported copy is of {1}, live updated_at is {2}" -f $r.slug, $ex, $r.updated_at))
      }
      continue
    }
    if ($Named.Contains($r.slug)) { $produced++; continue }
    $findings.Add(("UNDECLARED          {0} {1} ({2}): live, and no tracked file names it and ops\ghost-page-estate.json does not declare it" -f $r.kind, $r.slug, $r.visibility))
  }
  foreach ($s in @($Declared.Keys | Sort-Object)) {
    if (-not $liveBySlug.ContainsKey($s)) { $findings.Add(("DECLARED-NOT-LIVE   {0}: declared, and Ghost no longer publishes it" -f $s)) }
  }
  return [pscustomobject]@{ findings = $findings.ToArray(); live = $pagesSeen; produced = $produced
                            declared = $declaredLive; email_only = $emailOnly }
}

function Read-TcCensusRegistry([string]$Path) {
  $reg = Read-JsonFile $Path
  $decl = @{}
  foreach ($p in $reg.pages.PSObject.Properties) { $decl[$p.Name] = $p.Value }
  return [pscustomobject]@{ doc = $reg; declared = $decl }
}

function Read-TcCensusExported([string]$Dir, [string[]]$Slugs) {
  $ex = @{}
  foreach ($s in $Slugs) {
    $f = Join-Path $Dir ($s + '.json')
    if (Test-Path -LiteralPath $f) { try { $ex[$s] = [string](Read-JsonFile $f).updated_at } catch { } }
  }
  return $ex
}

# The exported_on a re-export writes (2026-09-25, queue 2026-09-23-373ac2). It moves ONLY when the page moved: the old
# export's date is kept when its updated_at, html_sha256 and lexical_sha256 all match the fresh read. Before this every
# -Export rewrote all 196 declared pages' dates, so one stale page cost a 228-file diff and the export was put off; 32
# pages sat EDITED-SINCE-EXPORT for two days after the Batch 3 article land.
function Get-TcCensusExportedOn($Old, [string]$UpdatedAt, [string]$HtmlSha, [string]$LexSha, [string]$Today) {
  if ($null -eq $Old -or -not $Old.PSObject.Properties['exported_on'] -or -not [string]$Old.exported_on) { return $Today }
  $same = ([string]$Old.updated_at -ceq $UpdatedAt) -and ([string]$Old.html_sha256 -ceq $HtmlSha) -and ([string]$Old.lexical_sha256 -ceq $LexSha)
  if ($same) { return [string]$Old.exported_on }
  return $Today
}

# ================================================================ self-test: a stubbed Ghost, no network, no key
if ($SelfTest) {
  $savedJournal = $env:TC_WRITE_JOURNAL
  $env:TC_WRITE_JOURNAL = $null
  $f = 0; $n = 0
  function Test-CensusCase($m, $c, $g) { $script:n++; if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('gpc-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  try {
    # the export's date moves only with the page (queue 2026-09-23-373ac2)
    $oldEx = [pscustomobject]@{ updated_at = '2026-07-05T00:33:33.000Z'; html_sha256 = 'aa'; lexical_sha256 = 'bb'; exported_on = '2026-09-19' }
    $d1 = Get-TcCensusExportedOn $oldEx '2026-09-23T13:17:48.000Z' 'cc' 'dd' '2026-09-25'
    Test-CensusCase 'MUST FIRE  a page Ghost edited since the export (founding: 32 Batch 3 articles, 2026-09-23) takes today''s exported_on' ($d1 -eq '2026-09-25') $d1
    $d2 = Get-TcCensusExportedOn $oldEx '2026-07-05T00:33:33.000Z' 'aa' 'bb' '2026-09-25'
    Test-CensusCase 'MUST NOT FIRE  an unchanged page keeps its old exported_on, so a re-export rewrites nothing for it' ($d2 -eq '2026-09-19') $d2
    $d3 = Get-TcCensusExportedOn $oldEx '2026-07-05T00:33:33.000Z' 'aa' 'bX' '2026-09-25'
    Test-CensusCase 'MUST FIRE  the same updated_at over a different lexical still moves the date (a hash is read, not only the clock)' ($d3 -eq '2026-09-25') $d3
    $d4 = Get-TcCensusExportedOn $null 'x' 'y' 'z' '2026-09-25'
    Test-CensusCase 'CLEAN TWIN  a page with no earlier export is dated today' ($d4 -eq '2026-09-25') $d4
    # the tracked-file half: a source file naming one slug, a file naming a slug only INSIDE a longer token, a binary
    $src = Join-Path $tmp 'source.ps1'
    [IO.File]::WriteAllText($src, ('$slug = ''tracked' + '-tool''' + "`n" + 'see wash-sale-rule' + '-2 and Mixed-Case-Page' + "`n"), (New-Object Text.UTF8Encoding($false)))
    $bin = Join-Path $tmp 'blob.bin'
    [IO.File]::WriteAllBytes($bin, [byte[]](@(0, 1, 2) + [Text.Encoding]::ASCII.GetBytes('orphan' + '-page')))
    $slugs = @('tracked-tool', 'wash-sale-rule', 'orphan-page', 'mixed-case-page', 'declared-page')
    $scan = [TcCensusScan]::Named(@($src, $bin, (Join-Path $tmp 'missing.txt')), [string[]]$slugs)
    $named = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($s in $scan.Found) { [void]$named.Add($s) }

    Test-CensusCase 'CLEAN TWIN scan: a slug written as a whole token in a tracked source file is found' `
      ($named.Contains('tracked-tool')) ("found=[" + ($scan.Found -join ',') + "]")
    Test-CensusCase 'MUST FIRE scan: a slug that appears only INSIDE a longer token is not counted as named' `
      (-not $named.Contains('wash-sale-rule')) ("found=[" + ($scan.Found -join ',') + "]")
    Test-CensusCase 'MUST FIRE scan: the match is case-sensitive, as the measurement was' `
      (-not $named.Contains('mixed-case-page')) ("found=[" + ($scan.Found -join ',') + "]")
    Test-CensusCase 'MUST FIRE scan: a binary file is skipped, not read as text, and the unreadable one is counted' `
      ((-not $named.Contains('orphan-page')) -and $scan.Binary -eq 1 -and $scan.Text -eq 1 -and $scan.Unreadable -eq 1) ("text={0} binary={1} unreadable={2}" -f $scan.Text, $scan.Binary, $scan.Unreadable)

    # the live half: a stubbed Ghost with two list endpoints, each one page long
    $stubPosts = @(
      [pscustomobject]@{ slug = 'tracked-tool';  status = 'published'; visibility = 'public'; updated_at = '2026-07-04T00:00:00.000Z' }
      [pscustomobject]@{ slug = 'orphan-page';   status = 'published'; visibility = 'public'; updated_at = '2026-07-04T00:00:00.000Z' }
      [pscustomobject]@{ slug = 'declared-page'; status = 'published'; visibility = 'public'; updated_at = '2026-07-05T00:00:00.000Z' }
      [pscustomobject]@{ slug = 'price-alert-x'; status = 'sent';      visibility = 'paid';   updated_at = '2026-09-11T00:00:00.000Z' }
      [pscustomobject]@{ slug = 'a-draft';       status = 'draft';     visibility = 'public'; updated_at = '2026-09-11T00:00:00.000Z' }
    )
    $stubPages = @([pscustomobject]@{ slug = 'refunds'; status = 'published'; visibility = 'public'; updated_at = '2026-07-10T13:38:44.000Z' })
    $calls = @{ n = 0 }
    $stub = {
      param($res, $pg)
      $calls.n++
      if ($calls.n -gt 20) { throw 'STUB-GUARD: more than 20 fetches' }
      $items = if ($res -eq 'posts') { $stubPosts } else { $stubPages }
      $o = [ordered]@{}; $o[$res] = $items; $o['meta'] = [pscustomobject]@{ pagination = [pscustomobject]@{ page = $pg; next = $null } }
      [pscustomobject]$o
    }
    $live = Get-TcCensusLive -Fetch $stub
    Test-CensusCase 'CLEAN TWIN live: both endpoints are read once each and every row comes back' `
      ($calls.n -eq 2 -and @($live).Count -eq 6) ("calls={0} rows={1}" -f $calls.n, @($live).Count)

    $decl = @{ 'declared-page' = [pscustomobject]@{ visibility = 'public' }; 'refunds' = [pscustomobject]@{ visibility = 'public' } }
    $exp = @{ 'declared-page' = '2026-07-05T00:00:00.000Z'; 'refunds' = '2026-07-10T13:38:44.000Z' }
    $v = Get-TcCensusVerdict -Live $live -Declared $decl -Named $named -Exported $exp
    $fj = ($v.findings -join ' | ')
    Test-CensusCase 'MUST FIRE verdict: an undeclared live page no tracked file names is reported UNDECLARED' `
      (@($v.findings | Where-Object { $_ -match '^UNDECLARED\s+post orphan-page' }).Count -eq 1) $fj
    Test-CensusCase 'MUST NOT FIRE verdict: a declared page with matching visibility and export is not a finding' `
      (@($v.findings | Where-Object { $_ -match 'declared-page|refunds' }).Count -eq 0 -and $v.declared -eq 2) ("declared={0} findings={1}" -f $v.declared, $fj)
    Test-CensusCase 'CLEAN TWIN verdict: a page a tracked source names counts as produced' `
      ($v.produced -eq 1 -and @($v.findings | Where-Object { $_ -match 'tracked-tool' }).Count -eq 0) ("produced={0} findings={1}" -f $v.produced, $fj)
    Test-CensusCase 'MUST NOT FIRE verdict: a sent (email-only) post is counted, never failed; a draft is out of scope' `
      ($v.email_only -eq 1 -and $v.live -eq 4 -and @($v.findings | Where-Object { $_ -match 'price-alert-x|a-draft' }).Count -eq 0) ("email_only={0} live={1} findings={2}" -f $v.email_only, $v.live, $fj)
    Test-CensusCase 'the clean fixture has exactly one finding in total' (@($v.findings).Count -eq 1) $fj

    $decl2 = @{ 'declared-page' = [pscustomobject]@{ visibility = 'paid' }; 'refunds' = [pscustomobject]@{ visibility = 'public' }; 'gone-page' = [pscustomobject]@{ visibility = 'public' } }
    $exp2 = @{ 'declared-page' = '2026-07-05T00:00:00.000Z'; 'refunds' = '2026-07-01T00:00:00.000Z'; 'gone-page' = 'x' }
    $v2 = Get-TcCensusVerdict -Live $live -Declared $decl2 -Named $named -Exported $exp2
    $fj2 = ($v2.findings -join ' | ')
    Test-CensusCase 'MUST FIRE verdict: a page declared paid and served public is VISIBILITY-MOVED' `
      (@($v2.findings | Where-Object { $_ -match '^VISIBILITY-MOVED\s+declared-page: declared paid, live public' }).Count -eq 1) $fj2
    Test-CensusCase 'MUST FIRE verdict: a declared page edited in Ghost after its export is EDITED-SINCE-EXPORT' `
      (@($v2.findings | Where-Object { $_ -match '^EDITED-SINCE-EXPORT refunds' }).Count -eq 1) $fj2
    Test-CensusCase 'MUST FIRE verdict: a declared page Ghost no longer publishes is DECLARED-NOT-LIVE' `
      (@($v2.findings | Where-Object { $_ -match '^DECLARED-NOT-LIVE\s+gone-page' }).Count -eq 1) $fj2
    $v3 = Get-TcCensusVerdict -Live $live -Declared $decl -Named $named -Exported @{ 'refunds' = '2026-07-10T13:38:44.000Z' }
    Test-CensusCase 'MUST FIRE verdict: a declared page with no exported copy is reported' `
      (@($v3.findings | Where-Object { $_ -match '^EDITED-SINCE-EXPORT declared-page: declared but no exported copy' }).Count -eq 1) ($v3.findings -join ' | ')

    # a Ghost whose pager repeats itself must end as a throw (BLIND in the live path), never a partial census
    $loop = { param($res, $pg) $calls.n++; if ($calls.n -gt 20) { throw 'STUB-GUARD' }; $o = [ordered]@{}; $o[$res] = @(); $o['meta'] = [pscustomobject]@{ pagination = [pscustomobject]@{ page = $pg; next = 1 } }; [pscustomobject]$o }
    $calls.n = 0; $threw = ''
    try { $null = Get-TcCensusLive -Fetch $loop } catch { $threw = $_.Exception.Message }
    Test-CensusCase 'MUST FIRE live: a pager that does not advance throws after one fetch, so the run is BLIND' `
      ($calls.n -eq 1 -and $threw -match 'did not advance') ("calls={0} threw=[{1}]" -f $calls.n, $threw)

    # the registry shipped next to this file parses and every declared page has an exported copy
    $regOk = $false; $regGot = ''
    try {
      $rg = Read-TcCensusRegistry $registryPath
      $dir = Join-Path $repo ([string]$rg.doc.export_dir)
      $missing = @($rg.declared.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dir ($_ + '.json'))) -or -not (Test-Path -LiteralPath (Join-Path $dir ($_ + '.html'))) })
      $regGot = ("declared={0} missing_exports={1}" -f $rg.declared.Count, $missing.Count)
      $regOk = ($rg.declared.Count -gt 0 -and $missing.Count -eq 0)
    } catch { $regGot = $_.Exception.Message }
    Test-CensusCase 'the shipped registry parses and every declared page has its exported .json and .html' $regOk $regGot
  } catch {
    Write-Output ("FAIL  the self-test threw: " + $_.Exception.Message); $f++
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    $env:TC_WRITE_JOURNAL = $savedJournal
  }
  $want = 20
  if ($n -ne $want -and $f -eq 0) { Write-Output ("FAIL  ran {0} case(s), the list holds {1}" -f $n, $want); $f++ }
  if ($f -eq 0) { Write-Output ("audit-ghost-page-census SELF-TEST PASS ({0} cases)" -f $n); exit 0 }
  Write-Output ("audit-ghost-page-census SELF-TEST FAIL ({0} of {1})" -f $f, $n); exit 1
}

# ================================================================ live
# Read-only by construction: every call below is a GET, and the journal is cleared so not even a GET is
# recorded anywhere a reverter could read.
$env:TC_WRITE_JOURNAL = $null
$key = $null
try { $key = Get-GhostKey -Root $repo } catch { $key = $null }
if (-not $key) {
  Write-Output 'ghost-page-census: COULD NOT EVALUATE - no GHOST_ADMIN_KEY and no meal-prep\.ghostkey, so nothing was read'
  exit 3
}
if (-not (Test-Path -LiteralPath $registryPath)) {
  Write-Output ("ghost-page-census: COULD NOT EVALUATE - no registry at {0}" -f $registryPath)
  exit 3
}
try { $reg = Read-TcCensusRegistry $registryPath } catch {
  Write-Output ("ghost-page-census: COULD NOT EVALUATE - the registry does not parse: {0}" -f $_.Exception.Message)
  exit 3
}
$exportRel = [string]$reg.doc.export_dir
$exportDir = Join-Path $repo $exportRel
$getHeaders = { @{ Authorization = ('Ghost ' + (Get-GhostJWT -Key $key)); 'Accept-Version' = (Get-GhostAcceptVersion) } }

if ($Export) {
  # Fetch EVERY declared page first and write nothing until all of them came back: a half-written export
  # would read as adopted and be stale in the half nobody noticed.
  $got = @{}
  $blind = @()
  foreach ($s in @($reg.declared.Keys | Sort-Object)) {
    $kind = [string]$reg.declared[$s].kind
    $res = if ($kind -eq 'page') { 'pages' } else { 'posts' }
    try {
      $r = Invoke-GhostApi -Method GET -Uri ("$API/ghost/api/admin/$res/slug/$s/?formats=html,lexical&include=tags") -Headers (& $getHeaders) -TimeoutSec 60
      $o = @($r.$res)[0]
      if (-not $o) { $blind += ($s + ': no object'); continue }
      $got[$s] = $o
    } catch { $blind += ($s + ': ' + $_.Exception.Message) }
    Start-Sleep -Milliseconds 150
  }
  if ($blind.Count) {
    foreach ($b in $blind) { Write-Output ('  BLIND  ' + $b) }
    Write-Output ("ghost-page-census/export: COULD NOT EVALUATE - {0} of {1} declared page(s) could not be read, so NOTHING was written" -f $blind.Count, $reg.declared.Count)
    exit 3
  }
  if (-not (Test-Path -LiteralPath $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }
  $sha = [Security.Cryptography.SHA256]::Create()
  $hex = { param($t) if ($null -eq $t) { return $null }; ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$t)))).Replace('-', '').ToLowerInvariant() }
  $written = 0; $bytes = 0
  foreach ($s in @($got.Keys | Sort-Object)) {
    $o = $got[$s]
    $oldF = Join-Path $exportDir ($s + '.json'); $old = $null
    if (Test-Path -LiteralPath $oldF) { try { $old = Read-JsonFile $oldF } catch { $old = $null } }
    $hSha = (& $hex $o.html); $lSha = (& $hex $o.lexical)
    # No authors, no member data: the fields that say what the page is and what it says, nothing about who.
    $meta = [ordered]@{
      slug = [string]$o.slug; kind = [string]$reg.declared[$s].kind; id = [string]$o.id; title = [string]$o.title
      status = [string]$o.status; visibility = [string]$o.visibility
      published_at = [string]$o.published_at; updated_at = [string]$o.updated_at; created_at = [string]$o.created_at
      url = [string]$o.url; custom_excerpt = $o.custom_excerpt; meta_title = $o.meta_title; meta_description = $o.meta_description
      canonical_url = $o.canonical_url; feature_image = $o.feature_image
      tags = @(@($o.tags) | Where-Object { $_ } | ForEach-Object { [string]$_.slug })
      codeinjection_head = $o.codeinjection_head; codeinjection_foot = $o.codeinjection_foot
      html_file = ($s + '.html'); html_sha256 = $hSha; lexical_sha256 = $lSha
      exported_on = (Get-TcCensusExportedOn $old ([string]$o.updated_at) $hSha $lSha (Get-Date -Format 'yyyy-MM-dd')); exported_by = 'ops/audit-ghost-page-census.ps1 -Export (read-only Admin API GET)'
      lexical = $o.lexical
    }
    $j = ConvertTo-Json -InputObject $meta -Depth 6
    $h = [string]$o.html
    if (Write-TcLfFile -Path (Join-Path $exportDir ($s + '.json')) -Text $j -NoBom) { $written++ }
    if (Write-TcLfFile -Path (Join-Path $exportDir ($s + '.html')) -Text $h -NoBom) { $written++ }
    $bytes += [Text.Encoding]::UTF8.GetByteCount($j) + [Text.Encoding]::UTF8.GetByteCount($h)
  }
  Write-Output ("ghost-page-census/export: {0} of {1} declared page(s) exported to {2}, {3} file(s) changed, {4:N1} MB of text" -f $got.Count, $reg.declared.Count, $exportRel, $written, ($bytes / 1MB))
  Exit-Guard -Name 'ghost-page-census' -Summary ("export pages={0} changed_files={1}" -f $got.Count, $written) -Code 0
}

# ---- census
$fetch = {
  param($res, $pg)
  if ($pg -gt 1) { Start-Sleep -Milliseconds 200 }
  $flt = [uri]::EscapeDataString('status:[published,sent]')
  Invoke-GhostApi -Method GET -Uri ("$API/ghost/api/admin/$res/?limit=100&page=$pg&filter=$flt&fields=slug,status,visibility,updated_at") -Headers (& $getHeaders) -TimeoutSec 90
}
try { $live = Get-TcCensusLive -Fetch $fetch -MaxPages 40 } catch {
  Write-Output ("ghost-page-census: COULD NOT EVALUATE - reading Ghost failed: {0}" -f $_.Exception.Message)
  Exit-Guard -Name 'ghost-page-census' -Summary 'blind=ghost-read' -Code 3
}
if (@($live).Count -eq 0) {
  Write-Output 'ghost-page-census: COULD NOT EVALUATE - Ghost returned zero live objects, so a clean result would prove nothing'
  Exit-Guard -Name 'ghost-page-census' -Summary 'blind=zero-live' -Code 3
}

$registryRel = 'ops/' + (Split-Path $registryPath -Leaf)
$files = Get-TcCensusTrackedFiles -Root $repo -ExcludePrefixes @($registryRel, ($exportRel.TrimEnd('/') + '/'))
$liveSlugs = @($live | Where-Object { $_.status -eq 'published' } | ForEach-Object { $_.slug })
$scan = [TcCensusScan]::Named([string[]]$files, [string[]]$liveSlugs)
if ($scan.Text -eq 0) {
  Write-Output ("ghost-page-census: COULD NOT EVALUATE - the tracked-file scan read no text file ({0} listed), so every page would read as unnamed" -f $files.Count)
  Exit-Guard -Name 'ghost-page-census' -Summary 'blind=no-tracked-text' -Code 3
}
$named = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($s in $scan.Found) { [void]$named.Add($s) }
$exported = Read-TcCensusExported -Dir $exportDir -Slugs @($reg.declared.Keys)
$v = Get-TcCensusVerdict -Live $live -Declared $reg.declared -Named $named -Exported $exported

Write-Output ("ghost-page-census: {0} live web page(s): {1} named by a tracked file, {2} declared in {3}, {4} finding(s). {5} email-only sent post(s) counted, not pages." -f $v.live, $v.produced, $v.declared, $registryRel, @($v.findings).Count, $v.email_only)
Write-Output ("  tracked files scanned: {0} text, {1} binary skipped, {2} unreadable, of {3} listed (registry and {4} excluded)" -f $scan.Text, $scan.Binary, $scan.Unreadable, $files.Count, $exportRel)
foreach ($x in $v.findings) { Write-Output ('  ' + $x) }
if (@($v.findings).Count) {
  Write-Output ''
  Write-Output '  UNDECLARED: find what made the page, commit its source or declare it in ops\ghost-page-estate.json with why, then'
  Write-Output '  export it with -Export. EDITED-SINCE-EXPORT: read what changed in Ghost, then re-run -Export. VISIBILITY-MOVED and'
  Write-Output '  DECLARED-NOT-LIVE: somebody changed the live site; decide, then record the new state here.'
}
Exit-Guard -Name 'ghost-page-census' -Summary ("live={0} produced={1} declared={2} email_only={3} findings={4} scanned_text={5}" -f $v.live, $v.produced, $v.declared, $v.email_only, @($v.findings).Count, $scan.Text) -Code $(if (@($v.findings).Count) { 1 } else { 0 })
