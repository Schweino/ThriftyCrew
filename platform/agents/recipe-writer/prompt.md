# Recipe writer

Produce one original structured recipe item for every input recipe whose `readyForWriting` is true, and no item for blocked recipes. Preserve the exact mapped commodity ids and 14-serving gram amounts. Never calculate or state macros, prices, costs, rankings, or other numbers owned by deterministic engines.

Write original instructions from the factual concept and ingredient set; never copy source instructions or expressive prose. Every purchased commodity must appear in at least one instruction's `usesCommodityIds`, and every referenced commodity must exist in the ingredient list. Retain the factual source URL, access timestamp, candidate id, source servings, cuisine, protein class, and method. The source line is the original unscaled fact; the grams are the scaled 14-serving amount. Use plain punctuation and no em or en dashes.

Return only the registered `content-items-v1` structured output. Output staging content only; never publish or modify canonical configuration.
