package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"serk.finance/internal/accounting"
	"serk.finance/internal/assistant"
)

func schema(s string) json.RawMessage { return json.RawMessage(s) }

const dateProp = `{"type":"string","description":"Date as YYYY-MM-DD"}`

var assistantToolList = []assistant.Tool{
	{Name: "company_overview", Description: "Key figures for today: cash, receivables, payables, revenue and expenses this period, items awaiting approval.",
		Schema: schema(`{"type":"object","properties":{}}`)},
	{Name: "trial_balance", Description: "Trial balance as of a date (optionally only movements from a start date). Money in minor units.",
		Schema: schema(`{"type":"object","properties":{"as_of":` + dateProp + `,"from":` + dateProp + `},"required":["as_of"]}`)},
	{Name: "balance_sheet", Description: "Statement of financial position (IFRS presentation: current / non-current) as of a date.",
		Schema: schema(`{"type":"object","properties":{"as_of":` + dateProp + `},"required":["as_of"]}`)},
	{Name: "income_statement", Description: "Statement of profit or loss for a date range.",
		Schema: schema(`{"type":"object","properties":{"from":` + dateProp + `,"to":` + dateProp + `},"required":["from","to"]}`)},
	{Name: "account_ledger", Description: "Posted entries of one account between two dates, with running balance. At most 100 rows.",
		Schema: schema(`{"type":"object","properties":{"account_code":{"type":"string"},"from":` + dateProp + `,"to":` + dateProp + `,"limit":{"type":"integer","minimum":1,"maximum":100}},"required":["account_code","from","to"]}`)},
	{Name: "list_accounts", Description: "Chart of accounts: code, name, type, statement class. Optionally filter by type (ASSET, LIABILITY, EQUITY, REVENUE, OTHER_INCOME, COST_OF_SALES, EXPENSE, OTHER_EXPENSE) or text.",
		Schema: schema(`{"type":"object","properties":{"type":{"type":"string"},"search":{"type":"string"}}}`)},
	{Name: "list_journals", Description: "Recent journals, newest first, optionally by state (DRAFT, SUBMITTED, APPROVED, POSTED, VOIDED).",
		Schema: schema(`{"type":"object","properties":{"state":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":50}}}`)},
	{Name: "get_journal", Description: "One journal with its lines, by number (for example JRN-EFY2019-000003).",
		Schema: schema(`{"type":"object","properties":{"number":{"type":"string"}},"required":["number"]}`)},
	{Name: "list_documents", Description: "Sales invoices, supplier bills, payroll runs or stock openings with state and totals.",
		Schema: schema(`{"type":"object","properties":{"kind":{"type":"string","enum":["INVOICE","BILL","PAYROLL","OPENING"]},"state":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":50}},"required":["kind"]}`)},
	{Name: "vat_report", Description: "VAT report for a date range: output tax, input tax and net payable, by rate.",
		Schema: schema(`{"type":"object","properties":{"from":` + dateProp + `,"to":` + dateProp + `},"required":["from","to"]}`)},
	{Name: "find_parties", Description: "Find customers or vendors by name.",
		Schema: schema(`{"type":"object","properties":{"kind":{"type":"string","enum":["customer","vendor"]},"search":{"type":"string"}},"required":["kind"]}`)},
	{Name: "find_items", Description: "Find products and services by name or SKU, with price, stock quantity and value.",
		Schema: schema(`{"type":"object","properties":{"search":{"type":"string"}}}`)},
	{Name: "ledger_integrity", Description: "Check that posted journals balance and the audit chain is intact (needs audit permission).",
		Schema: schema(`{"type":"object","properties":{}}`)},
	{Name: "review_entries", Description: "Audit-style review of journals in a date range: flags manual entries to revenue, round or unusually large amounts, weekend dates, and drafts or submissions waiting more than 7 days. Use for 'anything unusual?' or before closing a period.",
		Schema: schema(`{"type":"object","properties":{"from":` + dateProp + `,"to":` + dateProp + `},"required":["from","to"]}`)},
	{Name: "draft_journal", Description: "Prepare a DRAFT manual journal for people to review, submit and approve. Lines must balance. Do not use it for invoices, bills, payroll or controlled accounts (receivables, payables, VAT, payroll liabilities, inventory) — those have their own documents or adjustments.",
		Schema: schema(`{"type":"object","properties":{"accounting_date":` + dateProp + `,"description":{"type":"string"},"reason":{"type":"string","description":"Why, and the supporting document"},"lines":{"type":"array","minItems":2,"items":{"type":"object","properties":{"account_code":{"type":"string"},"debit":{"type":"string","description":"Major units, e.g. 20000.00"},"credit":{"type":"string"},"description":{"type":"string"}},"required":["account_code"]}}},"required":["accounting_date","description","reason","lines"]}`)},
	{Name: "draft_sales_invoice", Description: "Prepare a DRAFT sales invoice on credit for people to review, submit and approve.",
		Schema: schema(`{"type":"object","properties":{"customer":{"type":"string","description":"Customer name"},"accounting_date":` + dateProp + `,"due_date":` + dateProp + `,"invoice_number":{"type":"string"},"lines":{"type":"array","minItems":1,"items":{"type":"object","properties":{"item":{"type":"string","description":"Item SKU or name"},"quantity":{"type":"string"},"unit_price":{"type":"string","description":"Major units, before tax"},"tax_code":{"type":"string","description":"For example VAT15; omit for no tax"}},"required":["item","quantity","unit_price"]}}},"required":["customer","accounting_date","lines"]}`)},
	{Name: "draft_supplier_bill", Description: "Prepare a DRAFT supplier bill on credit for people to review, submit and approve.",
		Schema: schema(`{"type":"object","properties":{"vendor":{"type":"string","description":"Vendor name"},"accounting_date":` + dateProp + `,"due_date":` + dateProp + `,"bill_number":{"type":"string","description":"The supplier's invoice number"},"lines":{"type":"array","minItems":1,"items":{"type":"object","properties":{"item":{"type":"string"},"quantity":{"type":"string"},"unit_price":{"type":"string"},"tax_code":{"type":"string"}},"required":["item","quantity","unit_price"]}}},"required":["vendor","accounting_date","bill_number","lines"]}`)},
}

