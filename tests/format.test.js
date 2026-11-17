import test from "node:test";
import assert from "node:assert/strict";
import { ugx, dmy, dmyTime, kampalaDate, parseLogin, addDays } from "../src/lib/format.js";
import { rolesFor, hasAny } from "../src/lib/roles.js";

test("ugx: thousand separators, no decimals", () => {
  assert.equal(ugx(1585500), "1,585,500");
  assert.equal(ugx(0), "0");
  assert.equal(ugx(1234.6), "1,235");
});
test("dmy / Kampala time", () => {
  assert.equal(dmy("2026-10-12"), "12/10/2026");
  // 22:30 UTC on 16 Nov is 01:30 on 17 Nov in Kampala (UTC+3)
  assert.equal(kampalaDate(new Date("2026-11-16T22:30:00Z")), "2026-11-17");
  assert.equal(dmyTime("2026-11-16T22:30:00Z"), "17/11/2026 01:30");
});
test("addDays", () => { assert.equal(addDays("2026-11-30", 1), "2026-12-01"); });
test("parseLogin: email and Ugandan phone formats", () => {
  assert.deepEqual(parseLogin(" Keith@X.com "), { email: "keith@x.com" });
  for (const p of ["0772123456", "772123456", "+256 772 123 456", "256772123456", "00256772123456"])
    assert.deepEqual(parseLogin(p), { phone: "+256772123456" });
  assert.ok(parseLogin("abc").error);
});
test("roles are per module", () => {
  const roles = [
    { module: "payments", role: "cashier", site_id: "s1" },
    { module: "sales", role: "manager", site_id: "s1" },
  ];
  assert.deepEqual(rolesFor(roles, "payments"), ["cashier"]);
  assert.equal(hasAny(roles, "payments", ["d1", "d2"]), false);
  assert.equal(hasAny(roles, "sales", ["manager"]), true);
});
