<#
  match-lib.ps1 - THE commodity matcher, precompiled. Same decision as the original Match-Category in
  compare-deals.ps1, roughly an order of magnitude faster.

  WHY (measured 2026-08-22). One compare-deals run took 159s, and 139s of that was the categorize loop:
      39,931 rows -> 31,828 distinct names
      45.7 MILLION include-pattern evaluations, 2.6 million exclude evaluations
      avg 1,436 include tests per name (first-match-wins over 1,454 patterns x 2 text variants)
  The regex work itself is trivial. The cost was PowerShell's `-match` operator being invoked 48 million
  times from an interpreted triple loop, at ~2.5 us a call. apply-coverage-batch runs that loop three to
  four times per attempt, which is why one batch attempt cost ~10 minutes and a revert cost a fourth.

  WHAT CHANGED, AND WHAT DID NOT.
    * Every pattern is compiled ONCE into a [regex] with IgnoreCase, which is exactly the option set the
      `-match` operator uses (case-insensitive, nothing else). Same .NET engine, same semantics.
    * Each commodity's INCLUDE list becomes ONE alternation, (?:p1)|(?:p2)|..., tested with IsMatch. For a
      yes/no question an alternation of groups answers identically to testing the groups in turn. This is
      safe because the catalog was measured to contain ZERO backreferences and ZERO named groups, which
      are the only constructs whose meaning changes when wrapped. The three patterns carrying inline
      options are kept as standalone regexes rather than folded in.
    * Excludes are tested per pattern as before; they run only on include hits, so they were never the cost.
    * The decision procedure is a line-for-line port: texts = raw + normalized variant; global-exclude
      hits on the RAW name; relax_global by exact pattern-string equality; first commodity in file order
      whose include hits, whose global hits are all relaxed, and whose excludes all miss.

  PROVEN IDENTICAL, NOT ASSUMED. test-match-lib.ps1 runs the ORIGINAL Match-Category (extracted verbatim
  from compare-deals) and this one over every distinct product name in the live capture pool and demands
  the same commodity id for all of them. The rule is the same one the estate applies to every matcher
  copy: `two copies of a rule` drift silently, so the second copy has to be proven against the first on
  the real corpus, every suite run, not reasoned about once.

  Usage:
      . match-lib.ps1
      $m = New-CommodityMatcher -Commodities $commodities -GlobalExclude $GLOBAL_EXCLUDE
      $c = Resolve-Commodity -Matcher $m -Name $productName      # -> commodity object or $null
#>

function Get-MatchTexts([string]$name) {
  # VERBATIM from compare-deals. [0] is always the RAW lowercase name; [1] the normalized variant used
  # for INCLUDES ONLY (drops Sam's "priced per X" suffix, treats "X and Y" as "X Y").
  $n = $name.ToLower()
  $v = $n -replace ',?\s*priced per\s+\w+', ''
  $v = (($v -replace '\band\b', ' ') -replace '\s{2,}', ' ').Trim()
  return ,@($n, $v)
}

