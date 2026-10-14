// Which accounts each finance field accepts. These mirror the database rules
// (finance.configure, finance.validate_item_accounts) so screens only offer usable accounts;
// the database still checks every save.
import type { Account } from "./types";

export type Reserved = { purpose: string; account_id: string };

export const mappingTypes: Record<string, string[]> = {
  receivable: ["ASSET"],
  payable: ["LIABILITY"],
  output_tax: ["LIABILITY"],
  input_tax: ["ASSET"],
  opening_equity: ["EQUITY"],
  retained_earnings: ["EQUITY"],
  payroll_expense: ["EXPENSE"],
  payroll_payable: ["LIABILITY"],
  payroll_tax: ["LIABILITY"],
  pension_expense: ["EXPENSE"],
  pension_payable: ["LIABILITY"],
};
export const controlKeys = ["receivable", "payable", "output_tax", "input_tax", "payroll_payable", "payroll_tax", "pension_payable"];

export const itemTypes: Record<string, string[]> = {
  income_account_id: ["REVENUE", "OTHER_INCOME"],
  expense_account_id: ["COST_OF_SALES", "EXPENSE"],
  asset_account_id: ["ASSET"],
};

const usable = (a: Account) => a.active && a.posting_allowed;
const byCode = (a: Account, b: Account) => a.code.localeCompare(b.code);

// An account mapped to a control purpose, or holding inventory, serves only that purpose.
// Older control records whose purpose now points elsewhere may be released by the server
// when unused, so they stay selectable and the server has the final word.
const inventoryHeld = (id: string, reserved: Reserved[]) => reserved.some((r) => r.account_id === id && r.purpose === "inventory");

/** Accounts that may be mapped to a settings field. */
export function mappingOptions(key: string, accounts: Account[], reserved: Reserved[], mappings: Record<string, string>, cash: string[]): Account[] {
  const types = mappingTypes[key] ?? [];
  const isControl = controlKeys.includes(key);
  return accounts
    .filter((a) => usable(a) && types.includes(a.type))
    .filter((a) => !isControl || !(cash.includes(a.id) || inventoryHeld(a.id, reserved) || controlKeys.some((k) => k !== key && mappings[k] === a.id)))
    .sort(byCode);
}

/** Asset accounts that may be ticked as bank or cash accounts. */
export function cashOptions(accounts: Account[], reserved: Reserved[], mappings: Record<string, string>): Account[] {
  const mapped = new Set(controlKeys.map((k) => mappings[k]).filter(Boolean));
  return accounts
    .filter((a) => usable(a) && a.type === "ASSET" && !a.control_account && !mapped.has(a.id) && !inventoryHeld(a.id, reserved))
    .sort(byCode);
}

/** Accounts an item field accepts. Inventory must not be a cash or another control account. */
export function itemOptions(key: string, accounts: Account[], reserved: Reserved[]): Account[] {
  const types = itemTypes[key] ?? [];
  return accounts
    .filter((a) => usable(a) && types.includes(a.type))
    .filter((a) => key !== "asset_account_id" || !reserved.some((r) => r.account_id === a.id && r.purpose !== "inventory"))
    .sort(byCode);
}

const pattern: Record<string, RegExp> = {
  income_account_id: /sales|revenue/i,
  expense_account_id: /cost of (goods|sales)|cogs/i,
  asset_account_id: /inventor|stock|merchandise/i,
};

/** Suggested item accounts: what existing items use most, else the best name match. */
export function itemDefaults(accounts: Account[], reserved: Reserved[], items: Record<string, unknown>[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of Object.keys(itemTypes)) {
    const options = itemOptions(key, accounts, reserved);
    const counts = new Map<string, number>();
    for (const it of items) {
      const id = it[key];
      if (typeof id === "string" && options.some((o) => o.id === id)) counts.set(id, (counts.get(id) ?? 0) + 1);
    }
    const used = [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
    out[key] = used ?? options.find((o) => pattern[key].test(o.name))?.id ?? options[0]?.id ?? "";
  }
  return out;
}
