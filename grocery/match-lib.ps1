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

  BOUNDED-TIME MATCHING (2026-09-19, backlog I183, I208, I209). Every regex here is built with a
  MatchTimeout (default 250 ms), because .NET Framework's engine backtracks and a catalogue include is
  machine-written as often as hand-written. audit-coverage-gaps.ps1's header is the estate's own incident:
  one ambiguous include once blocked the daily pipeline for 11 hours. A timeout alone would only turn a
  hang into an uncaught RegexMatchTimeoutException that aborts the whole board build, so the compiled core
  and the PowerShell twin both CATCH it and score that name COULD-NOT-LOOK, which is never the same answer
  as no-match ([[a-could-not-look-must-not-settle-the-question]]):
    * first-match-wins means a commodity that could not be decided makes every LATER answer unknowable, so
      the name resolves to nothing and is recorded as could-not-look, with the commodity and the kind
      (include / exclude / global) that could not be decided. A definite hit elsewhere still wins where the
      order allows it: an include that times out on the raw name but matches the variant is a hit, and an
      exclude that fires is a definite exclusion whatever a sibling exclude did.
    * a per-regex CIRCUIT BREAKER, as audit-coverage-gaps has: after 3 timeouts a regex is quarantined for
      the rest of the run and every later look at it is could-not-look without running it, so one bad
      pattern costs at most 3 bounds and not one bound per name. A commodity's plain includes are ONE
      combined regex, so that breaker is per commodity.
    * Get-CommodityMatcherBlind reads it all back; compare-deals prints it, writes it into the board's
      health block and the flagged file, and check-ad-cycles pages it; the identity table does not record a
      could-not-look name as unmatched, because a stored "no commodity owns this" is reused next run.
  Why 250 ms: on the 2026-09-19 corpus (42,753 distinct names, board 2026-09-17) the slowest single
  Resolve was 15.1 ms in a cold pass (under 2 ms re-timed) and the slowest single regex on a real name
  6.3 ms, so the bound sits more than 16x above anything a real name costs; it is also the bound
  audit-coverage-gaps has run with since 2026-08-14. It was the only value tried. Measured by I209 on
  Framework 4: a 250 ms timeout costs 2 to 4 percent on ordinary matches. NOT RegexOptions.Compiled: I209
  measured it SLOWER here on a catalogue-shaped pattern and 89 to 125 ms dearer to build.

  Usage:
      . match-lib.ps1
      $m = New-CommodityMatcher -Commodities $commodities -GlobalExclude $GLOBAL_EXCLUDE
      $c = Resolve-Commodity -Matcher $m -Name $productName      # -> commodity object or $null
      $b = Get-CommodityMatcherBlind -Matcher $m                 # -> what could not be decided, and why
  Self-test:  powershell -File grocery\match-lib.ps1 -SelfTest   (hermetic: frozen catalogue, no board)
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
  // One regex match that hit its MatchTimeout. Entry is the commodity index (-1 for a global exclude).
  public sealed class MatchTimeoutNote {
    public string Kind; public int Entry; public string Pattern; public string Name; public bool Quarantined;
  }
  // One name the matcher could not decide, and the first commodity (and kind) that made it undecidable.
  public sealed class MatchBlindNote {
    public string Name; public int Entry; public string Kind;
  }
  public sealed class BoundedMatchCore {
    // Resolve's answer for a name it could not decide. Never -1, which means "no commodity owns it".
    public const int CouldNotLook = -2;
    public int BreakerLimit = 3;
    public List<MatchTimeoutNote> Timeouts = new List<MatchTimeoutNote>();
    public List<MatchBlindNote> Blind = new List<MatchBlindNote>();
    public int QuarantineSkips;    // looks answered could-not-look WITHOUT running, because the regex was quarantined
    // Keyed by Regex REFERENCE (Regex does not override Equals). Consulted only once it is non-empty, so a
    // run with no timeout pays one Count read per match and nothing else.
    Dictionary<Regex, int> _dead = new Dictionary<Regex, int>();
    // 1 = match, 0 = no match, -1 = could not look (timed out now, or quarantined by the breaker).
    int Look(Regex rx, string s, int entry, string kind) {
      int n = 0;
      if (_dead.Count != 0 && _dead.TryGetValue(rx, out n) && n >= BreakerLimit) { QuarantineSkips++; return -1; }
      try { return rx.IsMatch(s) ? 1 : 0; }
      catch (RegexMatchTimeoutException) {
        n = n + 1; _dead[rx] = n;
        Timeouts.Add(new MatchTimeoutNote { Kind = kind, Entry = entry, Pattern = rx.ToString(), Name = s, Quarantined = n >= BreakerLimit });
        return -1;
      }
    }
    // An entry's include verdict, in the original's order: combined (raw, variant), then each special
    // (raw, variant), first definite hit wins. A timeout only matters if nothing after it hits.
    int LookInclude(int i, string raw, string variant) {
      bool blind = false; int r;
      if (Inc[i] != null) {
        r = Look(Inc[i], raw, i, "include"); if (r == 1) return 1; if (r < 0) blind = true;
        r = Look(Inc[i], variant, i, "include"); if (r == 1) return 1; if (r < 0) blind = true;
      }
      if (IncSpecial[i] != null) {
        foreach (var rx in IncSpecial[i]) {
          r = Look(rx, raw, i, "include"); if (r == 1) return 1; if (r < 0) blind = true;
          r = Look(rx, variant, i, "include"); if (r == 1) return 1; if (r < 0) blind = true;
        }
      }
      return blind ? -1 : 0;
    }
    // 1 = excluded, 0 = every exclude missed, -1 = none fired but one could not be decided.
    int LookExclude(int i, string raw) {
      if (Exc[i] == null) return 0;
      bool blind = false;
      foreach (var rx in Exc[i]) { int r = Look(rx, raw, i, "exclude"); if (r == 1) return 1; if (r < 0) blind = true; }
      return blind ? -1 : 0;
    }
    // The global-exclude pass: definite hits and undecided texts, separately.
    void LookGlobals(string raw, out List<string> ghits, out List<string> gblind) {
      ghits = null; gblind = null;
      for (int g = 0; g < Gex.Length; g++) {
        int r = Look(Gex[g], raw, -1, "global");
        if (r == 1) { if (ghits == null) ghits = new List<string>(); ghits.Add(GexText[g]); }
        else if (r < 0) { if (gblind == null) gblind = new List<string>(); gblind.Add(GexText[g]); }
      }
    }
    // After an include hit: 1 = blocked by a definite global hit it does not relax, -1 = an undecided global
    // it does not relax could block it, 0 = clear. A definite block wins over an undecided one.
    int GlobalGate(int i, List<string> ghits, List<string> gblind) {
      if (ghits != null) { foreach (var g in ghits) { if (Array.IndexOf(Relax[i], g) < 0) return 1; } }
      if (gblind != null) { foreach (var g in gblind) { if (Array.IndexOf(Relax[i], g) < 0) return -1; } }
      return 0;
    }
    int NoteBlind(string raw, int entry, string kind) {
      Blind.Add(new MatchBlindNote { Name = raw, Entry = entry, Kind = kind });
      return CouldNotLook;
    }
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
    // Returns the index of the winning entry, -1 for none, or CouldNotLook (-2) when an entry that comes
    // before any winner could not be decided inside the bound.
    public int Resolve(string raw, string variant) {
      List<string> ghits, gblind;
      LookGlobals(raw, out ghits, out gblind);
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
        int hit = LookInclude(i, raw, variant);
        if (hit == 0) continue;
        if (hit < 0) return NoteBlind(raw, i, "include");
        int gate = GlobalGate(i, ghits, gblind);
        if (gate > 0) continue;
        if (gate < 0) return NoteBlind(raw, i, "global");
        int bad = LookExclude(i, raw);
        if (bad > 0) continue;
        if (bad < 0) return NoteBlind(raw, i, "exclude");
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
    // Could-not-look: an undecidable entry BEFORE the winner makes the answer undecidable (CouldNotLook, as
    // Resolve). One AFTER the winner cannot change the winner, so it is left out of the contested set and
    // stays on record in Timeouts; the contested set is advisory, the winner is not. A winning pattern that
    // times out while being NAMED is skipped, so winPat can come back -1 on a winner, which test-match-lib
    // already reports as a matched name with no include_hit.
    public int ResolveDetail(string raw, string variant, List<int> others, out int winPat) {
      winPat = -1;
      int winner = -1;
      List<string> ghits, gblind;
      LookGlobals(raw, out ghits, out gblind);
      if (_idx == null) BuildIndex();
      var cand = new bool[Inc.Length];
      Collect(raw, cand);
      if (!ReferenceEquals(variant, raw) && variant != raw) Collect(variant, cand);
      for (int i = 0; i < Inc.Length; i++) {
        if (!HasInc[i]) continue;
        if (!_always[i] && !cand[i]) continue;
        int hit = LookInclude(i, raw, variant);
        if (hit == 0) continue;
        if (hit < 0) { if (winner < 0) return NoteBlind(raw, i, "include"); continue; }
        int gate = GlobalGate(i, ghits, gblind);
        if (gate > 0) continue;
        if (gate < 0) { if (winner < 0) return NoteBlind(raw, i, "global"); continue; }
        int bad = LookExclude(i, raw);
        if (bad > 0) continue;
        if (bad < 0) { if (winner < 0) return NoteBlind(raw, i, "exclude"); continue; }
        if (winner < 0) {
          winner = i;
          if (IncEach != null && IncEach[i] != null) {
            for (int p = 0; p < IncEach[i].Length; p++) {
              if (Look(IncEach[i][p], raw, i, "include-name") == 1 || Look(IncEach[i][p], variant, i, "include-name") == 1) { winPat = p; break; }
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
  if ('ThriftyCrew.BoundedMatchCore' -as [type]) { $script:MatchCoreLoaded = $true; return $true }
  try { Add-Type -TypeDefinition $script:MatchCoreSource -Language CSharp -ErrorAction Stop | Out-Null; $script:MatchCoreLoaded = $true; return $true }
  catch { $script:MatchCoreLoaded = $false; return $false }
}

function New-MatchLookState([int]$BreakerLimit = 3) {
  # The PowerShell twin's timeout bookkeeping, the same four facts BoundedMatchCore keeps. dead is keyed by
  # the Regex OBJECT, which a hashtable compares by reference, exactly as the C# dictionary does.
  return @{ limit = $BreakerLimit; dead = @{}; skips = 0
            timeouts = (New-Object System.Collections.ArrayList); blind = (New-Object System.Collections.ArrayList) }
}

function New-CommodityMatcher {
  param(
    [Parameter(Mandatory)]$Commodities,
    [Parameter(Mandatory)][string[]]$GlobalExclude,
    # THE BOUND, per regex match. 250 ms: see the header for the measurement that chose it. Floored at 25 ms,
    # as audit-coverage-gaps floors its own, so a typo cannot make every ordinary match a timeout.
    [int]$MatchTimeoutMs = 250,
    [int]$BreakerLimit = 3
  )
  $opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  $span = [TimeSpan]::FromMilliseconds([Math]::Max(25, $MatchTimeoutMs))
  $gex = New-Object System.Collections.Generic.List[object]
  foreach ($g in $GlobalExclude) {
    $gex.Add([pscustomobject]@{ text = [string]$g; rx = [regex]::new([string]$g, $opt, $span) })
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
    if ($plain.Count) { $combined = [regex]::new((($plain | ForEach-Object { '(?:' + $_ + ')' }) -join '|'), $opt, $span) }
    $specialRx = @($special | ForEach-Object { [regex]::new($_, $opt, $span) })
    $excRx = @(@($c.exclude | Where-Object { $null -ne $_ -and "$_" -ne '' }) | ForEach-Object { [regex]::new([string]$_, $opt, $span) })
    $relax = @($c.relax_global | Where-Object { $_ } | ForEach-Object { [string]$_ })
    # incAll is the include ORDER both paths test in: the combined alternation, then each special.
    $incAll = @(@($combined) + $specialRx | Where-Object { $null -ne $_ })
    # Every include compiled INDIVIDUALLY, in file order: which one fired, for the detail scan only. Built once
    # here for both paths (the interpreted twin used to build one per winning pattern per name).
    $incEach = @($incs | ForEach-Object { [regex]::new([string]$_, $opt, $span) })
    $entries.Add([pscustomobject]@{
      commodity = $c; inc = $combined; incSpecial = $specialRx; exc = $excRx; relax = $relax
      incPatterns = $incs; incAll = $incAll; incEach = $incEach
      hasInc = (($null -ne $combined) -or ($specialRx.Count -gt 0))
    })
  }
  $core = $null
  if (Get-MatchCoreType) {
    $core = New-Object ThriftyCrew.BoundedMatchCore
    $core.BreakerLimit = $BreakerLimit
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
        $t = [ThriftyCrew.BoundedMatchCore]::RequiredLiteral([string]$p)
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
      $incE[$i] = [System.Text.RegularExpressions.Regex[]]@($entries[$i].incEach)
      $incT[$i] = [string[]]@($pats | ForEach-Object { [string]$_ })
    }
    $core.IncEach = $incE; $core.IncEachText = $incT
  }
  return [pscustomobject]@{ gex = $gex; entries = $entries; core = $core; span = $span; look = (New-MatchLookState $BreakerLimit) }
}

function Add-MatchTimeoutNote($L, $Rx, [string]$Text, [int]$Entry, [string]$Kind) {
  # Called only when a match has just timed out, so the bookkeeping costs nothing on a clean call.
  $n = [int]$L.dead[$Rx] + 1
  $L.dead[$Rx] = $n
  [void]$L.timeouts.Add([pscustomobject]@{ Kind = $Kind; Entry = $Entry; Pattern = $Rx.ToString(); Name = $Text; Quarantined = ($n -ge $L.limit) })
}

function Invoke-MatchPsScan {
  <#
    THE INTERPRETED TWIN of BoundedMatchCore.Resolve (and, with -Detail, ResolveDetail): same order, same
    predicate, same could-not-look rule, used only when Add-Type is unavailable. Every look is
    1 = match, 0 = no match, -1 = could not look (timed out now, or quarantined by the breaker), written
    inline rather than as a helper call because this path runs ~1,200 looks per name with no prefilter.
    Returns idx (entry index, -1 none, -2 could not look), and for -Detail the contested set and the
    winning pattern's index.
  #>
  param($Matcher, [string]$N, [string]$V, [switch]$Detail)
  $L = $Matcher.look
  if ($null -eq $L) { $L = New-MatchLookState; $Matcher | Add-Member -NotePropertyName look -NotePropertyValue $L -Force }
  # FAST PATH: the pre-2026-09-19 loop, verbatim, inside ONE try. While no regex is quarantined and no match
  # times out it decides exactly as the precise scan below, near the old speed. Measured 2026-09-19 over the
  # first 2,000 corpus names, two rounds each: the old loop 4.7 s, the precise scan alone 8.0 to 8.4 s, with this
  # fast path 5.2 to 5.5 s, answers identical. A timeout abandons it for the precise scan, which re-runs the name
  # and RECORDS what it could not decide - so until the breaker trips, an undecidable name pays two bounds here.
  if ($L.dead.Count -eq 0) {
    try {
      $ghits = $null
      foreach ($g in $Matcher.gex) { if ($g.rx.IsMatch($N)) { if ($null -eq $ghits) { $ghits = New-Object System.Collections.Generic.List[string] }; $ghits.Add($g.text) } }
      $win = -1; $winIx = -1
      $others = New-Object System.Collections.Generic.List[int]
      for ($i = 0; $i -lt $Matcher.entries.Count; $i++) {
        $e = $Matcher.entries[$i]
        if (-not $e.hasInc) { continue }
        $hit = $false
        foreach ($rx in $e.incAll) { if ($rx.IsMatch($N) -or $rx.IsMatch($V)) { $hit = $true; break } }
        if (-not $hit) { continue }
        if ($null -ne $ghits) {
          $blocked = $false
          foreach ($g in $ghits) { if ($e.relax -notcontains $g) { $blocked = $true; break } }
          if ($blocked) { continue }
        }
        $bad = $false
        foreach ($rx in $e.exc) { if ($rx.IsMatch($N)) { $bad = $true; break } }
        if ($bad) { continue }
        if ($win -lt 0) {
          $win = $i
          if (-not $Detail) { break }
          $each = @($e.incEach)
          for ($p = 0; $p -lt $each.Count; $p++) { if ($each[$p].IsMatch($N) -or $each[$p].IsMatch($V)) { $winIx = $p; break } }
        } else { $others.Add($i) }
      }
      return [pscustomobject]@{ idx = $win; others = $others; winIx = $winIx }
    } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] { }
  }
  $ghits = $null; $gblind = $null
  foreach ($g in $Matcher.gex) {
    $r = 0
    if ($L.dead.Count -and [int]$L.dead[$g.rx] -ge $L.limit) { $L.skips = [int]$L.skips + 1; $r = -1 }
    else { try { if ($g.rx.IsMatch($N)) { $r = 1 } } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] { $r = -1; Add-MatchTimeoutNote $L $g.rx $N -1 'global' } }
    if ($r -eq 1) { if ($null -eq $ghits) { $ghits = New-Object System.Collections.Generic.List[string] }; $ghits.Add($g.text) }
    elseif ($r -lt 0) { if ($null -eq $gblind) { $gblind = New-Object System.Collections.Generic.List[string] }; $gblind.Add($g.text) }
  }
  $win = -1; $winIx = -1
  $others = New-Object System.Collections.Generic.List[int]
  $texts = @($N, $V)
  for ($i = 0; $i -lt $Matcher.entries.Count; $i++) {
    $e = $Matcher.entries[$i]
    if (-not $e.hasInc) { continue }
    $hit = 0
    foreach ($rx in $e.incAll) {
      foreach ($s in $texts) {
        $r = 0
        if ($L.dead.Count -and [int]$L.dead[$rx] -ge $L.limit) { $L.skips = [int]$L.skips + 1; $r = -1 }
        else { try { if ($rx.IsMatch($s)) { $r = 1 } } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] { $r = -1; Add-MatchTimeoutNote $L $rx $s $i 'include' } }
        if ($r -eq 1) { $hit = 1; break }
        if ($r -lt 0) { $hit = -1 }
      }
      if ($hit -eq 1) { break }
    }
    if ($hit -eq 0) { continue }
    $kind = ''
    if ($hit -lt 0) { $kind = 'include' }
    else {
      $gate = 0
      if ($null -ne $ghits) { foreach ($g in $ghits) { if ($e.relax -notcontains $g) { $gate = 1; break } } }
      if ($gate -eq 0 -and $null -ne $gblind) { foreach ($g in $gblind) { if ($e.relax -notcontains $g) { $gate = -1; break } } }
      if ($gate -gt 0) { continue }
      if ($gate -lt 0) { $kind = 'global' }
      else {
        $bad = 0
        foreach ($rx in $e.exc) {
          $r = 0
          if ($L.dead.Count -and [int]$L.dead[$rx] -ge $L.limit) { $L.skips = [int]$L.skips + 1; $r = -1 }
          else { try { if ($rx.IsMatch($N)) { $r = 1 } } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] { $r = -1; Add-MatchTimeoutNote $L $rx $N $i 'exclude' } }
          if ($r -eq 1) { $bad = 1; break }
          if ($r -lt 0) { $bad = -1 }
        }
        if ($bad -gt 0) { continue }
        if ($bad -lt 0) { $kind = 'exclude' }
      }
    }
    if ($kind) {
      # Undecidable BEFORE any winner: the answer is undecidable. AFTER one: left out of the contested set.
      if ($win -lt 0) { [void]$L.blind.Add([pscustomobject]@{ Name = $N; Entry = $i; Kind = $kind }); return [pscustomobject]@{ idx = -2; others = $others; winIx = -1 } }
      continue
    }
    if ($win -lt 0) {
      $win = $i
      if (-not $Detail) { break }
      $each = @($e.incEach)
      for ($p = 0; $p -lt $each.Count; $p++) {
        $named = $false
        foreach ($s in $texts) {
          try { if ($each[$p].IsMatch($s)) { $named = $true } } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] { Add-MatchTimeoutNote $L $each[$p] $s $i 'include-name' }
          if ($named) { break }
        }
        if ($named) { $winIx = $p; break }
      }
    } else { $others.Add($i) }
  }
  return [pscustomobject]@{ idx = $win; others = $others; winIx = $winIx }
}

