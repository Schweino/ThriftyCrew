# OPEN ITEM: published pairs that read as duplicates of each other

opened: 2026-09-04, by Opus 5, on Brad's ruling ("some are real duplicates - open an item").
source: the P1 measurement in `EVAL-dedup-shortlist-2026-09-04.md` section 8.
status: OPEN - nothing here has been changed, retired, or unpublished. This is a list and a
question, not a proposal.

## What turned this up, and why it is credible

The dedup measurement needed a set of pairs that are definitely NOT duplicates, to count how often
a candidate gate would throw a live recipe away. The set used was the 300 closest pairs of PUBLISHED
recipes by bge-m3 cosine (0.8775 - 0.9624). Every one of them was ruled distinct by a decider at
acceptance time, so by construction they should all be clean negatives.

They are not all clean. The local model called fourteen of them the same dinner under the
names-only design, six under the ingredient-carrying one, and on reading them **several of those
look right and the original acceptance looks wrong**. That matters twice over:

1. Some of the "wrong refusals" counted against the gate designs were not wrong, so both recall and
   safety in section 8 are measured against a contaminated label set.
2. If these are duplicates, the catalog is selling a reader two versions of one dinner.

## The pairs, highest cosine first

Flagged by BOTH designs (names-only and with ingredients) - the strongest signal:

| cosine | A | B |
|---|---|---|
| 0.9624 | Salsa Verde Chicken Burrito | Salsa Verde Chicken Burrito Bowl |
| 0.9265 | High-Protein Beef Burrito Bowls | High-Protein Beef and Bean Burrito |
| 0.9080 | Chicken Tetrazzini | Turkey Tetrazzini |
| 0.8897 | Slow Cooker Pork Green Chili Bowls | Slow Cooker Salsa Verde Pork Bowls |
| 0.8849 | Ground Beef Stroganoff Pasta | Low Carb Ground Beef Stroganoff Skillet |
| 0.8813 | Chicken Pot Pie Casserole with Biscuits | Turkey Biscuit Pot Pie Casserole |

Flagged by the names-only design only:

| cosine | A | B |
|---|---|---|
| 0.9571 | Chicken and Bean Burrito | Chicken and Refried Bean Burrito |
| 0.9443 | Slow Cooker Pork Posole Verde Bowls | Slow Cooker Salsa Verde Pork Bowls |
| 0.9193 | Slow Cooker Greek Chicken Bowls | Slow Cooker Mediterranean Chicken Bowls |
| 0.9103 | Louisiana Red Beans and Rice with Sausage | Red Beans, Turkey Sausage and Rice |
| 0.9040 | Korean Gochujang Ground Pork Rice Bowls | Slow Cooker Korean Gochujang Pork Bowls |
| 0.9016 | Slow Cooker Chicken Gyro Bowls | Slow Cooker Greek Chicken Bowls |
| 0.8894 | Turkey Taco Casserole | Turkey Taco Rice Skillet |
| 0.8867 | Beef Birria Burrito | Beef Birria Rice Bowls |
| 0.8864 | Slow Cooker Korean Gochujang Pork Bowls | Slow Cooker Korean Shredded Pork Bowls |
| 0.8790 | Slow Cooker Chicken Gyro Bowls | Slow Cooker Chicken Shawarma Bowls |
| 0.8779 | Korean Beef Bibimbap Bowls | Korean Ground Beef Rice Bowls |

## The rule these pairs sit against, and the contradiction in it

`llm_same_dinner`'s rubric - the estate's own written definition, and the one every dedup prompt
carries - says: *"A different vehicle for the same filling (taco vs burrito vs bowl) is the SAME
dinner."* Six of the pairs above are exactly a vehicle swap (burrito / burrito bowl, birria burrito
/ birria rice bowl, taco casserole / taco rice skillet), and three are a protein swap in an
otherwise identical dish (chicken/turkey tetrazzini, chicken/turkey pot pie).

So either the rubric is wrong, or the acceptances are. That is the question, and it is Brad's:

- **If the rubric is right**, some of these are duplicates that should not both be selling, and the
  next question is disposal - which of each pair, and whether a live paid post can be retired at
  all (`retire-recipe` only retires LIVE recipes; see the memory of the same name).
- **If the acceptances are right** - a burrito and a burrito bowl really are two dinners a reader
  might buy both of - then the rubric's vehicle sentence is wrong and should be struck, because it
  is reaching every dedup prompt in the estate and pushing every model that reads it toward a
  refusal the estate does not want.

## What was deliberately NOT done

- No recipe was retired, held, unpublished, or edited.
- The rubric sentence was not changed. It is load-bearing in three prompts and changing it is a
  ruling, not a cleanup.
- No `dupe_of` was written. These pairs were never ruled duplicates by anything with authority; a
  local model flagged them and a session read them.