type assistantTools struct {
	s       *Server
	r       *http.Request
	ac      assistantContext
	nonce   string
	request string
	seq     int
}

var codeText = regexp.MustCompile(`^[A-Za-z0-9._/ -]{1,64}$`)

// toolError turns a database or validation error into a safe message for the model.
func toolError(e error) error {
	var te *assistant.ToolError
	if errors.As(e, &te) {
		return te
	}
	var pg *pgconn.PgError
	if errors.As(e, &pg) && appCode.MatchString(pg.Message) {
		msg := strings.ReplaceAll(pg.Message, "_", " ")
		if pg.Message == "permission_denied" || pg.Code == "42501" {
			return &assistant.ToolError{Code: "permission_denied", Message: "The user's role does not allow this, or the module is switched off."}
		}
		if fieldKey.MatchString(pg.Detail) {
			msg += " (field " + pg.Detail + ")"
		}
		return &assistant.ToolError{Code: pg.Message, Message: msg}
	}
	if errors.As(e, &pg) && pg.Code == "42501" {
		return &assistant.ToolError{Code: "permission_denied", Message: "The user's role does not allow this."}
	}
	var p *problem
	if errors.As(e, &p) {
		return &assistant.ToolError{Code: p.code, Message: strings.ReplaceAll(p.code, "_", " ")}
	}
	if errors.Is(e, accounting.ErrInvalid) {
		return &assistant.ToolError{Code: "invalid_journal", Message: "The journal is incomplete or does not balance."}
	}
	return e
}

func bad(msg string) error { return &assistant.ToolError{Code: "invalid_input", Message: msg} }

func (t *assistantTools) one(sql string, args ...any) (json.RawMessage, error) {
	var out json.RawMessage
	e := t.s.scoped(t.r, func(tx pgx.Tx) error { return tx.QueryRow(t.r.Context(), sql, args...).Scan(&out) })
	return out, e
}