function Get-CommodityMatcherBlind {
  <#
    WHAT THE MATCHER COULD NOT DECIDE, read back from whichever path ran (the compiled core, or the twin).
      timeouts          regex matches that hit the bound
      quarantine_skips  looks answered could-not-look without running, because the breaker had tripped
      quarantined       the regexes the breaker tripped on, with their commodity and kind
      could_not_look    DISTINCT names resolved to nothing because a commodity before any winner could not
                        be decided; each with that commodity, the kind, and how many times it was looked up
    A could-not-look name is NOT an unmatched name and must never be recorded as one.
  #>
  param([Parameter(Mandatory)]$Matcher)
  $tos = @(); $bl = @(); $skips = 0
  if ($null -ne $Matcher.core) {
    $tos = @($Matcher.core.Timeouts.ToArray()); $bl = @($Matcher.core.Blind.ToArray()); $skips = [int]$Matcher.core.QuarantineSkips
  }
  if ($null -ne $Matcher.look) {
    $tos += @($Matcher.look.timeouts.ToArray()); $bl += @($Matcher.look.blind.ToArray()); $skips += [int]$Matcher.look.skips
  }
  $idOf = { param($ix) if ($ix -ge 0 -and $ix -lt $Matcher.entries.Count) { [string]$Matcher.entries[$ix].commodity.id } else { '(global exclude)' } }
  $byName = [ordered]@{}
  foreach ($b in $bl) {
    $k = [string]$b.Name
    if ($byName.Contains($k)) { $byName[$k].looks++ ; continue }
    $byName[$k] = [pscustomobject]@{ name = $k; commodity = (& $idOf ([int]$b.Entry)); kind = [string]$b.Kind; looks = 1 }
  }
  $q = [ordered]@{}
  foreach ($t in @($tos | Where-Object { $_.Quarantined })) {
    $k = [string]$t.Entry + '|' + [string]$t.Kind + '|' + [string]$t.Pattern
    if (-not $q.Contains($k)) {
      $pt = [string]$t.Pattern
      $q[$k] = [pscustomobject]@{ commodity = (& $idOf ([int]$t.Entry)); kind = [string]$t.Kind; pattern = $(if ($pt.Length -gt 200) { $pt.Substring(0, 200) + '...' } else { $pt }) }
    }
  }
  return [pscustomobject]@{
    timeout_ms = $(if ($Matcher.span) { [int]$Matcher.span.TotalMilliseconds } else { 0 })
    timeouts = $tos.Count
    quarantine_skips = $skips
    quarantined = @($q.Values)
    could_not_look = @($byName.Values)
  }
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
      # could_not_look = $true is NOT an unmatched product: the matcher ran out of its bound before it could
      # say. A caller that stores "no commodity owns this" must not store it for these.
      return [pscustomobject]@{ commodity = $null; include_hit = ''; include_hit_ix = -1; excludes_tested = 0; candidates = @(); could_not_look = ($idx -eq [ThriftyCrew.BoundedMatchCore]::CouldNotLook) }
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
      could_not_look = $false
    }
  }
  # FALLBACK (no Add-Type): the interpreted twin, same order, same predicate. Rare, and covered by the
  # same corpus assertion in test-match-lib, so it cannot drift from the compiled one silently either.
  $r = Invoke-MatchPsScan -Matcher $Matcher -N $n -V $v -Detail
  if ($r.idx -lt 0) { return [pscustomobject]@{ commodity = $null; include_hit = ''; include_hit_ix = -1; excludes_tested = 0; candidates = @(); could_not_look = ($r.idx -eq -2) } }
  $e = $Matcher.entries[$r.idx]
  $winHit = $(if ($r.winIx -ge 0) { [string]@($e.incPatterns)[$r.winIx] } else { '' })
  return [pscustomobject]@{ commodity = $e.commodity; include_hit = $winHit; include_hit_ix = $r.winIx; excludes_tested = @($e.exc).Count
                            candidates = @($r.others | ForEach-Object { [string]$Matcher.entries[$_].commodity.id }); could_not_look = $false }
}

