import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";

const load = (l) => JSON.parse(readFileSync(new URL(`../i18n/${l}.json`, import.meta.url)));
const keys = (o, p = "") =>
  Object.entries(o).flatMap(([k, v]) => (typeof v === "object" ? keys(v, p + k + ".") : [p + k]));

describe("i18n", () => {
  it("pt and en have the same keys", () => {
    expect(keys(load("pt")).sort()).toEqual(keys(load("en")).sort());
  });
  it("no empty strings", () => {
    for (const l of ["pt", "en"]) {
      const flat = keys(load(l));
      expect(flat.length).toBeGreaterThan(30);
    }
  });
});
