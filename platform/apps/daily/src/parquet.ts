import { parquetWriteBuffer } from "hyparquet-writer";
import type { DirectCaptureArtifact } from "@thriftycrew/contracts";
import { digestHex, stableJson } from "@thriftycrew/domain";

type DirectObservation = DirectCaptureArtifact["observations"][number];

export interface ObservationLakeRow {
  observationId: string;
  productId: string;
  productVersionId: string;
  sourceId: string;
  storeLocationId: string;
  batchId: string;
  observation: DirectObservation;
}

export interface ObservationParquetPartition {
  bytes: Uint8Array;
  sha256: string;
  rows: number;
  minObservedAt: string;
  maxObservedAt: string;
  schemaVersion: 1;
}

/** Durable analytical representation of one capture batch. */
export async function buildObservationParquet(rows: readonly ObservationLakeRow[]): Promise<ObservationParquetPartition> {
  if (rows.length === 0) throw new Error("an observation partition cannot be empty");
  const ordered = [...rows].sort((left, right) => left.observation.capturedAt.localeCompare(right.observation.capturedAt)
    || left.observationId.localeCompare(right.observationId));
  const bytes = new Uint8Array(parquetWriteBuffer({
    columnData: [
      { name: "observation_id", data: ordered.map((row) => row.observationId), type: "STRING" },
      { name: "product_id", data: ordered.map((row) => row.productId), type: "STRING" },
      { name: "product_version_id", data: ordered.map((row) => row.productVersionId), type: "STRING" },
      { name: "source_id", data: ordered.map((row) => row.sourceId), type: "STRING" },
      { name: "store_location_id", data: ordered.map((row) => row.storeLocationId), type: "STRING" },
      { name: "batch_id", data: ordered.map((row) => row.batchId), type: "STRING" },
      { name: "external_product_key", data: ordered.map((row) => row.observation.externalProductKey), type: "STRING" },
      { name: "name", data: ordered.map((row) => row.observation.name), type: "STRING" },
      { name: "size_text", data: ordered.map((row) => row.observation.sizeText), type: "STRING" },
      { name: "kind", data: ordered.map((row) => row.observation.kind), type: "STRING" },
      { name: "purchase_price_minor", data: ordered.map((row) => row.observation.purchasePriceMinor), type: "INT32" },
      { name: "regular_price_minor", data: ordered.map((row) => row.observation.regularPriceMinor ?? null), type: "INT32" },
      { name: "per_unit_micros", data: ordered.map((row) => BigInt(row.observation.perUnitMicros)), type: "INT64" },
      { name: "normalized_basis_unit", data: ordered.map((row) => row.observation.normalizedBasisUnit), type: "STRING" },
      { name: "normalized_basis_qty_micros", data: ordered.map((row) => BigInt(row.observation.normalizedBasisQtyMicros)), type: "INT64" },
      { name: "captured_at", data: ordered.map((row) => new Date(row.observation.capturedAt)), type: "TIMESTAMP" },
      { name: "valid_from", data: ordered.map((row) => row.observation.validFrom ? new Date(row.observation.validFrom) : null), type: "TIMESTAMP" },
      { name: "valid_to", data: ordered.map((row) => row.observation.validTo ? new Date(row.observation.validTo) : null), type: "TIMESTAMP" },
      { name: "membership_required", data: ordered.map((row) => row.observation.membershipRequired), type: "BOOLEAN" },
      { name: "loyalty_required", data: ordered.map((row) => row.observation.loyaltyRequired), type: "BOOLEAN" },
      { name: "taxonomy_path", data: ordered.map((row) => row.observation.taxonomyPath ?? null), type: "STRING" },
      { name: "canonical_observation_json", data: ordered.map((row) => stableJson(row.observation)), type: "JSON" },
    ],
    rowGroupSize: 10_000,
    kvMetadata: [
      { key: "tc.schema", value: "grocery-observation-v1" },
      { key: "tc.source", value: ordered[0]!.sourceId },
      { key: "tc.batch", value: ordered[0]!.batchId },
    ],
  }));
  const observed = ordered.map((row) => row.observation.capturedAt);
  return { bytes, sha256: await digestHex(bytes), rows: ordered.length, minObservedAt: observed[0]!, maxObservedAt: observed.at(-1)!, schemaVersion: 1 };
}