function Resolve-Commodity {
  # $Name is NOT Mandatory, deliberately: the original accepts an empty name and returns $null for it,
  # and Mandatory would reject '' at the binder as a crash. The identity harness found this on its
  # first run - the one adversarial case that differed was the empty string.
  param([Parameter(Mandatory)]$Matcher, [string]$Name = '')
  if ($null -eq $Name) { $Name = '' }
  $texts = Get-MatchTexts $Name
  $n = $texts[0]; $v = $texts[1]
  # $null for BOTH "no commodity owns this" and "could not look": the board cannot place either row. The
  # difference is recorded on the matcher, and Get-CommodityMatcherBlind is how a caller tells them apart.
  if ($null -ne $Matcher.core) {
    $idx = $Matcher.core.Resolve($n, $v)
    if ($idx -lt 0) { return $null }
    return $Matcher.entries[$idx].commodity
  }
  $r = Invoke-MatchPsScan -Matcher $Matcher -N $n -V $v
  if ($r.idx -lt 0) { return $null }
  return $Matcher.entries[$r.idx].commodity
}

# ---- SELF-TEST (2026-09-19, backlog I183 / I209) --------------------------------------------------------
# The dot-sourced gate form (lib\selftest-discovery.ps1 rule 1): NO param() block, because compare-deals
# dot-sources this file and a param() block would reset the engine's own -SelfTest. Dot-sourced, this is false.
$__matchLibSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
if ($__matchLibSelfTest) {
  # HERMETIC: a frozen five-line catalogue, no board, no commodities.json. Every case runs on BOTH paths - the
  # compiled core production uses and the PowerShell twin used when Add-Type is unavailable.
  #
  # NO STOPWATCH DECIDES A CASE (ops-and-gates.md): the bound is proven by the timeout the code RECORDS and by
  # the MatchTimeout the regex was BUILT with, never by timing a call. THE VICTIM IS SIZED FOR A NEUTERED RUN:
  # the founding include below is I208's cubic chicken-breast shape, and 'boneless' + 800 spaces costs it
  # several seconds unbounded (measured 2026-09-19 on this box: 500 spaces 769 ms, 600 1,274 ms, 700 2,933 ms),
  # so the 250 ms bound fires with room on a faster machine and a neutered bound goes red in seconds, not a hang.
  $ErrorActionPreference = 'Stop'
  $bad = 0; $ran = 0
  function _MT([string]$label, [bool]$ok, [string]$got) {
    $script:ran++
    if ($ok) { Write-Output ('  ok    ' + $label) } else { Write-Output ('  FAIL  ' + $label + '   got: ' + $got); $script:bad++ }
  }
  $FOUNDING = '(?:boneless|skinless)\s*[,&/ ]+\s*(?:boneless|skinless)[^,]*chicken\s+breast'
  $ATOMIC   = '(?:boneless|skinless)(?>\s*[,&/ ]+\s*)(?:boneless|skinless)[^,]*chicken\s+breast'
  $VICTIM   = 'boneless' + (' ' * 800) + 'x chicken breast'
  $NOGLOBAL = @('zz-fixture-global-that-never-matches-zz')
  function _Cat([object[]]$rows) { return @($rows | ForEach-Object { [pscustomobject]@{ id = $_[0]; include = @($_[1]); exclude = @($_[2]); relax_global = @($_[3]) } }) }
  function _Paths($m) {
    # the compiled core, and the interpreted twin over the SAME entries with its own bookkeeping
    $ps = [pscustomobject]@{ gex = $m.gex; entries = $m.entries; core = $null; span = $m.span; look = (New-MatchLookState) }
    $out = @()
    if ($null -ne $m.core) { $out += ,@('compiled', $m) } else { Write-Output '  FAIL  the compiled core did not load, so the path production runs is unproven'; $script:bad++ }
    $out += ,@('ps-twin', $ps)
    return ,$out
  }
  function _Id($c) { if ($c) { [string]$c.id } else { '<none>' } }
  try {
    # --- MUST FIRE: an include that cannot be decided makes the NAME could-not-look, never no-match ------
    # fixture-redos comes FIRST, so first-match-wins means nobody can say fixture-breast owns the victim. A
    # catch that scored the timeout as a miss would answer fixture-breast here - the silent wrong answer.
    $cat = _Cat @(@('fixture-redos', $FOUNDING, @(), @()), @('fixture-breast', 'chicken\s+breast', @(), @()))
    $m = New-CommodityMatcher -Commodities $cat -GlobalExclude $NOGLOBAL
    _MT 'MUST FIRE  every regex is BUILT with the configured 250 ms bound' ($m.entries[0].inc.MatchTimeout.TotalMilliseconds -eq 250 -and $m.entries[0].incEach[0].MatchTimeout.TotalMilliseconds -eq 250 -and $m.gex[0].rx.MatchTimeout.TotalMilliseconds -eq 250) ([string]$m.entries[0].inc.MatchTimeout)
    foreach ($pp in (_Paths $m)) {
      $path = $pp[0]; $mm = $pp[1]
      $c = Resolve-Commodity -Matcher $mm -Name $VICTIM
      $b = Get-CommodityMatcherBlind -Matcher $mm
      _MT ("MUST FIRE  [$path] a timed-out include resolves to nothing, NOT to the later fixture-breast") ($null -eq $c) (_Id $c)
      _MT ("MUST FIRE  [$path] the timeout is RECORDED") ($b.timeouts -ge 1) ("timeouts=" + $b.timeouts)
      $cl = @($b.could_not_look)
      _MT ("MUST FIRE  [$path] the name is recorded could-not-look against fixture-redos/include") ($cl.Count -eq 1 -and $cl[0].commodity -eq 'fixture-redos' -and $cl[0].kind -eq 'include') (($cl | ForEach-Object { $_.commodity + '/' + $_.kind }) -join ',')
      # --- MUST FIRE: the breaker. After 3 timeouts the regex is quarantined and costs nothing more -----
      $answers = @(); foreach ($k in 1..5) { $answers += (_Id (Resolve-Commodity -Matcher $mm -Name $VICTIM)) }
      $b = Get-CommodityMatcherBlind -Matcher $mm
      _MT ("MUST FIRE  [$path] the breaker stops at exactly 3 timeouts over 6 looks") ($b.timeouts -eq 3) ("timeouts=" + $b.timeouts)
      _MT ("MUST FIRE  [$path] later looks are answered by the quarantine, without running") ($b.quarantine_skips -ge 1 -and @($b.quarantined | Where-Object { $_.commodity -eq 'fixture-redos' -and $_.kind -eq 'include' }).Count -eq 1) ("skips=" + $b.quarantine_skips + " quarantined=" + @($b.quarantined).Count)
      _MT ("MUST FIRE  [$path] a quarantined include is STILL could-not-look, never no-match") (@($answers | Where-Object { $_ -ne '<none>' }).Count -eq 0) ($answers -join ',')
      $d = Resolve-CommodityDetail -Matcher $mm -Name $VICTIM
      _MT ("MUST FIRE  [$path] the detail scan says could_not_look, so the identity table will not store it as unmatched") ($d.could_not_look -eq $true -and $null -eq $d.commodity) ("could_not_look=" + $d.could_not_look + " commodity=" + (_Id $d.commodity))
    }
    # --- MUST FIRE: an undecidable GLOBAL exclude blocks the answer unless the commodity relaxes it ------
    $catG = _Cat @(,@('fixture-breast', 'chicken\s+breast', @(), @()))
    $mG = New-CommodityMatcher -Commodities $catG -GlobalExclude @($FOUNDING)
    $catR = _Cat @(,@('fixture-breast', 'chicken\s+breast', @(), @($FOUNDING)))
    $mR = New-CommodityMatcher -Commodities $catR -GlobalExclude @($FOUNDING)
    foreach ($pp in (_Paths $mG)) {
      $c = Resolve-Commodity -Matcher $pp[1] -Name $VICTIM; $cl = @((Get-CommodityMatcherBlind -Matcher $pp[1]).could_not_look)
      _MT ("MUST FIRE  [$($pp[0])] an undecided global exclude the commodity does not relax is could-not-look/global") ($null -eq $c -and $cl.Count -eq 1 -and $cl[0].kind -eq 'global') ((_Id $c) + ' ' + (($cl | ForEach-Object { $_.kind }) -join ','))
    }
    foreach ($pp in (_Paths $mR)) {
      $c = Resolve-Commodity -Matcher $pp[1] -Name $VICTIM
      _MT ("CLEAN TWIN  [$($pp[0])] a commodity that RELAXES that global still wins") ((_Id $c) -eq 'fixture-breast') (_Id $c)
    }
    # --- MUST FIRE: an undecided EXCLUDE; CLEAN TWIN: a definite sibling exclude still excludes ---------
    $catX = _Cat @(@('fixture-meat', 'chicken', @($FOUNDING), @()), @('fixture-breast', 'chicken\s+breast', @(), @()))
    $mX = New-CommodityMatcher -Commodities $catX -GlobalExclude $NOGLOBAL
    $catY = _Cat @(@('fixture-meat', 'chicken', @($FOUNDING, 'chicken'), @()), @('fixture-breast', 'chicken\s+breast', @(), @()))
    $mY = New-CommodityMatcher -Commodities $catY -GlobalExclude $NOGLOBAL
    foreach ($pp in (_Paths $mX)) {
      $c = Resolve-Commodity -Matcher $pp[1] -Name $VICTIM; $cl = @((Get-CommodityMatcherBlind -Matcher $pp[1]).could_not_look)
      _MT ("MUST FIRE  [$($pp[0])] an undecided exclude is could-not-look/exclude, not a win for fixture-meat") ($null -eq $c -and $cl.Count -eq 1 -and $cl[0].commodity -eq 'fixture-meat' -and $cl[0].kind -eq 'exclude') ((_Id $c) + ' ' + (($cl | ForEach-Object { $_.commodity + '/' + $_.kind }) -join ','))
    }
    foreach ($pp in (_Paths $mY)) {
      $c = Resolve-Commodity -Matcher $pp[1] -Name $VICTIM; $cl = @((Get-CommodityMatcherBlind -Matcher $pp[1]).could_not_look)
      _MT ("CLEAN TWIN  [$($pp[0])] an exclude that FIRES excludes, whatever a timed-out sibling did, and the next commodity wins") ((_Id $c) -eq 'fixture-breast' -and $cl.Count -eq 0) ((_Id $c) + ' blind=' + $cl.Count)
    }
    # --- CLEAN TWIN: ordinary names decide exactly as before, with nothing recorded ---------------------
    foreach ($pp in (_Paths (New-CommodityMatcher -Commodities $cat -GlobalExclude $NOGLOBAL))) {
      $got = @(); foreach ($nm in @('Boneless, Skinless Chicken Breast 3 lb', 'Tyson chicken breast tenders', 'Great Value Quick Grits, 24 oz')) { $got += (_Id (Resolve-Commodity -Matcher $pp[1] -Name $nm)) }
      $b = Get-CommodityMatcherBlind -Matcher $pp[1]
      _MT ("CLEAN TWIN  [$($pp[0])] ordinary names still resolve (redos, breast, none) with 0 timeouts") (($got -join ',') -eq 'fixture-redos,fixture-breast,<none>' -and $b.timeouts -eq 0 -and @($b.could_not_look).Count -eq 0) (($got -join ',') + ' timeouts=' + $b.timeouts)
      $d = Resolve-CommodityDetail -Matcher $pp[1] -Name 'Boneless & Skinless Chicken Breast'
      _MT ("CLEAN TWIN  [$($pp[0])] the detail scan still names the include that fired") ($d.could_not_look -eq $false -and $d.include_hit -eq $FOUNDING -and (_Id $d.commodity) -eq 'fixture-redos') ($d.include_hit + ' / ' + (_Id $d.commodity))
    }
    # --- CLEAN TWIN (I208): the atomic rewrite decides the victim with NO timeout, and answers as before --
    $catA = _Cat @(@('fixture-redos', $ATOMIC, @(), @()), @('fixture-breast', 'chicken\s+breast', @(), @()))
    $mA = New-CommodityMatcher -Commodities $catA -GlobalExclude $NOGLOBAL
    $mF = New-CommodityMatcher -Commodities $cat -GlobalExclude $NOGLOBAL
    $probe = @('boneless, skinless chicken breast', 'boneless & skinless chicken breast', 'skinless /  boneless chicken breast', 'boneless  skinless chicken breast', 'boneless chicken breast')
    $ga = @($probe | ForEach-Object { _Id (Resolve-Commodity -Matcher $mA -Name $_) }); $gf = @($probe | ForEach-Object { _Id (Resolve-Commodity -Matcher $mF -Name $_) })
    $cv = Resolve-Commodity -Matcher $mA -Name $VICTIM
    _MT 'CLEAN TWIN  the I208 atomic group answers the 5 probe names exactly as the founding include' (($ga -join ',') -eq ($gf -join ',')) (($ga -join ',') + ' vs ' + ($gf -join ','))
    _MT 'CLEAN TWIN  the I208 atomic group decides the victim with 0 timeouts' ((_Id $cv) -eq 'fixture-breast' -and (Get-CommodityMatcherBlind -Matcher $mA).timeouts -eq 0) ((_Id $cv) + ' timeouts=' + (Get-CommodityMatcherBlind -Matcher $mA).timeouts)
  } catch {
    Write-Output ('  FAIL  the self-test threw: ' + $_.Exception.Message); $bad++
  }
  # A literal case list knows its own number: a shortfall is a defect, never a smaller tree.
  $want = 29
  if ($ran -ne $want -and $bad -eq 0) { Write-Output ("  FAIL  ran {0} case(s), the list holds {1}" -f $ran, $want); $bad++ }
  if ($bad -eq 0) { Write-Output ("match-lib SELF-TEST PASS ({0} cases: a timed-out look is could-not-look on both paths, the breaker holds at 3, ordinary names decide as before)" -f $ran); exit 0 }
  Write-Output ("match-lib SELF-TEST FAIL ({0} problem(s) in {1} case(s))" -f $bad, $ran); exit 1
}
