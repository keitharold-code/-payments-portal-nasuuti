import test from "node:test";
import assert from "node:assert/strict";
import { limitsFrom, parseAmount, formatAmount, allowedMethods, methodHint, deriveUrgency, payeeFor, validateCapture, DEFAULT_LIMITS } from "../src/lib/capture.js";

const L = DEFAULT_LIMITS;
test("amount parsing and formatting", () => {
  assert.equal(parseAmount("1,585,500"), 1585500);
  assert.equal(parseAmount(" 12 000 "), 12000);
  assert.equal(parseAmount(""), 0);
  assert.equal(formatAmount(1585500), "1,585,500");
  assert.equal(formatAmount(0), "");
});
test("limits come from settings, with defaults", () => {
  assert.equal(limitsFrom([{ key: "petty_cash_limit", value: 100000 }]).petty_cash_limit, 100000);
  assert.equal(limitsFrom([]).mobile_bank_ceiling, 1000000);
  assert.equal(limitsFrom([{ key: "unknown", value: 1 }]).unknown, undefined);
});
test("allowed methods by amount (boundaries)", () => {
  assert.deepEqual(allowedMethods(300000, L), ["bank_transfer", "mobile_money", "cheque", "petty_cash"]);
  assert.deepEqual(allowedMethods(300001, L), ["bank_transfer", "mobile_money"]);
  assert.deepEqual(allowedMethods(1000000, L), ["bank_transfer", "mobile_money"]);
  assert.deepEqual(allowedMethods(1000001, L), ["bank_transfer", "cheque"]);
  assert.deepEqual(allowedMethods(1200000, L).includes("petty_cash"), false);
  assert.equal(allowedMethods(0, L).length, 4);
  assert.deepEqual(allowedMethods(150000, { ...L, petty_cash_limit: 100000 }), ["bank_transfer", "mobile_money", "cheque"]);
});
test("method hint text", () => {
  assert.match(methodHint(1200000, L), /bank transfer or cheque only/);
  assert.match(methodHint(500000, L), /mobile money or bank transfer only/);
  assert.equal(methodHint(1000, L), "");
});
test("urgency: needed today or tomorrow is urgent", () => {
  assert.equal(deriveUrgency("2026-11-17", "2026-11-17"), "urgent");
  assert.equal(deriveUrgency("2026-11-18", "2026-11-17"), "urgent");
  assert.equal(deriveUrgency("2026-11-19", "2026-11-17"), "normal");
  assert.equal(deriveUrgency("2026-11-01", "2026-11-17"), "urgent");
});
test("payee panel follows the method", () => {
  const s = { name: "A", bank_name: "Stanbic", account_no: "1", account_name: "A Ltd", momo_number: null };
  assert.equal(payeeFor(s, "bank_transfer").ok, true);
  assert.equal(payeeFor(s, "mobile_money").ok, false);
  assert.match(payeeFor(s, "mobile_money").missing, /mobile money/);
  assert.equal(payeeFor(s, "cheque").ok, true);
});

const base = () => ({
  f: { requisition_book_id: "rb", requisition_serial: "012", department_id: "d", voucher_book_id: "vb", voucher_no: "431", amount: "1,585,500", method: "bank_transfer", date_required: "2026-11-20", description: "Stock" },
  ctx: { rbooks: [{ id: "rb", serial_from: 1, serial_to: 100 }], vbooks: [{ id: "vb", serial_from: 401, serial_to: 450 }],
         supplier: { name: "Psalms", bank_name: "S", account_no: "1" }, limits: L, deptName: "Shop", scanReady: true },
});
test("a complete capture validates clean", () => { const { f, ctx } = base(); assert.deepEqual(validateCapture(f, ctx), {}); });
test("acceptance 3: UGX 1,200,000 by petty cash is refused", () => {
  const { f, ctx } = base(); f.amount = "1,200,000"; f.method = "petty_cash";
  assert.ok(validateCapture(f, ctx).method);
});
test("required fields and ranges", () => {
  const { f, ctx } = base();
  assert.ok(validateCapture({ ...f, requisition_serial: "1234" }, ctx).requisition_serial);
  assert.ok(validateCapture({ ...f, requisition_serial: "101" }, ctx).requisition_serial);
  assert.ok(validateCapture({ ...f, voucher_no: "451" }, ctx).voucher_no);
  assert.ok(validateCapture({ ...f, voucher_no: "" }, ctx).voucher_no);
  assert.ok(validateCapture({ ...f, amount: "" }, ctx).amount);
  assert.ok(validateCapture({ ...f, description: "  " }, ctx).description);
  assert.ok(validateCapture(f, { ...ctx, supplier: null }).supplier_id);
  assert.ok(validateCapture(f, { ...ctx, scanReady: false }).scan);
});
test("salaries never by petty cash; missing payee details block bank", () => {
  const { f, ctx } = base();
  assert.ok(validateCapture({ ...f, amount: "100,000", method: "petty_cash" }, { ...ctx, deptName: "Staff & Wages" }).method);
  assert.ok(validateCapture(f, { ...ctx, supplier: { name: "X" } }).method);
});
