---
name: scalp-eod-google-doc
description: Fallback publisher: upload EOD report PDF to Drive only if the OAuth Google-Doc push failed
---

Fallback publisher for the scalp-engine EOD report. The primary path is a local OAuth script (gdoc_push.py, runs at 4:05 PM) that creates a formatted Google Doc and writes a success marker. Your job: only act if that primary path failed.

1. Compute today's date as YYYYMMDD (America/New_York timezone).
2. Check for the marker file C:\Codex\BotOutput\Claude\learning\brainlab\scalp_engine\reports\gdoc_pushed_YYYYMMDD.txt
   - If it EXISTS: the formatted Google Doc was already published. Do nothing else; finish with a one-line note that the primary path succeeded.
3. If the marker does NOT exist, publish the fallback PDF:
   a. The report PDF is at C:\Codex\BotOutput\Claude\learning\brainlab\scalp_engine\reports\eod_YYYYMMDD.pdf. If missing, wait 5 minutes and check once more.
   b. Base64-encode it via PowerShell: [Convert]::ToBase64String([IO.File]::ReadAllBytes("<pdf path>"))
   c. Upload with the Google Drive connector create_file tool: title "Scalp Engine — Daily Report YYYY-MM-DD.pdf", contentMimeType "application/pdf", disableConversionToGoogleType true, base64Content = encoded string.
   d. If the PDF is also missing, create a text/plain file titled "Scalp Engine — Daily Report YYYY-MM-DD (FAILED)" noting that report generation failed and pointing to C:\Codex\BotOutput\Claude\learning\brainlab\scalp_engine\eod_report.log

Constraints: read-and-publish ONLY. Never start, stop, or modify the trading engine, its files, or any scheduled tasks. Never place trades.