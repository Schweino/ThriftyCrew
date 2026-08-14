import { browserLanePolicy, recordBrowserLaneResult, withBrowserStoreLane } from "./lane-policy.mjs";
import { checkpointAdapterChunk } from "./adapter-protocol.mjs";

// Targeted ingredient evidence is accepted only after the true end of the
// result set. A depth of 25 truncated common Walmart queries even when only a
// few additional cards remained, so keep loading through the bounded five-page
// loop before a no-match result can be asserted.
const TARGET_RESULTS = 100;
const CONFIG = {
  sams: {
    location: "Omaha Sam's Club",
    locationId: "8146",
    priceMode: "Pickup",
    url: (query) => `https://www.samsclub.com/s/${encodeURIComponent(query)}`,
    host: "https://www.samsclub.com",
  },
  walmart: {
    location: "Omaha L St Supercenter, 12850 L St, Omaha, NE 68137",
    priceMode: "Pickup",
    url: (query) => `https://www.walmart.com/search?q=${encodeURIComponent(query)}&facet=fulfillment_method%3APickup`,
    host: "https://www.walmart.com",
    locationId: "5361",
  },
};

function normalize(value) {
  return String(value ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function priceMinor(value) {
  const match = String(value ?? "").trim().match(/^\$([0-9][0-9,]*(?:\.[0-9]{1,2})?)$/);
  return match ? Math.round(Number(match[1].replace(/,/g, "")) * 100) : null;
}

function expandVerification(target, verification) {
  const rows = Array.isArray(target.satisfies) && target.satisfies.length ? target.satisfies : [target];
  return rows.map((row) => ({ ...verification, rowKey: row.rowKey, discoveryHash: row.discoveryHash }));
}

export function findVerificationRow(rows, target) {
  const key = String(target.retailerProductId ?? target.productKey ?? "");
  return rows.find((candidate) => String(candidate.id) === key || String(candidate.url) === String(target.productKey));
}

export function walmartPickupEligible(row) {
  return row?.availabilityStatus === "IN_STOCK"
    && Array.isArray(row.pickupStoreIds)
    && row.pickupStoreIds.includes("5361");
}

export function pickupEligible(row, locationId) {
  return row?.availabilityStatus === "IN_STOCK"
    && Array.isArray(row.pickupStoreIds)
    && row.pickupStoreIds.includes(String(locationId));
}

export function packageSizeFromName(name) {
  const text = String(name ?? "").replace(/\s+/g, " ").trim();
  // Variable-weight offers do not have a fixed checkout package even when the
  // title also contains a merchandising weight or count.
  if (/priced\s+per\s+(?:pound|lb)\b/i.test(text)) return "";
  const unit = (value) => value.toLowerCase().replace(/\./g, "").replace(/\s+/g, " ")
    .replace(/^lbs?$/, "lb").replace(/^gallons?$/, "gal").replace(/^liters?$/, "l");
  const unitPattern = "fl\\.?\\s*oz\\.?|oz\\.?|lbs?\\.?|g|kg|ml|l|liters?|gal(?:lon)?s?|qt|pt";
  // Retailer titles commonly put merchandising descriptors after the size
  // ("18 oz, Rye Bread, Bag"). Select the final source-native quantity/unit
  // token instead of requiring it to be the final title suffix.
  const packs = [...text.matchAll(new RegExp(`([0-9]+(?:\\.[0-9]+)?)\\s*(${unitPattern})\\s*[,;]?\\s*(\\d+)\\s*(?:pk|pack|ct|counts?)\\.?`, "ig"))];
  if (packs.length) { const pack = packs.at(-1); return `${pack[3]} x ${pack[1]} ${unit(pack[2])}`; }
  const quantities = [...text.matchAll(new RegExp(`(?:^|[^a-z0-9])([0-9]+(?:\\.[0-9]+)?)\\s*(${unitPattern})(?=$|[^a-z])`, "ig"))];
  if (quantities.length) { const quantity = quantities.at(-1); return `${quantity[1]} ${unit(quantity[2])}`; }
  const counts = [...text.matchAll(/(?:^|[^a-z0-9])(\d+)\s*(?:pk|pack|ct|count)\.?(?=$|[^a-z])/ig)];
  if (counts.length) return `${counts.at(-1)[1]} ct`;
  const word = text.match(/(?:^|[,;(]\s*)(half\s+gallon|gallon|dozen|each)(?=$|[^a-z])/i);
  if (word) return word[1].toLowerCase() === "half gallon" ? "0.5 gal" : word[1].toLowerCase() === "gallon" ? "1 gal" : word[1].toLowerCase();
  return "";
}

export function sourcePriceSemantics(store, row) {
  const purchasePriceMinor = priceMinor(row.linePrice);
  const promotionText = [row.promotionText, row.priceDisplayCondition, row.savings, row.memberPriceString].filter(Boolean).join(" | ");
  const multi = promotionText.match(/\b(\d+)\s*(?:for|\/)\s*\$?([0-9]+(?:\.[0-9]{1,2})?)\b/i);
  const quantity = multi ? Number(multi[1]) : 1;
  const advertisedTotal = multi ? Math.round(Number(multi[2]) * 100) : purchasePriceMinor * quantity;
  if (multi && Math.abs(advertisedTotal - purchasePriceMinor * quantity) > 1) throw new Error("source promotion total does not agree with the captured unit price");
  const loyalty = /rewards?|loyalty|digital coupon|with card/i.test(promotionText);
  const membership = store === "sams" || /member price|membership/i.test(promotionText);
  const was = priceMinor(row.wasPrice);
  const discounted = was !== null && was > purchasePriceMinor;
  const offerType = quantity > 1 ? "multibuy" : loyalty ? "loyalty" : membership ? "member" : discounted ? "sale" : "everyday";
  const condition = loyalty ? (quantity > 1 ? "loyalty_quantity" : "loyalty") : membership ? (quantity > 1 ? "membership_quantity" : "membership") : quantity > 1 ? "quantity" : "none";
  return { offerType, condition, unitPriceMinor: purchasePriceMinor, qualifyingQuantity: quantity, totalPriceMinor: advertisedTotal, ...(discounted ? { regularPriceMinor: was } : {}), ambiguity: false };
}

export function parseNextDataOfferItem(item, origin = "https://www.walmart.com") {
  const id = String(item?.usItemId || item?.id || "").trim();
  if (!id) return null;
  const canonical = new URL(item.canonicalUrl || `/ip/item/${id}`, origin);
  return {
    id,
    name: String(item.name || "").trim(),
    linePrice: String(item.priceInfo?.linePrice || item.priceInfo?.itemPrice || "").trim(),
    unitPrice: String(item.priceInfo?.unitPrice || "").trim(),
    wasPrice: String(item.priceInfo?.wasPrice || "").trim(),
    priceDisplayCondition: String(item.priceInfo?.priceDisplayCondition || "").trim(),
    savings: String(item.priceInfo?.savings || "").trim(),
    memberPriceString: String(item.priceInfo?.memberPriceString || "").trim(),
    promotionText: [item.promotionMessages, item.promoData, item.promoDiscount, item.badges].map((value) => {
      if (value == null) return "";
      try { return JSON.stringify(value); } catch { return ""; }
    }).join(" | "),
    taxonomy: String(item.category?.categoryPathId || item.departmentName || "").trim(),
    url: canonical.origin + canonical.pathname,
    imageUrl: String(item.imageInfo?.thumbnailUrl || "").trim(),
    availabilityStatus: String(item.availabilityStatusV2?.value || "").trim().toUpperCase(),
    availabilityText: String(item.availabilityStatusV2?.display || item.availabilityStatusDisplayValue || "").trim(),
    offerId: String(item.offerId || "").trim(),
    sellerName: String(item.sellerName || "").trim(),
    pickupStoreIds: [...new Set((item.fulfillmentSummary || [])
      .filter((option) => String(option?.fulfillment || "").toUpperCase() === "PICKUP")
      .map((option) => String(option?.storeId || "").trim())
      .filter(Boolean))],
  };
}

async function readPage(tab) {
  const page = await tab.playwright.evaluate(() => {
    const body = document.body.innerText;
    const data = JSON.parse(document.querySelector("#__NEXT_DATA__")?.textContent || "{}");
    const stacked = (data?.props?.pageProps?.initialData?.searchResult?.itemStacks || []).flatMap((stack) => [...(stack.items || []), ...(stack.itemsV2 || [])]);
    const structured = new Map();
    for (const item of stacked) {
      const id = String(item?.usItemId || "").trim();
      if (!id || structured.has(id)) continue;
      structured.set(id, {
        usItemId: item.usItemId, id: item.id, name: item.name, canonicalUrl: item.canonicalUrl,
        priceInfo: item.priceInfo, category: item.category, departmentName: item.departmentName,
        imageInfo: item.imageInfo, availabilityStatusV2: item.availabilityStatusV2,
        availabilityStatusDisplayValue: item.availabilityStatusDisplayValue, offerId: item.offerId,
        sellerName: item.sellerName, fulfillmentSummary: item.fulfillmentSummary,
        promotionMessages: item.promotionMessages, promoData: item.promoData, promoDiscount: item.promoDiscount, badges: item.badges,
      });
    }
    const visible = new Map();
    for (const anchor of [...document.querySelectorAll("a")]) {
      const text = (anchor.innerText || anchor.getAttribute("aria-label") || "").replace(/\s+/g, " ").trim();
      if (!text || !anchor.href) continue;
      let decoded;
      try { decoded = decodeURIComponent(anchor.href); } catch { decoded = anchor.href; }
      const match = decoded.match(/\/(?:ip|p)\/[^/?#]*\/(\d{5,})(?:[?#/]|$)/i);
      if (!match) continue;
      const prior = visible.get(match[1]);
      if (!prior || text.length > prior.length) visible.set(match[1], text);
    }
    const rows = [];
    for (const item of structured.values()) {
      const id = String(item.usItemId || item.id || "");
      const name = String(item.name || "").trim();
      const linePrice = String(item.priceInfo?.linePrice || item.priceInfo?.itemPrice || "").trim();
      const visibleText = visible.get(id);
      if (!visibleText || !name || !linePrice) continue;
      const normalizedVisible = visibleText.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
      const normalizedName = name.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
      if (!visibleText.includes(linePrice) || !normalizedVisible.includes(normalizedName)) continue;
      rows.push({ item, visiblePrice: linePrice });
    }
    const query = document.querySelector('input[type="search"], input[role="searchbox"]')?.value || new URL(location.href).searchParams.get("q") || "";
    return {
      url: location.href,
      title: document.title,
      query,
      locale: document.documentElement.lang || "en-US",
      challenge: /\/are-you-human|\/blocked|\/verify/i.test(location.pathname)
        || /verify you are human|captcha|access denied|unusual traffic|robot or human|not a robot|403 error|request blocked|request could not be satisfied/i.test(`${document.title}\n${body}`),
      noResults: /no (?:matching )?(?:results|products)|0 results|couldn.t find/i.test(body),
      hasMore: [...document.querySelectorAll("button,a")].some((element) => /^(?:next|next page|load more|show more)$/i.test((element.innerText || element.getAttribute("aria-label") || "").trim()) && element.offsetParent !== null),
      nextHref: [...document.querySelectorAll("a")].find((element) => /^(?:next|next page)$/i.test((element.innerText || element.getAttribute("aria-label") || "").trim()) && element.offsetParent !== null)?.href || null,
      rows,
    };
  });
  const origin = new URL(page.url).origin;
  page.rows = page.rows.map(({ item, visiblePrice }) => ({ ...parseNextDataOfferItem(item, origin), visiblePrice })).filter((item) => item.id);
  return page;
}

export function buildNextDataRows(store, query, page, capturedAt) {
  const config = CONFIG[store];
  const rows = [];
  const excludedResults = [];
  for (const [resultIndex, row] of page.rows.entries()) {
    try {
      const purchasePriceMinor = priceMinor(row.linePrice);
      if (!Number.isSafeInteger(purchasePriceMinor) || purchasePriceMinor <= 0) throw new Error("source purchase price is not exact");
      const size = packageSizeFromName(row.name);
      const candidateIssues = [];
      if (!size) candidateIssues.push("invalid_package_basis");
      let priceSemantics;
      try { priceSemantics = sourcePriceSemantics(store, row); }
      catch { priceSemantics = { offerType: "unknown", condition: "unknown", unitPriceMinor: purchasePriceMinor,
        qualifyingQuantity: 1, totalPriceMinor: purchasePriceMinor, ambiguity: true }; candidateIssues.push("invalid_price_semantics"); }
      const pickup = pickupEligible(row, config.locationId);
      const offer = {
      version: 1, retailerProductId: row.id, ...(row.offerId ? { offerId: row.offerId } : {}), productName: row.name,
      sizeText: size, rawPriceText: row.linePrice, purchasePriceMinor, ...(row.unitPrice ? { unitPriceText: row.unitPrice } : {}),
      ...(!size ? { rawSizeText: row.name } : {}), ...(candidateIssues.length ? { candidateIssues } : {}),
      ...(row.sellerName ? { sellerName: row.sellerName } : {}),
      availability: { status: pickup ? "in_stock" : "unavailable", ...(row.availabilityText ? { rawText: row.availabilityText } : {}),
        fulfillmentMode: "pickup", locationId: config.locationId, eligible: pickup },
      priceSemantics, observedAt: capturedAt, sourceUrl: row.url,
    };
      const truth = {
      capturedAt,
      pageUrl: page.url,
      location: config.location,
      priceMode: config.priceMode,
      pageIndex: 0,
      resultIndex,
      pageState: { pageType: "search_results", pageTitle: page.title, query: page.query, resultRegionPresent: true, challengeDetected: false, currency: "USD", locale: page.locale, locationText: config.location, fulfillmentText: config.priceMode },
      visible: { rawText: row.visiblePrice, priceMinor: purchasePriceMinor, productName: row.name, productKey: row.id, sizeText: size, priceSemantics },
      structured: { rawText: row.linePrice, priceMinor: purchasePriceMinor, productName: row.name, productKey: row.id, sizeText: size, ...(row.unitPrice ? { unitPriceText: row.unitPrice } : {}), priceSemantics },
      offer,
      parser: { status: candidateIssues.length ? "typed_unpriceable" : "exact", rule: "next-data-price-lines", notes: "Visible product-card price agrees with the projected __NEXT_DATA__ linePrice for the same retailer item ID; candidate eligibility remains server-derived." },
    };
      rows.push({
        q: query, n: row.name, lp: row.linePrice, up: row.unitPrice, id: row.id, size,
        taxonomy_path: row.taxonomy, url: row.url, image_url: row.imageUrl,
        availability_status: offer.availability.status,
        fulfillment_mode: offer.availability.fulfillmentMode,
        ...(offer.sellerName ? { seller_name: offer.sellerName } : {}),
        ...(offer.offerId ? { offer_id: offer.offerId } : {}),
        _capture: truth,
      });
    } catch (error) {
      excludedResults.push({ productKey: row.id, name: row.name, reason: String(error?.message || error) });
    }
  }
  return { rows, excludedResults };
}

export function buildNextDataSuccess(query, page, built, { attempts, startedAt, finishedAt }) {
  const examinedResultCount = built.rows.length + built.excludedResults.length;
  const reason = built.excludedResults.length
    ? `${built.excludedResults.length} retailer result(s) explicitly excluded from pricing`
    : undefined;
  return {
    blocked: false,
    term: {
      query, outcome: "success", rowCount: built.rows.length, attempts, startedAt, finishedAt,
      retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: examinedResultCount, availableResultCount: examinedResultCount, pageCount: page.pageCount ?? 1, hasMoreResults: page.hasMore, termination: page.hasMore ? "target-depth" : "end-of-results" },
      ...(reason ? { reason, excludedResults: built.excludedResults } : {}),
    },
    rows: built.rows,
  };
}

async function captureTerm(tab, store, query) {
  const config = CONFIG[store];
  let lastError = "";
  for (let attempts = 1; attempts <= 2; attempts += 1) {
    const startedAt = new Date().toISOString();
    try {
      await tab.goto(config.url(query));
      let page = null;
      for (let poll = 0; poll < 20; poll += 1) {
        await tab.playwright.waitForTimeout(poll === 0 ? 800 : 300);
        page = await readPage(tab);
        if (page.challenge || page.rows.length || page.noResults) break;
      }
      let finishedAt = new Date().toISOString();
      if (page?.challenge) return { blocked: true, term: { query, outcome: "blocked", rowCount: 0, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "blocked" }, reason: "Retailer challenge detected; sweep stopped without attempting to solve it." }, rows: [] };
      if (!page) throw new Error(`${store} page produced no readable state`);
      if (normalize(page.query) !== normalize(query)) throw new Error(`visible query mismatch: expected ${query}, saw ${page.query}`);
      const accumulated = [...page.rows];
      let pageCount = 1;
      while (page.hasMore && page.nextHref && pageCount < 5) {
        const currentWithoutHash = String(page.url).replace(/#.*$/, "");
        const nextWithoutHash = String(page.nextHref).replace(/#.*$/, "");
        if (nextWithoutHash && nextWithoutHash !== currentWithoutHash) {
          await tab.goto(page.nextHref);
        } else {
          // Walmart exposes a client-routed href="#" continuation. The
          // accessible control can time out while its router is replacing the
          // result envelope, so advance through Walmart's canonical `page`
          // query parameter and revalidate the visible query and structured
          // rows after navigation.
          const continuation = new URL(page.url);
          continuation.searchParams.set("page", String(pageCount + 1));
          await tab.goto(continuation.href);
        }
        // Walmart updates the URL before replacing the product envelope. A
        // sub-second read can therefore see page-one's pager under page two's
        // URL and attempt a nonexistent extra continuation. Allow the routed
        // result region to settle before evaluating termination.
        await tab.playwright.waitForTimeout(2_500);
        const nextPage = await readPage(tab);
        if (nextPage.challenge) return { blocked: true, term: { query, outcome: "blocked", rowCount: 0, attempts, startedAt, finishedAt: new Date().toISOString(), retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount: pageCount + 1, hasMoreResults: false, termination: "blocked" }, reason: "Retailer challenge detected during result pagination." }, rows: [] };
        if (normalize(nextPage.query) !== normalize(query)) throw new Error(`visible query mismatch on continuation: expected ${query}, saw ${nextPage.query}`);
        accumulated.push(...nextPage.rows);
        page = nextPage;
        pageCount += 1;
      }
      const uniqueRows = new Map(accumulated.map((row) => [row.id, row]));
      page.rows = [...uniqueRows.values()];
      page.pageCount = pageCount;
      finishedAt = new Date().toISOString();
      if (page.rows.length === 0) {
        if (!page.noResults) throw new Error("zero visible/structured agreements without an explicit no-results state");
        return { blocked: false, term: { query, outcome: "empty", rowCount: 0, attempts, startedAt, finishedAt, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, availableResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "no-results" } }, rows: [] };
      }
      if (page.rows.length < TARGET_RESULTS && page.hasMore) throw new Error("visible/structured agreement remained truncated below target depth while a continuation was present");
      if (page.rows.some((row) => priceMinor(row.linePrice) === null || !row.id || !row.name)) throw new Error("one or more agreed rows lacked an exact line price, retailer item ID, or name");
      const built = buildNextDataRows(store, query, page, finishedAt);
      return buildNextDataSuccess(query, page, built, { attempts, startedAt, finishedAt });
    } catch (error) {
      lastError = String(error?.message || error);
      if (attempts < 2) await tab.playwright.waitForTimeout(500);
    }
  }
  const instant = new Date().toISOString();
  return { blocked: false, term: { query, outcome: "rejected", rowCount: 0, attempts: 2, startedAt: instant, finishedAt: instant, retrieval: { targetResultCount: TARGET_RESULTS, loadedResultCount: 0, pageCount: 1, hasMoreResults: false, termination: "error" }, reason: lastError || `${store} capture failed twice` }, rows: [] };
}

export async function captureNextDataCanary(tab, store, screenshotSha256) {
  const config = CONFIG[store];
  let state;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    state = await tab.playwright.evaluate(() => ({
      url: location.href,
      body: document.body.innerText.slice(0, 2000),
      challenge: /\/are-you-human|\/blocked|\/verify/i.test(location.pathname)
        || /verify you are human|captcha|access denied|unusual traffic|robot or human|not a robot|403 error|request blocked|request could not be satisfied/i.test(`${document.title}\n${document.body.innerText}`),
    }));
    if (state.challenge) throw new Error(`${store} retailer block page detected; stop the lane without retrying or attempting a bypass`);
    const pass = store === "sams"
      ? /Pickup[\s\S]*Omaha Sam's Club/i.test(state.body)
      : /Omaha L St Supercenter/i.test(state.body) && /fulfillment_method%3APickup/i.test(state.url);
    if (pass) return {
      observedAt: new Date().toISOString(),
      market: "Omaha, NE",
      location: config.location,
      locationId: config.locationId,
      retailerLocationKey: config.locationId,
      priceMode: config.priceMode,
      evidenceUrl: state.url,
      marketVerified: true,
      locationVerified: true,
      priceModeVerified: true,
      ...(screenshotSha256 ? { screenshotSha256 } : {}),
    };
    if (attempt < 4) await tab.playwright.waitForTimeout(750);
  }
  throw new Error(`${store} Omaha/Pickup canary failed after waiting for the page to settle`);
}

async function captureNextDataChunkInternal({ tab, store, terms, file, sessionDirectory, screenshotSha256, interTermDelayMs }) {
  if (!CONFIG[store]) throw new Error("next-data adapter supports sams or walmart");
  const policy = await browserLanePolicy(store);
  const maxTerms = policy.maxTerms;
  const effectiveDelayMs = Math.max(interTermDelayMs ?? 0, policy.dynamicDelayMs);
  if (!Array.isArray(terms) || terms.length < 1 || terms.length > maxTerms) throw new Error(`${store} chunk requires 1-${maxTerms} terms`);
  if (!Number.isInteger(effectiveDelayMs) || effectiveDelayMs < 0 || effectiveDelayMs > 30_000) throw new Error(`${store} inter-term delay must be 0-30000ms`);
  const canary = await captureNextDataCanary(tab, store, screenshotSha256);
  const results = [];
  const chunkStarted = Date.now();
  for (let index = 0; index < terms.length; index += 1) {
    const query = terms[index];
    const termStarted = Date.now();
    const captured = await captureTerm(tab, store, query);
    await recordBrowserLaneResult(store, captured.term.outcome, Date.now() - termStarted);
    const previousCount = results.length;
    results.push(captured);
    await checkpointAdapterChunk(file, { version: 2, phase: "discovery", store, canary, terms: results.map((result) => result.term), rows: results.flatMap((result) => result.rows) }, previousCount, sessionDirectory);
    if (captured.blocked) break;
    if (Date.now() - chunkStarted >= 45_000) break;
    if (index < terms.length - 1 && effectiveDelayMs > 0) await tab.playwright.waitForTimeout(effectiveDelayMs);
  }
  return { file, attempted: results.length, rows: results.reduce((total, result) => total + result.rows.length, 0), blocked: results.some((result) => result.blocked), rejected: results.filter((result) => result.term.outcome === "rejected").map((result) => ({ query: result.term.query, reason: result.term.reason })), empty: results.filter((result) => result.term.outcome === "empty").map((result) => result.term.query) };
}

async function captureNextDataVerificationChunkInternal({ tab, store, targets, file, sessionDirectory, screenshotSha256, interTermDelayMs }) {
  if (!CONFIG[store]) throw new Error("next-data verification adapter supports sams or walmart");
  const policy = await browserLanePolicy(store);
  const maxTargets = policy.maxTerms;
  const effectiveDelayMs = Math.max(interTermDelayMs ?? 0, policy.dynamicDelayMs);
  if (!Array.isArray(targets) || targets.length < 1 || targets.length > maxTargets) throw new Error(`${store} verification chunk requires 1-${maxTargets} targets`);
  if (!Number.isInteger(effectiveDelayMs) || effectiveDelayMs < 0 || effectiveDelayMs > 30_000) throw new Error(`${store} verification inter-target delay must be 0-30000ms`);
  const canary = await captureNextDataCanary(tab, store, screenshotSha256);
  const verifications = [];
  const chunkStarted = Date.now();
  for (let index = 0; index < targets.length; index += 1) {
    const target = targets[index];
    const previousCount = verifications.length;
    let captured = await captureTerm(tab, store, target.query);
    let row = findVerificationRow(captured.rows, target);
    if (!captured.blocked && captured.term.outcome !== "blocked" && !row && normalize(target.name) !== normalize(target.query)) {
      if (effectiveDelayMs > 0) await tab.playwright.waitForTimeout(effectiveDelayMs);
      const exactNameCapture = await captureTerm(tab, store, target.name);
      if (exactNameCapture.blocked || exactNameCapture.term.outcome === "blocked") captured = exactNameCapture;
      else {
        const exactNameRow = findVerificationRow(exactNameCapture.rows, target);
        if (exactNameRow) {
          captured = exactNameCapture;
          row = exactNameRow;
        }
      }
    }
    const observedAt = new Date().toISOString();
    if (captured.blocked || captured.term.outcome === "blocked") {
      verifications.push(...expandVerification(target, { observedAt, outcome: "blocked", reason: captured.term.reason || `${store} challenge detected during independent verification` }));
      await checkpointAdapterChunk(file, { version: 2, phase: "verification", store, canary, verifications }, previousCount, sessionDirectory);
      break;
    }
    if (!row) {
      verifications.push(...expandVerification(target, { observedAt, outcome: "missing", reason: captured.term.reason || "target product was absent from both the commodity and exact-name result envelopes" }));
    } else {
      const truth = { ...row._capture, capturedAt: observedAt };
      verifications.push(...expandVerification(target, {
        observedAt,
        outcome: "observed",
        productKey: row.url,
        name: row.n,
        sizeText: row.size,
        purchasePriceMinor: priceMinor(row.lp),
        truth,
      }));
    }
    await checkpointAdapterChunk(file, { version: 2, phase: "verification", store, canary, verifications }, previousCount, sessionDirectory);
    if (Date.now() - chunkStarted >= 45_000) break;
    if (index < targets.length - 1 && effectiveDelayMs > 0) await tab.playwright.waitForTimeout(effectiveDelayMs);
  }
  return {
    file,
    attempted: verifications.length,
    observed: verifications.filter((item) => item.outcome === "observed").length,
    missing: verifications.filter((item) => item.outcome === "missing").map((item) => item.rowKey),
    blocked: verifications.some((item) => item.outcome === "blocked"),
    budgetExhausted: Date.now() - chunkStarted >= 45_000,
  };
}

export async function captureNextDataChunk(options) {
  return withBrowserStoreLane(options.store, () => captureNextDataChunkInternal(options));
}

export async function captureNextDataVerificationChunk(options) {
  return withBrowserStoreLane(options.store, () => captureNextDataVerificationChunkInternal(options));
}
