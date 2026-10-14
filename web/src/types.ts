export type Company = { id: string; name: string; currency: string };
export type Session = {
  user_id: string;
  name: string;
  csrf_token: string;
  companies: Company[];
};
export type Account = {
  id: string;
  code: string;
  name: string;
  type: string;
  active: boolean;
  posting_allowed: boolean;
  control_account: boolean;
  normal_balance?: string;
  parent_id?: string | null;
  reporting_category?: string;
  statement_class?: string | null;
};
export type Period = {
  id: string;
  name: string;
  start_date: string;
  end_date: string;
  state: string;
  version: number;
  fiscal_year_id?: string;
};
export type Dimension = {
  id: string;
  kind: string;
  code: string;
  name: string;
  active: boolean;
};
export type Reference = {
  accounts: Account[];
  people?: { id: string; name: string }[];
  branches: { id: string; code: string; name: string; active?: boolean }[];
  periods: Period[];
  dimensions?: Dimension[];
  currencies: { code: string; minor_units: number }[];
  permissions: { create: boolean; audit: boolean; close: boolean; users?: boolean; roles?: boolean; configure?: boolean };
  held?: string[];
  features?: Record<string, boolean>;
};
export type LineDimension = { kind: string; dimension_id: string };
export type Journal = {
  id: string;
  number: string;
  description: string;
  accounting_date: string;
  created_at: string;
  currency: string;
  state: string;
  effective_state: string;
  version: number;
  debit_minor?: string;
  reason: string;
  functional_currency: string;
  fx_rate: string;
  reversed_from: string | null;
  branch_id?: string;
  period_id?: string;
  source_type?: string;
  source_document?: { kind: string; id: string; number: string; role: string } | null;
  sequence_no?: number;
  created_by?: string;
  submitted_by?: string | null;
  approved_by?: string | null;
  posted_by?: string | null;
  posted_at?: string | null;
  lines?: {
    line_no?: number;
    account_id: string;
    is_rounding?: boolean;
    account_code: string;
    account_name: string;
    description: string;
    debit_minor: string;
    credit_minor: string;
    functional_debit_minor: string;
    functional_credit_minor: string;
    dimensions?: LineDimension[];
  }[];
  permissions?: Record<string, boolean>;
};
export type Trial = {
  as_of: string;
  from?: string | null;
  currency: string;
  debit_minor: string;
  credit_minor: string;
  rows: {
    account_id: string;
    code: string;
    name: string;
    type: string;
    normal_balance?: string;
    debit_minor: string;
    credit_minor: string;
    net_debit_minor: string;
  }[];
};
export type Audit = {
  id: string;
  sequence_no: number;
  actor_id: string;
  recorded_at: string;
  action: string;
  entity_id: string;
  reason: string;
  event_hash: string;
  previous_hash: string;
  previous_state?: { state?: string; number?: string; version?: number } | null;
  new_state?: { state?: string; number?: string; version?: number } | null;
  request_context?: { remote_ip?: string; request_id?: string; user_agent?: string } | null;
};
export type GeneralLedger = {
  account: { id: string; code: string; name: string; type: string };
  from: string; as_of: string; generated_at: string; currency: string;
  company_wide: boolean; balance_convention: string;
  opening_minor: string; debit_minor: string; credit_minor: string; closing_minor: string;
  has_more: boolean;
  next_cursor: { after_date: string; after_id: string; after_line: number } | null;
  rows: {
    accounting_date: string; journal_id: string; number: string; line_no: number;
    description: string; journal_description: string; transaction_currency: string;
    transaction_debit_minor: string; transaction_credit_minor: string;
    debit_minor: string; credit_minor: string; running_minor: string; is_rounding: boolean;
  }[];
};
export type Integrity = {
  checked_at: string; company_id: string; scope: string; ok: boolean;
  posted_journals: number; audit_events: number; audit_head: string;
  unbalanced_posted_journals: number; audit_chain_errors: number; audit_head_errors: number;
  outbox_mismatches: number; journal_event_version_errors: number; limitations: string;
};
export type Grant = {
  role_id: string;
  role_name?: string;
  branch_id: string | null;
  branch_code?: string | null;
  approval_limit_minor: string | null;
};
export type AdminUser = {
  id: string;
  email: string;
  display_name: string;
  active: boolean;
  state: "ACTIVE" | "DISABLED";
  version: number;
  created_at: string;
  mfa_enrolled: boolean;
  grants: Grant[];
};
export type AdminRole = {
  id: string;
  name: string;
  description: string;
  version: number;
  permissions: string[];
  members: number;
};
export type PermissionInfo = { code: string; label: string; category: string };
export type AdminCatalog = {
  permissions: PermissionInfo[];
  roles: AdminRole[];
  users: AdminUser[];
  branches: { id: string; code: string; name: string }[];
  me: {
    user_id: string;
    permissions: string[];
    can_manage_users: boolean;
    can_manage_roles: boolean;
    approval_limit_minor: string | null;
  };
};
export type Customer = { id: string; name: string; email: string; phone: string; tax_id: string; active: boolean; };
export type Vendor = { id: string; name: string; email: string; phone: string; tax_id: string; active: boolean; };
export type Invoice = { id: string; customer_id: string; customer_name: string; invoice_number: string; issue_date: string; due_date: string; currency: string; subtotal: number; tax_total: number; total_amount: number; status: string; settlement_type?: string; payment_account_id?: string; payment_journal_id?: string; paid_at?: string; };
export type Bill = { id: string; vendor_id: string; vendor_name: string; bill_number: string; issue_date: string; due_date: string; currency: string; subtotal: number; tax_total: number; total_amount: number; status: string; settlement_type?: string; payment_account_id?: string; payment_journal_id?: string; paid_at?: string; };