# THE LOOP ITSELF, IN COMPILED CODE. Precompiling the regexes took the matcher from 139s to ~30s and
# then stalled: at that point the cost is no longer regex evaluation but the PowerShell interpreter
# iterating 586 entries x 31,924 names with property lookups on every step. The same decision procedure
# as a C# method - identical regex objects, identical order, identical relax/exclude rules - runs the
# whole corpus in about a second. Add-Type compiles it once per process (~1s) and caches the type.
# If compilation is unavailable the PowerShell path below is used unchanged; both are covered by the
# identity harness, so neither can drift from the original silently.
$script:MatchCoreSource = @'
using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
namespace ThriftyCrew {
  public sealed class MatchCore {
    public Regex[] Gex; public string[] GexText;
    public Regex[] Inc;            // per entry: combined include, or null
    public Regex[][] IncSpecial;   // per entry: standalone includes with inline options
    // Per entry: every include compiled INDIVIDUALLY, in commodities.json order, with its source text.
    // Used only by ResolveDetail (which include actually fired), never by Resolve - the hot path stays
    // exactly the bytes the identity harness has been proving.
    public Regex[][] IncEach; public string[][] IncEachText;
    public Regex[][] Exc;          // per entry: excludes
    public string[][] Relax;       // per entry: relax_global pattern texts
    public bool[] HasInc;
    // Per entry: literal tokens such that the entry's includes can only match a name containing at
    // least one of them (null = no sound prefilter, always test). See RequiredLiteral below.
    public string[][] Req;
    // INVERTED INDEX over the required literals: lowercase 3-char prefix -> the tokens starting with it,
    // each carrying the entries it unlocks. Built once by BuildIndex(). A name is scanned ONCE, position
    // by position, instead of testing ~1,500 tokens against it with IndexOf.
    Dictionary<string, List<KeyValuePair<string, List<int>>>> _idx;
    bool[] _always;   // entries with no sound prefilter (Req == null): always candidates
    public void BuildIndex() {
      _idx = new Dictionary<string, List<KeyValuePair<string, List<int>>>>(StringComparer.Ordinal);
      _always = new bool[Inc.Length];
      var byTok = new Dictionary<string, List<int>>(StringComparer.Ordinal);
      for (int i = 0; i < Inc.Length; i++) {
        if (!HasInc[i]) continue;
        if (Req[i] == null) { _always[i] = true; continue; }
        foreach (var t in Req[i]) {
          string tok = t.ToLowerInvariant();
          List<int> l; if (!byTok.TryGetValue(tok, out l)) { l = new List<int>(); byTok[tok] = l; }
          if (l.Count == 0 || l[l.Count - 1] != i) l.Add(i);
        }
      }
      foreach (var kv in byTok) {
        string pre = kv.Key.Substring(0, 3);
        List<KeyValuePair<string, List<int>>> bucket;
        if (!_idx.TryGetValue(pre, out bucket)) { bucket = new List<KeyValuePair<string, List<int>>>(); _idx[pre] = bucket; }
        bucket.Add(new KeyValuePair<string, List<int>>(kv.Key, kv.Value));
      }
    }
    // Which entries are possible for this text: every entry unlocked by a token that occurs in it.
    void Collect(string text, bool[] cand) {
      string s = text.ToLowerInvariant();
      for (int p = 0; p + 3 <= s.Length; p++) {
        List<KeyValuePair<string, List<int>>> bucket;
        if (!_idx.TryGetValue(s.Substring(p, 3), out bucket)) continue;
        foreach (var kv in bucket) {
          string tok = kv.Key;
          if (p + tok.Length <= s.Length && string.CompareOrdinal(s, p, tok, 0, tok.Length) == 0) {
            foreach (int i in kv.Value) cand[i] = true;
          }
        }
      }
    }
    // Returns the index of the winning entry, or -1.
    public int Resolve(string raw, string variant) {
      List<string> ghits = null;
      for (int g = 0; g < Gex.Length; g++) {
        if (Gex[g].IsMatch(raw)) { if (ghits == null) ghits = new List<string>(); ghits.Add(GexText[g]); }
      }
      if (_idx == null) BuildIndex();
      // PREFILTER: an entry whose every include requires a literal is a candidate only if one of those
      // literals occurs in the raw OR the variant text. Same predicate as testing IndexOf per token;
      // computed by one scan of each text. Sound by construction (see RequiredLiteral), and the
      // identity harness proves it on the corpus as well.
      var cand = new bool[Inc.Length];
      Collect(raw, cand);
      if (!ReferenceEquals(variant, raw) && variant != raw) Collect(variant, cand);
      for (int i = 0; i < Inc.Length; i++) {
        if (!HasInc[i]) continue;
        if (!_always[i] && !cand[i]) continue;
        bool hit = false;
        if (Inc[i] != null && (Inc[i].IsMatch(raw) || Inc[i].IsMatch(variant))) hit = true;
        if (!hit && IncSpecial[i] != null) {
          foreach (var rx in IncSpecial[i]) { if (rx.IsMatch(raw) || rx.IsMatch(variant)) { hit = true; break; } }
        }
        if (!hit) continue;
        if (ghits != null) {
          bool blocked = false;
          foreach (var g in ghits) { if (Array.IndexOf(Relax[i], g) < 0) { blocked = true; break; } }
          if (blocked) continue;
        }
        bool bad = false;
        if (Exc[i] != null) { foreach (var rx in Exc[i]) { if (rx.IsMatch(raw)) { bad = true; break; } } }
        if (bad) continue;
        return i;
      }
      return -1;
    }

