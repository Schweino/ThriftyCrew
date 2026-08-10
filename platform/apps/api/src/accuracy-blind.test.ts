import { describe, expect, it } from "vitest";
import { readAccuracyDraw } from "./accuracy";

describe("blind accuracy fan-out", () => {
  it("does not select the platform's product, URL, package, or price before reveal", async () => {
    const sql: string[] = [];
    const db = {
      prepare(statement: string) {
        sql.push(statement);
        return {
          bind() { return this; },
          async first() { return { id: "draw", status: "open" }; },
          async all() { return { results: [{ ordinal: 1, commodity_label: "Eggs", store_name: "Aldi" }] }; },
        };
      },
    } as unknown as D1Database;
    const draw = await readAccuracyDraw(db, "draw");
    expect(draw).toMatchObject({ blind: true, stores: { Aldi: [{ ordinal: 1, commodity_label: "Eggs", store_name: "Aldi" }] } });
    expect(sql[1]).not.toContain("product_url");
    expect(sql[1]).not.toContain("purchase_price_minor");
    expect(sql[1]).not.toContain("product_name");
  });
});
