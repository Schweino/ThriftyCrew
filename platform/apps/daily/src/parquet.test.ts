import { describe, expect, it } from "vitest";
import { parquetReadObjects } from "hyparquet";
import type { DirectCaptureArtifact } from "@thriftycrew/contracts";
import { buildObservationParquet } from "./parquet";

describe("observation Parquet partitions", () => {
  it("writes a self-contained canonical capture partition", async () => {
    const observation = {
      externalProductKey: "sku-1", name: "Milk", sizeText: "1 gal", kind: "everyday", currency: "USD",
      purchasePriceMinor: 399, purchaseQuantity: 1, packageCount: 1,
      capturedBasisUnit: "gal", capturedBasisQtyMicros: 1_000_000,
      normalizedBasisUnit: "gal", normalizedBasisQtyMicros: 1_000_000, perUnitMicros: 3_990_000,
      loyaltyRequired: false, membershipRequired: false, rawPriceText: "$3.99", rawSizeText: "1 gal",
      capturedAt: "2026-08-12T12:00:00.000Z", taxonomyPath: "Dairy/Milk",
    } as DirectCaptureArtifact["observations"][number];
    const partition = await buildObservationParquet([{
      observationId: "obs-1", productId: "prod-1", productVersionId: "pver-1",
      sourceId: "source", storeLocationId: "store", batchId: "batch", observation,
    }]);
    expect(new TextDecoder().decode(partition.bytes.slice(0, 4))).toBe("PAR1");
    expect(new TextDecoder().decode(partition.bytes.slice(-4))).toBe("PAR1");
    expect(partition.sha256).toMatch(/^[a-f0-9]{64}$/);
    const rows = await parquetReadObjects({ file: partition.bytes.buffer as ArrayBuffer });
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ observation_id: "obs-1", name: "Milk", purchase_price_minor: 399, taxonomy_path: "Dairy/Milk" });
    expect(JSON.parse(String(rows[0]!.canonical_observation_json))).toMatchObject({ externalProductKey: "sku-1", perUnitMicros: 3_990_000 });
  });
});