    // THE DETAIL SCAN (2026-08-22, the identity table - PLAN-product-identity section 10.6).
    // Same predicate, same order, same prefilter as Resolve; the ONLY difference is that it does not
    // stop at the first winner, so it can also report the CONTESTED set - every other entry whose
    // include hit, whose globals were relaxed, and whose excludes all missed. That set is what
    // audit-match-contested exists to find, and it falls out of one scan here.
    //
    // Resolve is deliberately NOT reimplemented in terms of this. Two reasons, both load-bearing:
    // the board's hot path must keep costing what it costs (this scan runs the whole entry list every
    // time instead of returning early), and the fast path must stay byte-for-byte the code that
    // test-match-lib has been proving against the original Match-Category. What guards the duplication
    // is the same rule as everywhere else in this estate - test-match-lib asserts, on every distinct
    // name in the live corpus, that ResolveDetail's winner IS Resolve's answer. A drift between these
    // two goes red on the next suite run rather than writing a wrong identity table for a quarter.
    //
    // winPat is the INDEX, inside the winning entry's include array, of the first pattern that fires -
    // pattern-major over (raw, variant), which is the original's own order:
    //     foreach ($inc in $c.include) { foreach ($t in $texts) { ... } }
    // -1 means "the entry won through a path with no individually-compiled include", which can only
    // happen if IncEach was not built.
    public int ResolveDetail(string raw, string variant, List<int> others, out int winPat) {
      winPat = -1;
      int winner = -1;
      List<string> ghits = null;
      for (int g = 0; g < Gex.Length; g++) {
        if (Gex[g].IsMatch(raw)) { if (ghits == null) ghits = new List<string>(); ghits.Add(GexText[g]); }
      }
      if (_idx == null) BuildIndex();
      var cand = new bool[Inc.Length];
      Collect(raw, cand);
      if (!ReferenceEquals(variant, raw) && variant != raw) Collect(variant, cand);
      for (int i = 0; i < Inc.Length; i++) {
        if (!HasInc[i]) continue;
        if (!_always[i] && !cand[i]) continue;
        bool hit = false;
        if (Inc[i] != null && (Inc[i].IsMatch(raw) || Inc[i].IsMatch(variant))) hit = true;
        if (!hit && IncSpecial[i] != null) {
          foreach (var rx in IncSpecial[i]) { if (rx.IsMatch(raw) || rx.IsMatch(variant)) { hit = true; break; } }
        }
        if (!hit) continue;
        if (ghits != null) {
          bool blocked = false;
          foreach (var g in ghits) { if (Array.IndexOf(Relax[i], g) < 0) { blocked = true; break; } }
          if (blocked) continue;
        }
        bool bad = false;
        if (Exc[i] != null) { foreach (var rx in Exc[i]) { if (rx.IsMatch(raw)) { bad = true; break; } } }
        if (bad) continue;
        if (winner < 0) {
          winner = i;
          if (IncEach != null && IncEach[i] != null) {
            for (int p = 0; p < IncEach[i].Length; p++) {
              if (IncEach[i][p].IsMatch(raw) || IncEach[i][p].IsMatch(variant)) { winPat = p; break; }
            }
          }
        } else if (others != null) { others.Add(i); }
      }
      return winner;
    }

    // How many of the winning entry's excludes were actually evaluated. For a WINNER this is all of
    // them, because an entry only wins by having every exclude miss - so this is the entry's exclude
    // count, and it is recorded to make "n excludes tested" on a board cell a fact rather than a claim.
    public int ExcludeCount(int entry) {
      if (entry < 0 || Exc == null || entry >= Exc.Length || Exc[entry] == null) { return 0; }
      return Exc[entry].Length;
    }