func (t *assistantTools) q(sql string, args ...any) (any, *assistant.Draft, error) {
	v, e := t.one(sql, args...)
	return v, nil, e
}

func date(v string, field string) (string, error) {
	if _, e := time.Parse("2006-01-02", v); e != nil {
		return "", bad(field + " must be a date as YYYY-MM-DD")
	}
	return v, nil
}

// major converts a decimal amount in the major unit ("20,000.50") to an exact minor-unit string.
func major(v string, places int) (string, error) {
	v = strings.ReplaceAll(strings.TrimSpace(v), ",", "")
	if v == "" {
		return "0", nil
	}
	if !regexp.MustCompile(`^[0-9]{1,20}(\.[0-9]+)?$`).MatchString(v) {
		return "", bad("amounts must be positive decimal numbers such as 20000.00")
	}
	r, ok := new(big.Rat).SetString(v)
	if !ok {
		return "", bad("invalid amount " + v)
	}
	r.Mul(r, new(big.Rat).SetInt(new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(places)), nil)))
	if !r.IsInt() {
		return "", bad(fmt.Sprintf("use at most %d decimal places", places))
	}
	return r.Num().String(), nil
}

func (t *assistantTools) key(tool string) string {
	t.seq++
	return fmt.Sprintf("ai:%s:%s:%d", t.nonce, tool, t.seq)
}

func (t *assistantTools) reason(given string) string {
	given = strings.TrimSpace(given)
	req := t.request
	if len(req) > 300 {
		req = req[:300] + "…"
	}
	out := "Prepared by the AI assistant at the user's request: " + req
	if given != "" {
		out = given + " — " + out
	}
	if len(out) > 1000 {
		out = out[:1000]
	}
	return out
}

func (t *assistantTools) Execute(ctx context.Context, name string, input json.RawMessage) (any, *assistant.Draft, error) {
	v, d, e := t.execute(name, input)
	if e != nil {
		return nil, nil, toolError(e)
	}
	return v, d, nil
}

