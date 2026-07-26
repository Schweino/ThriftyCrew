# R300 Canonicalization Notes (stage 2.5)

2026-07-25. Result: **300 recipes, 0 unmapped, 50 NEW canonical items** (4,576 ingredient lines; 279 dropped as garnish/water/headers).

## File structure

- `r300-canon-rules.authored.json` - the 207 hand-written r300 rules (ordered, first match wins).
- `build-canon-rules.ps1` - builds `r300-canon-rules.json` = authored rules + a **re-based copy of the r100 ruleset**: same regexes, same order, but every r100 target `NEW:X` where X now exists in food-macros-db is rewritten to plain `X` (93 targets rebased). This stops r300 from re-minting items that entered the DB after r100 (Oyster Sauce, Mirin, Eggs, Heavy Cream, etc.). The r100 file itself is untouched and is now effectively shadowed by an identical copy - rerun `build-canon-rules.ps1` after any DB or authored-rule change.
- `audit` script (scratchpad, session): recorded matching rule file+index for every line, diffed authored-vs-r100 outcomes, and grouped all lines by final target for eyeballing. Every diff was reviewed (details below).

## NEW items (50, by uses)

| Uses | Item | Why |
|---|---|---|
| 28 | Pork Shoulder | Pre-authorized folds: pork belly, butt, spare/back/country ribs, pulled pork, plain "pork". **Intentional policy shadow:** r100 folded pork shoulder -> Pork Loin; r300 makes shoulder its own item (a belly->loin fold would have been wrong). |
| 19 | Turkey Breast | Whole-muscle/leftover-turkey dishes per selector (4 leftover-turkey casseroles etc.). |
| 12 | Dried Arbol Chiles | arbol + generic dried red/Chinese/Asian chiles folded in (kung-pao class). |
| 10 | Kale | 9 kale lines + escarole folded in (zuppa toscana / wedding-soup class). |
| 10 | Dried Guajillo Chiles | guajillo + whole dried kashmiri folded in (kashmiri powder forms stay Chili Powder). |
| 7 | Cream of Chicken Soup | + cream-of-celery and broccoli-cheese-soup cans folded in ("any condensed cream soup"). |
| 7 | Dried Ancho Chiles | whole anchos hit 7 lines (birria/mole class), over the 3+ threshold, so minted rather than folded. |
| 6 | Cream of Mushroom Soup | see audit: r100 was silently sending these to White Mushrooms. |
| 6 | Diced Ham | incl. ham steak, ham bone (soup) fold. |
| 5 | Sazon Seasoning | sazón + Goya adobo folded in (one Latin-seasoning buy, noted). |
| 5 | Sauerkraut | reuben / pork-and-kraut identity. |
| 5 | Apple Juice | apple cider (drink) + apple juice; pork braises. |
| 5 | Swiss Cheese | r100 carryover still not in DB (reuben, cordon bleu). |
| 5 | Eggplant | r100 had no rule; "egg" was matching "eggplant" (see audit). |
| 4 | Brown Gravy Mix | slow-cooker recipes + leftover-gravy fold. |
| 4 | Sandwich Bread | bread/loaf/crustless-panade lines. |
| 4 | Chicken Livers | dirty-rice identity; beef liver (menudo), duck giblets, liver spread folded in (noted). |
| 4 | Baking Soda / 4 Baking Powder | real pantry buys. |
| 4 | Almonds | blanched/slivered/sliced almond lines. |
| 4 | Sweet Soy Sauce | kecap manis (3) + "sweet dark soy sauce" - pre-authorized; judged a real buy (thick sweet soy is not soy sauce). |
| 4 | Caraway Seeds | goulash/kraut identity, 4 lines. |
| 4 | Poultry Seasoning | + "chicken spice" folded in. |
| 3 | Wild Rice | wild-rice casserole/soup identity. |
| 3 | Doubanjiang | mapo/twice-cooked identity (spicy fermented bean paste). |
| 3 | Ground Fennel | Kerala beef fry + rogan josh (Indian context, so NOT the r100 fennel-seed->Italian-Seasoning fold). |
| 3 | Bratwurst | beer-brats identity. |
| 3 | Cocoa Powder | + Mexican chocolate folded in (mole/chili). |
| 2 | Stuffing Mix, Snow Peas, Capers, Brussels Sprouts, Basil Pesto, Artichoke Hearts, Sumac (musakhan identity, spec-mandated), Onion Soup Mix (Lipton pot-roast/meatloaf packets) | small but genuine buys with no honest existing sub. |
| 2 | PROTEIN-SWAP-LAMB | sentinel, see below. |
| 1 each | Jerk Seasoning (jerk chicken identity), Horseradish Sauce (dish named for it), Corned Beef Brisket (reuben, spec-mandated), Baked Beans (calico-beans identity), Blackberries (Colombian blackberry-sauce pork, dish identity), Korean Rice Cakes (tteokbokki-class identity), Pumpkin Puree, Gingersnap Cookies (sauerbraten gravy identity), Tater Tots (Alexia "potato puffs" line; r100 target, still not in DB), Pigeon Peas (arroz con gandules identity), Aji Amarillo Paste (aji de gallina identity), Rye Bread (reuben), Bulgur Wheat (kibbeh) | identity-defining one-offs per principle 8. |

