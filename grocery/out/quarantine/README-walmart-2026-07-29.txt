QUARANTINED 2026-07-29 - Walmart weekly browser pull FAILED (PerimeterX human-verification wall).

The in-page /search fetch was blocked after 55 of 526 terms and every retry landed on
walmart.com/blocked ("Activate and hold the button to confirm that you're human"). Solving that
challenge is off-limits, so the pull stopped there.

The 55-term capture built only 64 priced rows. walmart-regular-2026-07-25.json carries 1351.
compare-deals loads the NEWEST file per store, so publishing this one would have silently cut
Walmart from ~1351 cells to 64 - the everyday-file PARTIAL-OVERWRITE failure mode. Left the
2026-07-25 file in place to keep serving instead.

Raw capture kept at out\captures\walmart-capture-2026-07-29.csv.
audit-walmart-fullpull's comprehensive-capture clock is still running, correctly.