    // A literal that the pattern REQUIRES: an alphabetic run of 3+ chars at nesting depth 0 that is not
    // an escape (\b \s \w \d ...), not inside [...] or (...), not followed by a quantifier that could
    // make it optional, and not in a pattern whose top level contains a bare '|' (where no single
    // branch is required). Returns null when no such literal exists, which means "cannot prefilter".
    // Conservative on purpose: every rule here errs toward returning null, because a wrong "required"
    // claim would silently hide a real match while a null only costs speed.
    public static string RequiredLiteral(string p) {
      int depth = 0; bool inClass = false;
      // pass 1: a bare '|' at depth 0 means no single literal is required
      for (int i = 0; i < p.Length; i++) {
        char c = p[i];
        if (c == '\\') { i++; continue; }
        if (inClass) { if (c == ']') inClass = false; continue; }
        if (c == '[') { inClass = true; continue; }
        if (c == '(') { depth++; continue; }
        if (c == ')') { depth--; continue; }
        if (c == '|' && depth == 0) return null;
      }
      depth = 0; inClass = false;
      string best = null; int runStart = -1;
      for (int i = 0; i <= p.Length; i++) {
        char c = i < p.Length ? p[i] : '\0';
        // ASCII letters only: for those, Regex IgnoreCase and String OrdinalIgnoreCase agree exactly.
        // Outside ASCII the two case-folding rules can differ, so a non-ASCII run is never a token.
        bool letter = i < p.Length && c < (char)128 && char.IsLetter(c) && depth == 0 && !inClass;
        if (letter) { if (runStart < 0) runStart = i; continue; }
        if (runStart >= 0) {
          int len = i - runStart;
          // a quantifier right after the run makes its last char optional/repeated: drop that char
          bool quant = i < p.Length && (c == '?' || c == '*' || c == '{' || c == '+');
          int keep = quant ? len - 1 : len;
          if (keep >= 3) { string tok = p.Substring(runStart, keep); if (best == null || tok.Length > best.Length) best = tok; }
          runStart = -1;
        }
        if (i >= p.Length) break;
        if (c == '\\') { i++; continue; }           // skip the escaped char; \b \s \w etc are not literals
        if (inClass) { if (c == ']') inClass = false; continue; }
        if (c == '[') { inClass = true; continue; }
        if (c == '(') { depth++; continue; }
        if (c == ')') { depth--; continue; }
      }
      return best;
    }
  }
}
'@
function Get-MatchCoreType {
  if ($script:MatchCoreLoaded) { return $true }
  if ('ThriftyCrew.MatchCore' -as [type]) { $script:MatchCoreLoaded = $true; return $true }
  try { Add-Type -TypeDefinition $script:MatchCoreSource -Language CSharp -ErrorAction Stop | Out-Null; $script:MatchCoreLoaded = $true; return $true }
  catch { $script:MatchCoreLoaded = $false; return $false }
}