## House folds applied (what -> what)

- **No-alcohol:** red wine/pinot noir/"gratsi red" -> Beef Broth; white wine/sake/shaoxing/rice wine/cognac/"vinho branco" -> Chicken Broth; beer/guinness/pale ale -> Beef Broth; "sweet rice wine (mirim)" -> **Mirin** (exists, per spec); tequila, vodka -> DROP.
- **Proteins:** country ribs/belly/butt/spare ribs -> Pork Shoulder; "beef or chicken" (mafe) + brisket/short ribs/shank/neck/stew meat/round steak/veal shoulder -> Beef Chuck Roast; flank/skirt/sirloin/strip/rib eye/thin-sliced beef -> Beef Flank/Sirloin Steak; kielbasa/smoked sausage -> Smoked Turkey Sausage; drumsticks/legs -> Chicken Thigh (flagged below); ground chicken -> Chicken Thigh (selector ruling); "ground beef or lamb" (beef listed first) -> 93/7 Ground Beef; prawns/shrimp paste -> DROP (selector already stripped seafood).
- **Produce:** butternut/generic squash -> Sweet Potatoes (zucchini-first line left to Zucchini); taro, yuca -> Potato; cauliflower -> Broccoli Florets; escarole -> Kale; candlenuts -> Cashews; pecans -> Walnuts; dried apricots/prunes/dates/sultanas -> Golden Raisins; loomi/dried limes -> Lime Juice; anardana -> Pomegranate Molasses.
- **Pantry:** evaporated milk, half-and-half, double/whipping cream -> Heavy Cream; sweetened condensed milk (ca ri ga, 1 line) -> Sugar (sweetness role; flag if Brad wants the real can); cornmeal/semolina -> Grits; elbow/ditalini/acini/orecchiette/farfalle -> Pasta Shells; manicotti -> Pasta Shells - jumbo; broken lasagna -> Ziti; fideo -> Spaghetti; arborio (youvarlakia meatballs, not risotto) -> Rice; glass/shirataki/konnyaku/sweet-potato noodles -> Rice Noodles; wheat noodles -> Lo Mein Noodles; gochugaru/korean chili flakes/calabrian -> Red Pepper Flakes; korean chili paste -> Gochujang; ground/sweet bean sauce (tianmianjiang) -> Hoisin; green/massaman curry paste -> Red Curry Paste (<3 uses each, per principle 8); "curry sauce" -> Japanese Curry Roux; lard/palm/mustard oil -> Vegetable Oil; shortening/chicken fat/beurre manie -> Butter; sherry vinegar -> Red Wine Vinegar; browning sauce/worcester -> Worcestershire; liquid smoke -> Smoked Paprika; sweet chili sauce (1 line, 2 tbsp accent) -> Hot Honey; korean corn syrup + Mrs Balls chutney (bobotie) -> Honey; caramel color + rock/raw sugar -> Sugar; molasses -> Brown Sugar; chickpea/gram flour -> All-Purpose Flour; sofrito -> Salsa; french onion soup (canned) -> Beef Broth; coconut water (bo kho) -> Chicken Broth; coconut cream -> Coconut Milk; coconut soda/sprite -> Zero-Sugar Soda.
- **Seasonings:** kabsa mix, pilau masala, cardamom, kasuri methi, fenugreek -> Garam Masala; geera/kamouneh -> Ground Cumin; "7 Spice" (kibbeh) -> Ground Allspice (r100 precedent); peri peri seasoning -> Cajun Seasoning; adobo (Goya) -> Sazon Seasoning; mace -> Ground Nutmeg; ground anise + Chinese aromatic herb packet -> Five-Spice; marjoram -> Dried Oregano; tarragon/herbes de provence -> Italian Seasoning; dried chives -> Dried Parsley; celery salt -> Salt; maggi/rosdee -> Chicken Broth; royco usavi/beef powder -> Beef Broth; haitian epis -> Fresh Cilantro; kampot pepper -> Black Pepper (spec); italian dressing (mix) -> Italian Seasoning; thousand island -> Mayonnaise; taco sauce -> Salsa; holy/thai basil -> Fresh Basil (spec); salt-and-pepper combo lines -> Black Pepper (r100 precedent).
- **Bread/serve-with:** cornbread -> Corn Muffin Mix; hoagie rolls -> Keto Bun; tostadas, moo shu pancakes, doner pita, musakhan flatbread -> Tortilla; crackers -> Butter Crackers; doritos -> Corn Chips; steamed-rice serve-with lines -> Rice (per spec, duplicates collapse).

