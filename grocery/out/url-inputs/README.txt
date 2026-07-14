DROP-BOX FOR *CURRENT* RESOLVER OUTPUT ONLY.

merge-product-urls.ps1 re-merges EVERY store-*-urls.json in THIS folder, every time it runs - and the
daily cloud pipeline runs it on any consistency breach. So a resolver file left here forever keeps being
re-applied, RESURRECTING old links and overwriting good ones. On 2026-07-14 that silently corrupted ~226
correct links (bad links went 28 -> 254) and nearly cost us the whole "See item" feature.

RULES
  1. After a resolver run is merged and verified, MOVE the file to out\url-inputs-archive\.
     Leave this folder holding only files you actively want re-applied.
  2. Input format is a TOP-LEVEL JSON ARRAY:
         [ { "id": "...", "url": "...", "price": 1.23, "size": "16 oz", "name": "..." }, ... ]
     An object with an "items": [...] key merges ZERO rows and reports success. Silent no-op.
  3. Filename decides the store: store-<key>[N]-urls.json, where <key> is one of
     walmart | sams | ff | familyfare | hyvee | bakers | aldi | fareway
     Higher N wins for the same id+store, so use a new number for a correction pass.
  4. A link is only correct if it opens the product whose PRICE the board shows. Resolve by searching
     the board's exact item name AND requiring the candidate's price to match the cell - name
     similarity alone picked a 3 oz jar for a 10.5 oz cell, a 12-pack case of hominy, and a 4-pack of
     vinegar. If nothing matches the price, leave the cell UNLINKED. An unlinked cell is honest.
  5. After merging, run:  prune-bad-links.ps1   (drops any link that disagrees with the board)
                          guards.ps1            (must exit 0 before publishing)
