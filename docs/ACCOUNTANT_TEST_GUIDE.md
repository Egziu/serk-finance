# Accountant test guide — Serk Finance 0.3.0-rc1

Thank you for testing. This is a **test environment with fictional data**. Nothing you enter is real, and the workspace can be reset at any time. Please try to break it. Every wrong number, confusing screen or missing feature you report is valuable.

## Sign in

- **Address:** https://serk-finance-production.up.railway.app
- **Workspace:** `demo`
- **Password:** supplied separately. Change it from your profile after the first sign-in. You can also turn on two-factor authentication there.

| Email | Role | What the role may do |
|---|---|---|
| `admin@serk.demo` | Administrator | Everything, including users, roles and module switches |
| `chief.accountant@serk.demo` | Chief Accountant | All accounting, approval and configuration; not users/roles |
| `accountant@serk.demo` | Accountant | Prepares journals, invoices, bills, stock and tax entries; **cannot approve** |
| `manager@serk.demo` | Finance Manager | Approves and posts, reverses, closes periods and years |
| `payroll@serk.demo` | Payroll Officer | Employees and payroll only |
| `sales@serk.demo` | Sales Clerk | Customers, sales invoices, stock enquiry |
| `auditor@serk.demo` | Auditor (read only) | Reads everything, audit history; changes nothing |

Every financial entry needs **two different people**: one prepares and submits, another approves and posts. To test this, use two browsers, or a normal and a private window, signed in as different users.

## The company

**Abay Demo Trading PLC** trades in ETB and has two branches, Mekelle and Addis.

- **Fiscal year:** EFY 2019, from Hamle 1 (8 July 2026) to Sene 30 (7 July 2027). It has 13 periods: Hamle, Nehase, Pagume (5 days), then Meskerem to Sene.
- **Chart of accounts:** an Ethiopian trading SME, laid out for IFRS for SMEs presentation. Every asset and liability is marked current or non-current.
- **Already posted:**
  - Share capital of ETB 5,000,000 paid into CBE.
  - A purchase of 100 bags of teff at ETB 5,000 plus 15% VAT.
  - A sale of 20 bags at ETB 6,500 plus 15% VAT, with cost of sales at weighted-average cost.
- **Master data:** two customers, one supplier, three items (two stock items, one service), three employees.
- **Sample settings — please verify:**
  - VAT 15%.
  - Monthly employment income tax bands of 0% up to 2,000, then 15%, 20%, 25%, 30% and 35% above 14,000, as amended in 2025.
  - Pension at 7% employee and 11% employer.
  - These are **samples, not legal advice**. Tell us where they or their application are wrong, for example taxable base, pension cap or rounding.

## Suggested test scenarios

1. **Journals.** As Accountant, create a journal, save, submit. As Finance Manager, approve and post. Check that the Accountant cannot approve their own entry. Reverse a posted journal and check the reversal mirrors it.
2. **Sales and VAT.** Create a sales invoice with VAT, submit, approve. Then:
   - Check receivables, revenue, output VAT and cost of sales in the trial balance and general ledger.
   - Record a payment.
   - Run **Taxes & Rates → VAT report** for the month.
3. **Purchases.** Enter a supplier bill for stock with VAT, approve, pay. Check that input VAT and inventory increase.
4. **Inventory.** Count a shortage and a write-down under **Adjustments → Inventory adjustment**. The system values shortages at weighted-average cost. Check that the item value and the ledger agree.
5. **VAT settlement.** Under **Adjustments**, use **VAT / tax settlement**: Dr Output VAT, Cr Input VAT, Cr Bank for the net. A different user approves it.
6. **Payroll.** As Payroll Officer, run monthly payroll. In this version the pay period is a Gregorian month (for example 1–31 October 2026), and the payroll is dated on the period's last day, 31 October. Then:
   - Check gross pay, PAYE, pension and net pay per employee against your own calculation.
   - Approve the run as a different user.
   - Remit PAYE and pension through **Adjustments → Payroll remittance**.
7. **Periods.** Close Pagume. Try to post into it, which should be refused. Request a reopen and approve it as a different user.
8. **Year-end.** Under **Year-end & reopen**, preview the close for EFY 2019 and read the blockers. A full close needs every earlier period closed.
9. **Reports.** Check the trial balance, the balance sheet and the profit or loss statement for a date range. Export CSV and print. Is the presentation what you expect under IFRS for SMEs? What is missing (cash-flow statement, changes in equity, comparatives, notes)?
10. **Roles and modules.**
    - As Administrator, open **Users & roles**: create a role with exactly the permissions you want and assign a user.
    - Open **Modules & features** and switch a module off (for example Payroll). It disappears for everyone; switch it back on and the data returns.
    - Every change is in **Audit history**.
11. **Foreign currency.** Record a USD rate under **Currencies & Rates**, then post a USD journal. Rates older than 7 days, or more than 2% away from the recorded rate, are refused. Both limits can be changed on that page.

## How to report what you find

For each finding, send:

- The user you were signed in as.
- The screen.
- What you did.
- What you expected versus what happened, with a screenshot if you can.

Please also say whether the result is **wrong** (incorrect accounting), **missing** (a feature an Ethiopian SME needs) or **unclear** (wording or screen flow). The audit history records every action with its time, which helps us trace issues.

## Known limits in this version

These are planned, and most are on the roadmap:

- Partial payments and allocation, aging reports and statements.
- Bank reconciliation.
- Fixed-asset register and depreciation run.
- Cash-flow statement, changes in equity and comparative columns.
- Payroll by Ethiopian month (pay periods are Gregorian months for now) and the pension contribution ceiling.
- Withholding tax certificates and TOT.
- Ministry of Revenues return layouts and printed tax invoices.
- Amharic and other languages.
- The AI assistant.
