# R300 LAUNCH CARD - execute immediately when Brad says go/continue after app restart

Brad approved (2026-07-25): full 300-recipe run, all stages, publish included, no questions except
CAPTCHA walls or genuine judgment calls (those go to the triage queue / one specific ask).
Agents are registered at app start: recipe-sourcer + recipe-writer (claude-opus-4-8, high effort),
recipe-ingredient-mapper + recipe-batch-auditor + post-publish-reviewer (fable, high effort).
Verify with a tiny dispatch first if unsure the registry loaded.

## Stage 1 - dispatch ALL TEN sourcers in ONE message, subagent_type=recipe-sourcer, background:

Common to every prompt: "First Read C:\Codex\income\meal-prep\recipes-db.json and extract existing
names/slugs so you never return a duplicate or near-duplicate. Follow your agent instructions
(dinner over 500 cal, high protein, 14-serving batch-scalable, board-mappable ingredients, no seafood).
Write JSON to C:\Codex\income\meal-prep\r300\candidates\<SLICE>.json with schema
{"slice":"<SLICE>","candidates":[{"name","slug","protein","cuisine","source_url","est_cal",
"main_ingredients":[],"unmapped_flags":[],"why"}]}. Return a short summary only."

| Slice | Count | Hunting ground (put verbatim in prompt) |
|---|---|---|
| T1 | 45 turkey | ground-turkey skillets/bowls/casseroles, American + Tex-Mex; existing turkey taco/sloppy joe/chili/bolognese/keema/burger-bowl are dupes |
| T2 | 45 turkey | global turkey: Mediterranean/Middle Eastern/Greek/Asian (kofta, larb bowls, gyro bowls, shawarma skillets, teriyaki); keema + Greek lemon rice exist |
| T3 | 45 turkey | Italian/pasta bakes, slow-cooker turkey, hearty 500+cal soups/stews/chilis; bolognese penne, pizza pasta, sloppy joes, sc turkey chili, baked ziti, creamy shells exist |
| P1 | 40 pork | slow-cooker/oven shoulder-loin-tenderloin, Latin + American (adobada, al pastor bowls, pernil, Cuban mojo); kalua, tinga, honey garlic, Brazilian ribs, ragu exist |
| P2 | 40 pork | sausage/kielbasa/bratwurst skillets, sheet-pan, pasta, Eastern European (haluski, goulash, cabbage bakes); italian sausage penne + jambalaya-class exist |
| P3 | 40 pork | chops/ground-pork/tenderloin Asian + European (char siu bowls, adobo, dan-dan noodles, mapo over rice, schnitzel-inspired bakes; fried-to-order does not scale - adapt or skip) |
| B1 | 50 beef | global ground beef: Middle Eastern kofta bakes (NOT hashweh), Korean/Mongolian/soboro bowls, African bobotie/berbere, Latin picadillo; keema, cheeseburger pasta, million-dollar, chili exist |
| B2 | 50 beef | chuck/stew/sirloin: pot roast variants, barbacoa/birria bowls, American + Tex-Mex bakes; john wayne, swedish meatballs, beef and shells exist; prefer chuck over ribeye (cost) |
| C1 | 45 chicken | THIGH + drumstick dinners (catalog skews breast): braises, sheet-pan, rice bakes, thigh curries; 69 chicken recipes live - dedupe hard |
| C2 | 45 chicken | underrepresented cuisines: African peanut/mafe stews, piri piri, paprikash, Caribbean jerk/curry, new Indian/Thai; dedupe against all 69 name by name |

## After sourcing completes (notifications arrive):
Stage 2: merge candidates, cull to 300 per targets (turkey 90, pork 78, beef 73, chicken 59),
build normalized ingredient worklist -> then stage 3 mapper (fable), stages 4-8 per
meal-prep\NEXT-RUN-PLAYBOOK.md. Batch publishes (~50-75 at a time); auditor GO gates each batch;
post-publish-reviewer after every publish. Update RUN-STATE.md as stages complete + commit/push
r300 state so nothing is lost between sessions.