function New-CommodityMatcher {
  param(
    [Parameter(Mandatory)]$Commodities,
    [Parameter(Mandatory)][string[]]$GlobalExclude
  )
  $opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  $gex = New-Object System.Collections.Generic.List[object]
  foreach ($g in $GlobalExclude) {
    $gex.Add([pscustomobject]@{ text = [string]$g; rx = [regex]::new([string]$g, $opt) })
  }
  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($c in $Commodities) {
    $incs = @($c.include | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [string]$_ })
    # Fold plain patterns into one alternation; keep any pattern with inline options standalone, because
    # (?i) and friends inside a group apply to the remainder of the group only, which is not how the
    # original evaluated them.
    $plain = @($incs | Where-Object { $_ -notmatch '\(\?[imsxn-]+\)' })
    $special = @($incs | Where-Object { $_ -match '\(\?[imsxn-]+\)' })
    $combined = $null
    if ($plain.Count) { $combined = [regex]::new((($plain | ForEach-Object { '(?:' + $_ + ')' }) -join '|'), $opt) }
    $specialRx = @($special | ForEach-Object { [regex]::new($_, $opt) })
    $excRx = @(@($c.exclude | Where-Object { $null -ne $_ -and "$_" -ne '' }) | ForEach-Object { [regex]::new([string]$_, $opt) })
    $relax = @($c.relax_global | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $entries.Add([pscustomobject]@{
      commodity = $c; inc = $combined; incSpecial = $specialRx; exc = $excRx; relax = $relax
      incPatterns = $incs
      hasInc = (($null -ne $combined) -or ($specialRx.Count -gt 0))
    })
  }
  $core = $null
  if (Get-MatchCoreType) {
    $core = New-Object ThriftyCrew.MatchCore
    $core.Gex = [System.Text.RegularExpressions.Regex[]]@($gex | ForEach-Object { $_.rx })
    $core.GexText = [string[]]@($gex | ForEach-Object { $_.text })
    $n = $entries.Count
    $inc = New-Object 'System.Text.RegularExpressions.Regex[]' $n
    $incS = New-Object 'System.Text.RegularExpressions.Regex[][]' $n
    $exc = New-Object 'System.Text.RegularExpressions.Regex[][]' $n
    $relax = New-Object 'string[][]' $n
    $has = New-Object 'bool[]' $n
    $req = New-Object 'string[][]' $n
    for ($i = 0; $i -lt $n; $i++) {
      $e = $entries[$i]
      $inc[$i] = $e.inc
      $incS[$i] = [System.Text.RegularExpressions.Regex[]]@($e.incSpecial)
      $exc[$i] = [System.Text.RegularExpressions.Regex[]]@($e.exc)
      $relax[$i] = [string[]]@($e.relax)
      $has[$i] = [bool]$e.hasInc
      # The prefilter is only sound when EVERY include pattern yields a required literal. One pattern
      # with none (a bare alternation, an all-escape pattern) means the entry could match a name carrying
      # no token at all, so the entry must always be tested.
      $toks = New-Object System.Collections.Generic.List[string]
      $sound = $true
      foreach ($p in @($e.incPatterns)) {
        $t = [ThriftyCrew.MatchCore]::RequiredLiteral([string]$p)
        if ($null -eq $t) { $sound = $false; break }
        $toks.Add($t)
      }
      $req[$i] = $(if ($sound -and $toks.Count) { [string[]]$toks.ToArray() } else { $null })
    }
    $core.Inc = $inc; $core.IncSpecial = $incS; $core.Exc = $exc; $core.Relax = $relax; $core.HasInc = $has; $core.Req = $req
    # INDIVIDUAL includes, for ResolveDetail only. Built here rather than lazily because the matcher is
    # constructed once per run and this is ~1,450 more compiled regexes - measured below a tenth of a
    # second, against a table that has to name the pattern that fired on every board cell.
    $incE = New-Object 'System.Text.RegularExpressions.Regex[][]' $n
    $incT = New-Object 'string[][]' $n
    for ($i = 0; $i -lt $n; $i++) {
      $pats = @($entries[$i].incPatterns)
      $incE[$i] = [System.Text.RegularExpressions.Regex[]]@($pats | ForEach-Object { [regex]::new([string]$_, $opt) })
      $incT[$i] = [string[]]@($pats | ForEach-Object { [string]$_ })
    }
    $core.IncEach = $incE; $core.IncEachText = $incT
  }
  return [pscustomobject]@{ gex = $gex; entries = $entries; core = $core }
}

