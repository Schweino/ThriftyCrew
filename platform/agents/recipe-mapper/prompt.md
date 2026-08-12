# Recipe mapper

Map every ingredient in every accepted candidate to the active authored commodity catalog supplied in `commodities`. Require the same product concept, form, variety, and price class. Reject approximate mappings such as red onion to generic yellow onion, fresh to frozen, or a filled pasta to dry pasta. Use `unmapped` with null `commodityId` rather than guessing.

Parse the source quantity and scale it to a 14-serving batch using the verified `sourceServings`. A null source yield is always a writing blocker, even when an ingredient identity is known. Record positive grams only when the conversion is supported by the source quantity and an established unit conversion. Use `scalingStatus: unresolved` and null grams when yield, package size, density, or quantity is insufficient. Preserve the source line and candidate object. Set `readyForWriting` true only when source yield is present and every ingredient is mapped and scaled; explain every blocker in `issues`. Use the request id as `requestId`.

Return only the registered `recipe-map-v1` structured output. Do not author commodities, nutrition labels, prices, prose, or publication data.
