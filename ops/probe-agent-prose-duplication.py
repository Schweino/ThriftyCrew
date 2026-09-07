r"""E13, measured before building: does any agent definition PASTE what it should CITE?

E13's claim is that a delegating agent physically cannot restate a large body of text, so it should
emit an identifier and let the receiver inflate it. The memory half of that already shipped - all
twelve agents carry [[name]] citations and a resolver block, gated by ops/audit-memory-citations.ps1.

What is NOT checked is prose duplication: a paragraph copied out of a design ruling or a doc into an
agent definition is a COPY, and the copy drifts from the original silently. This looks for it before
anything is built, because the last four items on this backlog all inverted their own premise the
moment they were measured.

Method: every sufficiently long, distinctive line in an agent definition, looked for verbatim in the
repo's prose files. Short and boilerplate lines are excluded - they would match everywhere and say
nothing.
"""
import glob
import io
import os
import re

REPO = r'C:\Codex\ThriftyCrew'
AGENTS = glob.glob(os.path.join(REPO, '.claude', 'agents', '*.md'))
CORPUS = []
for pat in ('design/*.md', 'docs/*.md', 'CLAUDE.md', 'grocery/*.md', 'meal-prep/*.md'):
    CORPUS.extend(glob.glob(os.path.join(REPO, pat)))

MIN_LEN = 60


def norm(s):
    return re.sub(r'\s+', ' ', s.strip())


corpus = {}
for p in CORPUS:
    try:
        for line in io.open(p, encoding='utf-8-sig'):
            n = norm(line)
            if len(n) >= MIN_LEN:
                corpus.setdefault(n, p)
    except Exception:                                          # noqa: BLE001
        pass

print('agent definitions : %d' % len(AGENTS))
print('prose files scanned: %d   distinct long lines: %d' % (len(CORPUS), len(corpus)))
print('')

total = 0
for a in sorted(AGENTS):
    hits = []
    try:
        for i, line in enumerate(io.open(a, encoding='utf-8-sig'), 1):
            n = norm(line)
            if len(n) >= MIN_LEN and n in corpus:
                hits.append((i, n, corpus[n]))
    except Exception:                                          # noqa: BLE001
        continue
    if hits:
        total += len(hits)
        print('%s  -  %d duplicated line(s)' % (os.path.basename(a), len(hits)))
        for i, n, src in hits[:4]:
            print('   L%-4d %s' % (i, n[:88]))
            print('         also in %s' % os.path.relpath(src, REPO))

print('')
if total == 0:
    print('NO PROSE IS PASTED. Every agent definition states its own instructions rather than copying a')
    print('ruling or a doc, so the copy-drift E13 warns about has no instance here to fix. The memory')
    print('half of E13 already shipped as [[name]] citations plus the resolver block.')
else:
    print('%d duplicated line(s) total - each one is a copy that will drift from its source.' % total)