func (t *assistantTools) execute(name string, input json.RawMessage) (any, *assistant.Draft, error) {
	var in map[string]any
	if len(input) > 0 && json.Unmarshal(input, &in) != nil {
		return nil, nil, bad("input must be a JSON object")
	}
	str := func(k string) string { s, _ := in[k].(string); return strings.TrimSpace(s) }
	num := func(k string, def, max int) int {
		f, ok := in[k].(float64)
		if !ok || f < 1 {
			return def
		}
		if int(f) > max {
			return max
		}
		return int(f)
	}
	switch name {
	case "company_overview":
		return t.q(`SELECT finance.dashboard($1::date)`, time.Now().Format("2006-01-02"))
	case "trial_balance":
		asOf, e := date(str("as_of"), "as_of")
		if e != nil {
			return nil, nil, e
		}
		var from any
		if f := str("from"); f != "" {
			if from, e = date(f, "from"); e != nil {
				return nil, nil, e
			}
		}
		return t.q(`SELECT ledger.trial_balance($1::date,$2::date)`, asOf, from)
	case "balance_sheet":
		asOf, e := date(str("as_of"), "as_of")
		if e != nil {
			return nil, nil, e
		}
		return t.q(`SELECT ledger.balance_sheet($1::date)`, asOf)
	case "income_statement", "vat_report":
		from, e := date(str("from"), "from")
		if e != nil {
			return nil, nil, e
		}
		to, e := date(str("to"), "to")
		if e != nil {
			return nil, nil, e
		}
		if name == "vat_report" {
			return t.q(`SELECT finance.tax_report($1::date,$2::date)`, from, to)
		}
		return t.q(`SELECT ledger.income_statement($1::date,$2::date)`, from, to)
	case "account_ledger":
		from, e := date(str("from"), "from")
		if e != nil {
			return nil, nil, e
		}
		to, e := date(str("to"), "to")
		if e != nil {
			return nil, nil, e
		}
		code := str("account_code")
		if !codeText.MatchString(code) {
			return nil, nil, bad("account_code is required")
		}
		var out json.RawMessage
		e = t.s.scoped(t.r, func(tx pgx.Tx) error {
			var id string
			if err := tx.QueryRow(t.r.Context(), `SELECT id::text FROM ledger.accounts WHERE company_id=security.company() AND code=$1`, code).Scan(&id); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return bad("no account with code " + code)
				}
				return err
			}
			return tx.QueryRow(t.r.Context(), `SELECT ledger.general_ledger($1::uuid,$2::date,$3::date,$4,NULL,NULL,NULL)`, id, from, to, num("limit", 50, 100)).Scan(&out)
		})
		return out, nil, e
	case "list_accounts":
		ref, e := t.one(`SELECT ledger.reference_data()->'accounts'`)
		if e != nil {
			return nil, nil, e
		}
		var accounts []map[string]any
		_ = json.Unmarshal(ref, &accounts)
		typ, search := strings.ToUpper(str("type")), strings.ToLower(str("search"))
		out := []map[string]any{}
		for _, a := range accounts {
			if typ != "" && a["type"] != typ {
				continue
			}
			if search != "" && !strings.Contains(strings.ToLower(fmt.Sprint(a["code"], " ", a["name"])), search) {
				continue
			}
			out = append(out, map[string]any{"code": a["code"], "name": a["name"], "type": a["type"], "statement_class": a["statement_class"],
				"posting_allowed": a["posting_allowed"], "active": a["active"]})
		}
		return out, nil, nil
	case "list_journals":
		var state any
		if s := strings.ToUpper(str("state")); s != "" {
			state = s
		}
		return t.q(`SELECT ledger.list_journals($1,NULL,NULL,$2)`, num("limit", 20, 50), state)
	case "get_journal":
		number := str("number")
		if !codeText.MatchString(number) {
			return nil, nil, bad("number is required")
		}
		var out json.RawMessage
		e := t.s.scoped(t.r, func(tx pgx.Tx) error {
			var id string
			if err := tx.QueryRow(t.r.Context(), `SELECT id::text FROM ledger.journals WHERE company_id=security.company() AND number=$1`, number).Scan(&id); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return bad("no journal numbered " + number + " that this user can see")
				}
				return err
			}
			return tx.QueryRow(t.r.Context(), `SELECT ledger.get_journal($1::uuid)`, id).Scan(&out)
		})
		return out, nil, e
	case "list_documents":
		kind := str("kind")
		if kind != "INVOICE" && kind != "BILL" && kind != "PAYROLL" && kind != "OPENING" {
			return nil, nil, bad("kind must be INVOICE, BILL, PAYROLL or OPENING")
		}
		raw, e := t.one(`SELECT finance.list_documents($1)`, kind)
		if e != nil {
			return nil, nil, e
		}
		var docs []map[string]any
		_ = json.Unmarshal(raw, &docs)
		state, limit := strings.ToUpper(str("state")), num("limit", 25, 50)
		out := []map[string]any{}
		for _, d := range docs {
			if state != "" && d["state"] != state {
				continue
			}
			out = append(out, map[string]any{"number": d["document_no"], "state": d["state"], "date": d["accounting_date"], "due_date": d["due_date"],
				"total_minor": d["total_amount"], "currency": d["currency"], "payment_state": d["payment_state"], "reversal_state": d["reversal_state"]})
			if len(out) >= limit {
				break
			}
		}
		return out, nil, nil
	case "find_parties":
		table, perm := "invoicing.customers", "sales.read"
		if str("kind") == "vendor" {
			table, perm = "invoicing.vendors", "purchases.read"
		}
		return t.module(perm, `SELECT coalesce(jsonb_agg(jsonb_build_object('name',name,'email',email,'phone',phone,'tin',tax_id,'active',active) ORDER BY name),'[]')
			FROM (SELECT * FROM `+table+` WHERE name ILIKE '%'||$1||'%' ORDER BY name LIMIT 25) t`, str("search"))
	case "find_items":
		return t.module("inventory.read", `SELECT coalesce(jsonb_agg(jsonb_build_object('sku',i.sku,'name',i.name,'type',i.type,'unit_price_minor',i.unit_price::text,
			'stock_quantity',coalesce(p.quantity,0)::text,'stock_value_minor',coalesce(p.value_minor,0)::text) ORDER BY i.name),'[]')
			FROM (SELECT * FROM inventory.items WHERE active AND (name ILIKE '%'||$1||'%' OR sku ILIKE '%'||$1||'%') ORDER BY name LIMIT 25) i
			LEFT JOIN finance.positions p ON p.item_id=i.id`, str("search"))
	case "review_entries":
		from, e := date(str("from"), "from")
		if e != nil {
			return nil, nil, e
		}
		to, e := date(str("to"), "to")
		if e != nil {
			return nil, nil, e
		}
		return t.q(reviewEntriesSQL, from, to)
	case "ledger_integrity":
		return t.q(`SELECT ledger.integrity_status()`)
	case "draft_journal":
		return t.draftJournal(in)
	case "draft_sales_invoice":
		return t.draftDocument("INVOICE", in)
	case "draft_supplier_bill":
		return t.draftDocument("BILL", in)
	}
	return nil, nil, &assistant.ToolError{Code: "unknown_tool", Message: "No such tool."}
}

