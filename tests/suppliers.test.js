import test from "node:test";
import assert from "node:assert/strict";
import { norm, needsConfirmation, payeeSummary, matches, findDuplicate, toPayload, validateSupplier } from "../src/lib/suppliers.js";

test("norm ignores case, spaces and punctuation (same as the database name_key)", () => {
  assert.equal(norm("  Psalms  Food-Industry. "), "psalmsfoodindustry");
  assert.equal(norm("Kyoga Millers"), norm("kyoga-millers!"));
});
test("needsConfirmation", () => {
  assert.equal(needsConfirmation({}), false);
  assert.equal(needsConfirmation({ details_changed_at: "2026-11-17T10:00:00Z" }), true);
  assert.equal(needsConfirmation({ details_changed_at: "2026-11-17T10:00:00Z", details_verified_at: "2026-11-17T11:00:00Z" }), false);
  assert.equal(needsConfirmation({ details_changed_at: "2026-11-17T12:00:00Z", details_verified_at: "2026-11-17T11:00:00Z" }), true);
});
test("payeeSummary", () => {
  assert.equal(payeeSummary({ bank_name: "Stanbic", account_no: "9030001" }), "Stanbic · 9030001");
  assert.equal(payeeSummary({ momo_number: "0772", momo_name: "Ann" }), "MoMo 0772 (Ann)");
  assert.equal(payeeSummary({}), "");
});
test("search matches name, alias, phone, account", () => {
  const s = { name: "Kyoga Millers", aliases: ["KM"], phone: "0772 111", account_no: "55" };
  for (const q of ["kyoga", "km", "0772111", "55", ""]) assert.ok(matches(s, q), q);
  assert.ok(!matches(s, "nile"));
});
test("duplicate detection excludes the supplier being edited", () => {
  const list = [{ id: "1", name: "Kyoga Millers" }, { id: "2", name: "Nile" }];
  assert.equal(findDuplicate(list, "kyoga-MILLERS", null).id, "1");
  assert.equal(findDuplicate(list, "kyoga-MILLERS", "1"), null);
  assert.equal(findDuplicate(list, "", null), null);
});
test("toPayload: create carries site_id, edit carries id; aliases split", () => {
  const f = { name: " A ", aliases: "x, ,y", default_method: "bank_transfer" };
  assert.deepEqual(toPayload(f, "S", null).aliases, ["x", "y"]);
  assert.equal(toPayload(f, "S", null).site_id, "S");
  assert.equal(toPayload(f, "S", "ID").id, "ID");
  assert.equal(toPayload(f, "S", "ID").site_id, undefined);
  assert.equal(toPayload(f, "S", null).name, "A");
});
test("validateSupplier", () => {
  assert.deepEqual(validateSupplier({ name: "A" }), []);
  assert.ok(validateSupplier({ name: "" }).length);
  assert.ok(validateSupplier({ name: "A", bank_name: "X" }).length);
  assert.ok(validateSupplier({ name: "A", momo_number: "abc" }).length);
  assert.deepEqual(validateSupplier({ name: "A", momo_number: "0772 123 456" }), []);
});