## Flagged recipes

**Drumstick/leg lines mapped to Boneless Skinless Chicken Thigh** (drumstick may be the plated identity; review): Korean Dakdoritang; Andong Jjimdak; Chicken Kabsa; Coq au Vin; Chicken Normandy; Kuku Paka; Zanzibar Chicken Pilau; Haitian Poulet en Sauce; Vietnamese Ca Ri Ga; Musakhan.

**Ground chicken -> Chicken Thigh (minced-thigh build per selector):** Turkey Tsukune Meatball Rice Bowls ("ground chicken or turkey dark meat"). (Two Ants-Climbing-a-Tree recipes mention ground chicken only in stripped parentheticals.)

**NEW:PROTEIN-SWAP-LAMB (2 lines, resolve per-recipe downstream):**
- Xinjiang Cumin Turkey Stir-Fry - "boneless lamb leg meat" (target protein is turkey).
- Lebanese Baked Kafta (Kafta bil Sanieh) - "ground lamb or beef" (lamb listed first).

## DROP-with-doubt cases

- "coconut slices fresh or frozen" (Kerala beef fry) - toasted coconut chips are semi-identity; dropped, flag if it matters.
- "liver spread" mapped to Chicken Livers (caldereta enrichment), not dropped.
- "water or broth" -> DROP (water is offered); "water or chicken/beef broth" -> respective broths.
- "kabsa spice mix recipe above"-style self-references mapped to Garam Masala (collapse with the main kabsa line).
- Pickled mustard greens, pickled ginger, fried shallots, croutons, bok choy "per serving", radishes, jicama, blood jelly, gumbo filé, saffron, ratanjot, asafetida, carom seeds, wooden skewers -> DROP (garnish/optional-tier). Full drop list eyeballed - nothing load-bearing dropped.

## Audit results

Method: every one of 4,576 lines was attributed to (file, rule index); authored-rule matches were listed per rule and eyeballed; all lines were grouped by final canon target and every group eyeballed; and a full diff was produced of lines where an authored rule fired but the r100 set alone would map differently. All 112 diffs reviewed; each is either an intentional r300 policy (listed above) or one of these **r100 latent-bug repairs**:

- "sage" is a substring of "sauSAGE": generic smoked-sausage/kielbasa lines were becoming Italian Seasoning.
- "mushroom" precedes "cream of mushroom" in r100: all condensed mushroom-soup cans were becoming White Mushrooms.
- "egg" matched "EGGplant" and "rEGGiano": eggplant lines and "parmagiano reggiano" were becoming Eggs.
- "roma" matched "aROMAtic" and "ROMAine": an herb packet and a lettuce line were becoming Diced Tomatoes.
- "butter" matched "BUTTERnut squash", "BUTTER beans", "BUTTERed toast/noodles".
- "avocado" (DROP) preceded the oil rule: "avocado oil" and "neutral oil...avocado oil" lines were being dropped.
- "vegetable" oil rule ate plain "vegetables"/"frozen vegetables" lines.
- "white wine" preceded "white wine vinegar": vinegar was becoming Chicken Broth.
- "hash brown" stole "olive oil + more for hash browns"; "birds eye" (chili) stole Birds Eye frozen vegetables; "shallot" stole fried-shallot garnishes and onion-soup mixes; "potato" stole potato starch and Alexia potato puffs; "frito" stole "soFRITO".

Spot-checks required by spec (butter, rice, jalapeno, wine, sausage, chicken families) all pass: butter group contains only real butter/ghee lines; Rice group only rice/quinoa; Jalapeno only fresh chiles; wine folds land on the correct broths; sausage families split correctly (turkey sausage -> Smoked Turkey Sausage, Italian -> Hot Italian, ground turkey incl. Jennie-O ground lines -> 93/7 Ground Turkey); chicken breast/thigh/broth separation verified.

Deliberate residual quirks (harmless, same-tier): "salt & pepper" -> Black Pepper vs bare salt lines -> Salt (mirrors r100); "tabasco or cayenne" -> Hot Sauce; "veggies such as carrots, green beans or broccoli" -> Green Beans; makrut-lime-leaves-or-bay -> Bay Leaves.