func (t *assistantTools) module(permission, sql string, args ...any) (json.RawMessage, *assistant.Draft, error) {
	var out json.RawMessage
	e := t.s.scoped(t.r, func(tx pgx.Tx) error {
		if _, err := tx.Exec(t.r.Context(), `SELECT security.require($1)`, permission); err != nil {
			return err
		}
		return tx.QueryRow(t.r.Context(), sql, args...).Scan(&out)
	})
	return out, nil, e
}

func (t *assistantTools) draftJournal(in map[string]any) (any, *assistant.Draft, error) {
	var p struct {
		Date        string `json:"accounting_date"`
		Description string `json:"description"`
		Reason      string `json:"reason"`
		Lines       []struct {
			Code        string `json:"account_code"`
			Debit       string `json:"debit"`
			Credit      string `json:"credit"`
			Description string `json:"description"`
		} `json:"lines"`
	}
	raw, _ := json.Marshal(in)
	if json.Unmarshal(raw, &p) != nil || len(p.Lines) < 2 || len(p.Lines) > 100 {
		return nil, nil, bad("a journal needs at least two lines")
	}
	if _, e := date(p.Date, "accounting_date"); e != nil {
		return nil, nil, e
	}
	if t.ac.Branch == "" {
		return nil, nil, &assistant.ToolError{Code: "permission_denied", Message: "The user has no branch they may post to."}
	}
	j := accounting.CreateJournal{BranchID: t.ac.Branch, Date: p.Date, Description: strings.TrimSpace(p.Description), Currency: t.ac.Currency, FXRate: "1", Reason: t.reason(p.Reason)}
	var out json.RawMessage
	e := t.s.scoped(t.r, func(tx pgx.Tx) error {
		for i, l := range p.Lines {
			var id string
			if err := tx.QueryRow(t.r.Context(), `SELECT id::text FROM ledger.accounts WHERE company_id=security.company() AND code=$1`, strings.TrimSpace(l.Code)).Scan(&id); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return bad(fmt.Sprintf("line %d: no account with code %s", i+1, l.Code))
				}
				return err
			}
			dr, err := major(l.Debit, t.ac.Places)
			if err != nil {
				return err
			}
			cr, err := major(l.Credit, t.ac.Places)
			if err != nil {
				return err
			}
			j.Lines = append(j.Lines, accounting.Line{AccountID: id, Debit: dr, Credit: cr, Description: strings.TrimSpace(l.Description)})
		}
		if err := j.Validate(); err != nil {
			return err
		}
		b, _ := json.Marshal(j)
		return tx.QueryRow(t.r.Context(), `SELECT ledger.command($1,'create',$2::jsonb)`, t.key("journal"), string(b)).Scan(&out)
	})
	if e != nil {
		return nil, nil, e
	}
	var created struct {
		ID     string `json:"id"`
		Number string `json:"number"`
		State  string `json:"state"`
	}
	_ = json.Unmarshal(out, &created)
	return map[string]any{"status": "draft_created", "number": created.Number, "state": created.State,
			"next": "A person must review and submit it; a different authorised person approves and posts it."},
		&assistant.Draft{Kind: "JOURNAL", ID: created.ID, Number: created.Number, Summary: j.Description}, nil
}