function Resolve-CommodityDetail {
  <#
    THE SAME ANSWER, PLUS ITS REASONS. Returns the winning commodity exactly as Resolve-Commodity does,
    and alongside it the three facts a board cell has never been able to state:
        include_hit      the exact pattern text that claimed this product
        include_hit_ix   its index in that commodity's include array (the short token the page renders,
                         so 3,000 cells do not ship hundreds of KB of regex text - section 10.19)
        excludes_tested  how many of that commodity's excludes were evaluated and missed
        candidates       every OTHER commodity that also wanted this product and was not excluded -
                         the "contested" set, decided today by array order alone
    Used by the identity emission in compare-deals; the board's own hot loop still calls
    Resolve-Commodity. test-match-lib proves the two agree on every name in the live corpus.
  #>
  param([Parameter(Mandatory)]$Matcher, [string]$Name = '')
  if ($null -eq $Name) { $Name = '' }
  $texts = Get-MatchTexts $Name
  $n = $texts[0]; $v = $texts[1]
  if ($null -ne $Matcher.core) {
    $others = New-Object System.Collections.Generic.List[int]
    $winPat = 0
    $idx = $Matcher.core.ResolveDetail($n, $v, $others, [ref]$winPat)
    if ($idx -lt 0) {
      return [pscustomobject]@{ commodity = $null; include_hit = ''; include_hit_ix = -1; excludes_tested = 0; candidates = @() }
    }
    $e = $Matcher.entries[$idx]
    $hit = ''
    if ($winPat -ge 0 -and $winPat -lt @($e.incPatterns).Count) { $hit = [string]@($e.incPatterns)[$winPat] }
    return [pscustomobject]@{
      commodity = $e.commodity
      include_hit = $hit
      include_hit_ix = $winPat
      excludes_tested = $Matcher.core.ExcludeCount($idx)
      candidates = @($others | ForEach-Object { [string]$Matcher.entries[$_].commodity.id })
    }
  }
  # FALLBACK (no Add-Type): the interpreted twin, same order, same predicate. Rare, and covered by the
  # same corpus assertion in test-match-lib, so it cannot drift from the compiled one silently either.
  $ghits = $null
  foreach ($g in $Matcher.gex) { if ($g.rx.IsMatch($n)) { if ($null -eq $ghits) { $ghits = New-Object System.Collections.Generic.List[string] }; $ghits.Add($g.text) } }
  $win = $null; $winHit = ''; $winIx = -1; $winExc = 0
  $cands = New-Object System.Collections.Generic.List[string]
  foreach ($e in $Matcher.entries) {
    if (-not $e.hasInc) { continue }
    $hit = $false
    if ($null -ne $e.inc) { if ($e.inc.IsMatch($n) -or $e.inc.IsMatch($v)) { $hit = $true } }
    if (-not $hit -and $e.incSpecial.Count) {
      foreach ($rx in $e.incSpecial) { if ($rx.IsMatch($n) -or $rx.IsMatch($v)) { $hit = $true; break } }
    }
    if (-not $hit) { continue }
    if ($null -ne $ghits) {
      $blocked = $false
      foreach ($g in $ghits) { if ($e.relax -notcontains $g) { $blocked = $true; break } }
      if ($blocked) { continue }
    }
    $bad = $false
    foreach ($rx in $e.exc) { if ($rx.IsMatch($n)) { $bad = $true; break } }
    if ($bad) { continue }
    if ($null -eq $win) {
      $win = $e; $winExc = @($e.exc).Count
      $pats = @($e.incPatterns)
      for ($p = 0; $p -lt $pats.Count; $p++) {
        $rx = [regex]::new([string]$pats[$p], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($rx.IsMatch($n) -or $rx.IsMatch($v)) { $winHit = [string]$pats[$p]; $winIx = $p; break }
      }
    } else { $cands.Add([string]$e.commodity.id) }
  }
  if ($null -eq $win) { return [pscustomobject]@{ commodity = $null; include_hit = ''; include_hit_ix = -1; excludes_tested = 0; candidates = @() } }
  return [pscustomobject]@{ commodity = $win.commodity; include_hit = $winHit; include_hit_ix = $winIx; excludes_tested = $winExc; candidates = @($cands) }
}

function Resolve-Commodity {
  # $Name is NOT Mandatory, deliberately: the original accepts an empty name and returns $null for it,
  # and Mandatory would reject '' at the binder as a crash. The identity harness found this on its
  # first run - the one adversarial case that differed was the empty string.
  param([Parameter(Mandatory)]$Matcher, [string]$Name = '')
  if ($null -eq $Name) { $Name = '' }
  $texts = Get-MatchTexts $Name
  $n = $texts[0]; $v = $texts[1]
  if ($null -ne $Matcher.core) {
    $idx = $Matcher.core.Resolve($n, $v)
    if ($idx -lt 0) { return $null }
    return $Matcher.entries[$idx].commodity
  }
  # global prepared-food tokens that hit the RAW name (usually none)
  $ghits = $null
  foreach ($g in $Matcher.gex) { if ($g.rx.IsMatch($n)) { if ($null -eq $ghits) { $ghits = New-Object System.Collections.Generic.List[string] }; $ghits.Add($g.text) } }
  foreach ($e in $Matcher.entries) {
    if (-not $e.hasInc) { continue }
    $hit = $false
    if ($null -ne $e.inc) { if ($e.inc.IsMatch($n) -or $e.inc.IsMatch($v)) { $hit = $true } }
    if (-not $hit -and $e.incSpecial.Count) {
      foreach ($rx in $e.incSpecial) { if ($rx.IsMatch($n) -or $rx.IsMatch($v)) { $hit = $true; break } }
    }
    if (-not $hit) { continue }
    if ($null -ne $ghits) {
      $blocked = $false
      foreach ($g in $ghits) { if ($e.relax -notcontains $g) { $blocked = $true; break } }
      if ($blocked) { continue }
    }
    $bad = $false
    foreach ($rx in $e.exc) { if ($rx.IsMatch($n)) { $bad = $true; break } }
    if ($bad) { continue }
    return $e.commodity
  }
  return $null
}