func (t *assistantTools) draftDocument(kind string, in map[string]any) (any, *assistant.Draft, error) {
	var p struct {
		Customer string `json:"customer"`
		Vendor   string `json:"vendor"`
		Date     string `json:"accounting_date"`
		Due      string `json:"due_date"`
		Invoice  string `json:"invoice_number"`
		Bill     string `json:"bill_number"`
		Lines    []struct {
			Item     string `json:"item"`
			Quantity string `json:"quantity"`
			Price    string `json:"unit_price"`
			Tax      string `json:"tax_code"`
		} `json:"lines"`
	}
	raw, _ := json.Marshal(in)
	if json.Unmarshal(raw, &p) != nil || len(p.Lines) < 1 || len(p.Lines) > 100 {
		return nil, nil, bad("a document needs at least one line")
	}
	if _, e := date(p.Date, "accounting_date"); e != nil {
		return nil, nil, e
	}
	if p.Due == "" {
		p.Due = p.Date
	} else if _, e := date(p.Due, "due_date"); e != nil {
		return nil, nil, e
	}
	party, table, number, numberKey, partyKey := p.Customer, "invoicing.customers", p.Invoice, "invoice_number", "customer_id"
	if kind == "BILL" {
		party, table, number, numberKey, partyKey = p.Vendor, "invoicing.vendors", p.Bill, "bill_number", "vendor_id"
		if strings.TrimSpace(number) == "" {
			return nil, nil, bad("bill_number (the supplier's invoice number) is required")
		}
	}
	if strings.TrimSpace(number) == "" {
		number = "DRAFT-" + strings.ReplaceAll(p.Date, "-", "") + "-" + strings.ToUpper(t.nonce[:6])
	}
	body := map[string]any{"branch_id": t.ac.Branch, "accounting_date": p.Date, "due_date": p.Due, "settlement_type": "CREDIT", numberKey: strings.TrimSpace(number)}
	var out json.RawMessage
	e := t.s.scoped(t.r, func(tx pgx.Tx) error {
		ctx := t.r.Context()
		partyID, err := uniqueID(ctx, tx, `SELECT id::text FROM `+table+` WHERE active AND lower(name)=lower($1)`, `SELECT id::text FROM `+table+` WHERE active AND name ILIKE '%'||$1||'%'`, strings.TrimSpace(party))
		if err != nil {
			return err
		}
		if partyID == "" {
			return bad("could not identify exactly one active party named " + party + "; use find_parties")
		}
		body[partyKey] = partyID
		var lines []map[string]any
		for i, l := range p.Lines {
			itemID, err := uniqueID(ctx, tx, `SELECT id::text FROM inventory.items WHERE active AND (sku=$1 OR lower(name)=lower($1))`, `SELECT id::text FROM inventory.items WHERE active AND name ILIKE '%'||$1||'%'`, strings.TrimSpace(l.Item))
			if err != nil {
				return err
			}
			if itemID == "" {
				return bad(fmt.Sprintf("line %d: could not identify exactly one item %q; use find_items", i+1, l.Item))
			}
			qty := strings.ReplaceAll(strings.TrimSpace(l.Quantity), ",", "")
			if !regexp.MustCompile(`^[0-9]{1,12}(\.[0-9]{1,6})?$`).MatchString(qty) {
				return bad(fmt.Sprintf("line %d: quantity must be a positive number", i+1))
			}
			price, err2 := major(l.Price, t.ac.Places)
			if err2 != nil {
				return err2
			}
			line := map[string]any{"item_id": itemID, "quantity": qty, "unit_price": price}
			if tax := strings.TrimSpace(l.Tax); tax != "" {
				var taxID string
				if err := tx.QueryRow(ctx, `SELECT CASE WHEN count(*)=1 THEN min(id::text) END FROM taxes.tax_rates WHERE code=$1 AND effective_from<=$2::date AND (effective_to IS NULL OR effective_to>=$2::date)`, tax, p.Date).Scan(&taxID); err != nil || taxID == "" {
					return bad(fmt.Sprintf("line %d: no tax rate %s in force on %s", i+1, tax, p.Date))
				}
				line["tax_rate_id"] = taxID
			}
			lines = append(lines, line)
		}
		body["lines"] = lines
		b, _ := json.Marshal(body)
		return tx.QueryRow(ctx, `SELECT finance.document_command($1,$2,'create',$3::jsonb)`, t.key(strings.ToLower(kind)), kind, string(b)).Scan(&out)
	})
	if e != nil {
		return nil, nil, e
	}
	var created struct {
		ID       string `json:"id"`
		Number   string `json:"document_no"`
		State    string `json:"state"`
		Subtotal string `json:"subtotal"`
		Tax      string `json:"tax_total"`
		Total    string `json:"total_amount"`
	}
	_ = json.Unmarshal(out, &created)
	return map[string]any{"status": "draft_created", "number": created.Number, "state": created.State, "subtotal_minor": created.Subtotal,
			"tax_minor": created.Tax, "total_minor": created.Total, "next": "A person must review and submit it; a different authorised person approves it."},
		&assistant.Draft{Kind: kind, ID: created.ID, Number: created.Number, Summary: party}, nil
}

// uniqueID returns the single id matched exactly, else the single id matched loosely, else "".
func uniqueID(ctx context.Context, tx pgx.Tx, exact, loose, arg string) (string, error) {
	if arg == "" {
		return "", nil
	}
	for _, q := range []string{exact, loose} {
		rows, e := tx.Query(ctx, q+" LIMIT 2", arg)
		if e != nil {
			return "", e
		}
		ids, e := pgx.CollectRows(rows, pgx.RowTo[string])
		if e != nil {
			return "", e
		}
		if len(ids) == 1 {
			return ids[0], nil
		}
		if len(ids) > 1 {
			return "", nil
		}
	}
	return "", nil
}

// reviewEntriesSQL flags journals an auditor would look at first. It reads only what the
// caller's row-level security allows.
const reviewEntriesSQL = `WITH j AS (
  SELECT j.id,j.number,j.accounting_date,j.description,j.source_type,j.state,j.created_at,
   (SELECT sum(l.functional_debit_minor) FROM ledger.lines l WHERE l.journal_id=j.id) AS total,
   EXISTS(SELECT FROM ledger.lines l JOIN ledger.accounts a ON a.id=l.account_id WHERE l.journal_id=j.id AND a.type IN('REVENUE','OTHER_INCOME')) AS touches_revenue
  FROM ledger.journals j WHERE j.company_id=security.company() AND j.accounting_date BETWEEN $1::date AND $2::date AND j.state<>'VOIDED'),
 m AS (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY total) AS median FROM j WHERE total>0),
 f AS (SELECT j.*,array_remove(ARRAY[
   CASE WHEN j.source_type='MANUAL' AND j.touches_revenue THEN 'manual_entry_to_revenue' END,
   CASE WHEN j.total>=1000000 AND j.total%100000=0 THEN 'round_amount' END,
   CASE WHEN (SELECT median FROM m)>0 AND j.total>5*(SELECT median FROM m) THEN 'unusually_large' END,
   CASE WHEN extract(isodow FROM j.accounting_date) IN (6,7) THEN 'weekend_date' END,
   CASE WHEN j.state IN('DRAFT','SUBMITTED','APPROVED') AND j.created_at<now()-interval '7 days' THEN 'waiting_over_7_days' END],NULL) AS flags FROM j)
 SELECT jsonb_build_object('journals_reviewed',(SELECT count(*) FROM j),'median_total_minor',(SELECT median FROM m)::bigint::text,
  'flagged',coalesce((SELECT jsonb_agg(jsonb_build_object('number',number,'date',accounting_date,'description',description,'source',source_type,
   'state',state,'total_minor',total::text,'flags',flags) ORDER BY cardinality(flags) DESC,total DESC) FROM (SELECT * FROM f WHERE cardinality(flags)>0 ORDER BY cardinality(flags) DESC,total DESC LIMIT 50) x),'[]'::jsonb))`
