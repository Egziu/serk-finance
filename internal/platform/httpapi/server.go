package httpapi

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"os"
	"strings"
	"sync"
	"time"

	"serk.finance/internal/auth"
	"serk.finance/internal/mfa"
	"serk.finance/internal/platform/config"
	"serk.finance/internal/platform/database"
)

type Config struct {
	MFAKey     []byte
	RequireMFA bool
	// OptionalMFA lets a non-development (staging) deployment run without mandatory MFA. Set only
	// when SERK_ENV=staging and SERK_REQUIRE_MFA=false; production never sets it.
	OptionalMFA       bool
	Origin            string
	SecureCookies     bool
	StaticDir         string
	TrustedProxyCIDRs []string
	// DevShowOTP returns the current MFA code with the step-one challenge. It removes
	// the second factor and is refused unless the server runs in development mode.
	DevShowOTP bool
}
type Server struct {
	DB, AuthDB         *database.Pool
	Config             Config
	dummyHash          string
	loginSlots         chan struct{}
	loginQueue         chan struct{}
	loginLimits        *limiter
	limits             *limiter
	requests, failures uint64
	mu                 sync.Mutex
	trustedProxies     []netip.Prefix
}

// effectiveRequireMFA: any deployment with secure cookies (staging, production) requires MFA
// unless it explicitly opted out for staging tests.
func effectiveRequireMFA(c Config) bool {
	return c.RequireMFA || (c.SecureCookies && !c.OptionalMFA)
}

func New(db, authdb *database.Pool, c Config) (*Server, error) {
	c.RequireMFA = effectiveRequireMFA(c)
	if c.DevShowOTP && c.SecureCookies {
		return nil, errors.New("SERK_DEV_SHOW_OTP is allowed only in development")
	}
	if (c.RequireMFA || len(c.MFAKey) > 0) && len(c.MFAKey) != 32 {
		return nil, errors.New("MFA encryption key required")
	}
	if e := config.Origin(c.Origin, c.SecureCookies); e != nil {
		return nil, e
	}
	if c.StaticDir != "" {
		if info, e := os.Stat(c.StaticDir + "/index.html"); e != nil || !info.Mode().IsRegular() {
			return nil, errors.New("web bundle missing; build web assets first")
		}
	}
	var trusted []netip.Prefix
	for _, raw := range c.TrustedProxyCIDRs {
		prefix, e := netip.ParsePrefix(strings.TrimSpace(raw))
		if e != nil {
			return nil, errors.New("invalid trusted proxy CIDR")
		}
		if prefix.Bits() == 0 {
			return nil, errors.New("unrestricted proxy trust is forbidden")
		}
		trusted = append(trusted, prefix)
	}
	dummy, e := auth.Hash("unusable-" + time.Now().String())
	if e != nil {
		return nil, e
	}
	return &Server{DB: db, AuthDB: authdb, Config: c, trustedProxies: trusted, dummyHash: dummy, loginSlots: make(chan struct{}, 2), loginQueue: make(chan struct{}, 16), loginLimits: &limiter{}, limits: &limiter{}}, nil
}
func (s *Server) Handler() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /health/live", func(w http.ResponseWriter, r *http.Request) { write(w, 200, map[string]string{"status": "ok"}) })
	m.HandleFunc("GET /health/ready", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if e := s.DB.Ping(ctx); e != nil {
			write(w, 503, map[string]string{"status": "unavailable"})
			return
		}
		if e := s.AuthDB.Ping(ctx); e != nil {
			write(w, 503, map[string]string{"status": "unavailable"})
			return
		}
		write(w, 200, map[string]string{"status": "ready"})
	})
	m.HandleFunc("POST /api/v1/auth/login", s.login)
	m.HandleFunc("POST /api/v1/auth/login/mfa", s.loginMFA)
	m.HandleFunc("POST /api/v1/auth/logout", s.logout)
	m.HandleFunc("GET /api/v1/session", s.session)
	m.HandleFunc("GET /api/v1/accounting/reference", s.reference)
	m.HandleFunc("GET /api/v1/accounting/accounts", s.listAccounts)
	m.HandleFunc("POST /api/v1/accounting/accounts", s.createAccount)
	m.HandleFunc("PUT /api/v1/accounting/accounts/{id}", s.updateAccount)
	m.HandleFunc("POST /api/v1/organization/branches", s.createBranch)
	m.HandleFunc("POST /api/v1/organization/dimensions", s.createDimension)
	m.HandleFunc("POST /api/v1/invoicing/customers", s.createCustomer)
	m.HandleFunc("GET /api/v1/invoicing/customers", s.listCustomers)
	m.HandleFunc("POST /api/v1/invoicing/vendors", s.createVendor)
	m.HandleFunc("GET /api/v1/invoicing/vendors", s.listVendors)
	m.HandleFunc("POST /api/v1/invoicing/invoices", s.createInvoice)
	m.HandleFunc("GET /api/v1/invoicing/invoices", s.listInvoices)
	m.HandleFunc("POST /api/v1/invoicing/bills", s.createBill)
	m.HandleFunc("GET /api/v1/invoicing/bills", s.listBills)
	m.HandleFunc("POST /api/v1/taxes/agencies", s.createTaxAgency)
	m.HandleFunc("GET /api/v1/taxes/agencies", s.listTaxAgencies)
	m.HandleFunc("POST /api/v1/taxes/rates", s.createTaxRate)
	m.HandleFunc("GET /api/v1/taxes/rates", s.listTaxRates)
	m.HandleFunc("POST /api/v1/payroll/employees", s.createEmployee)
	m.HandleFunc("GET /api/v1/payroll/employees", s.listEmployees)
	m.HandleFunc("POST /api/v1/payroll/run", s.runPayroll)

	m.HandleFunc("POST /api/v1/invoicing/invoices/{id}/approve", s.approveInvoice)
	m.HandleFunc("POST /api/v1/invoicing/invoices/{id}/pay", s.payInvoice)
	m.HandleFunc("POST /api/v1/invoicing/bills/{id}/approve", s.approveBill)
	m.HandleFunc("POST /api/v1/invoicing/bills/{id}/pay", s.payBill)
	m.HandleFunc("POST /api/v1/inventory/items", s.createItem)
	m.HandleFunc("GET /api/v1/inventory/items", s.listItems)
	m.HandleFunc("GET /api/v1/accounting/journals", s.list)
	m.HandleFunc("GET /api/v1/accounting/journals/{id}", s.get)
	m.HandleFunc("POST /api/v1/accounting/journals", s.create)
	m.HandleFunc("POST /api/v1/accounting/journals/{id}/{action}", s.transition)
	m.HandleFunc("GET /api/v1/accounting/periods/{id}/close-preview", s.periodClosePreview)
	m.HandleFunc("POST /api/v1/accounting/periods/{id}/close", s.closePeriod)
	m.HandleFunc("POST /api/v1/accounting/fiscal-years", s.createFiscalYear)
	m.HandleFunc("GET /api/v1/reports/trial-balance", s.trial)
	m.HandleFunc("GET /api/v1/reports/general-ledger", s.generalLedger)
	m.HandleFunc("GET /api/v1/reports/balance-sheet", s.balanceSheet)
	m.HandleFunc("GET /api/v1/reports/income-statement", s.incomeStatement)
	m.HandleFunc("GET /api/v1/accounting/integrity", s.integrity)
	m.HandleFunc("GET /api/v1/taxes/liability", s.taxLiability)
	m.HandleFunc("GET /api/v1/audit/events", s.audit)
	// Access management. Writes are POST only: scoped() enforces CSRF on POST.
	m.HandleFunc("GET /api/v1/admin/catalog", s.adminCatalog)
	m.HandleFunc("POST /api/v1/admin/users", s.adminCreateUser)
	m.HandleFunc("POST /api/v1/admin/users/{id}/{action}", s.adminUserAction)
	m.HandleFunc("POST /api/v1/admin/roles", s.adminCreateRole)
	m.HandleFunc("POST /api/v1/admin/roles/{id}/{action}", s.adminRoleAction)

	m.HandleFunc("GET /api/v1/currencies", s.listCurrencies)
	m.HandleFunc("GET /api/v1/exchange-rates", s.listExchangeRates)
	m.HandleFunc("POST /api/v1/exchange-rates", s.addExchangeRate)

	m.HandleFunc("GET /api/v1/dashboard/metrics", s.dashboardMetrics)

	m.HandleFunc("GET /api/v1/profile/mfa", s.profileMFAStatus)
	m.HandleFunc("POST /api/v1/profile/mfa/enable", s.profileMFAEnable)
	m.HandleFunc("POST /api/v1/profile/mfa/disable", s.profileMFADisable)
	m.HandleFunc("POST /api/v1/profile/password", s.profilePassword)
	m.HandleFunc("GET /api/v1/finance/settings", s.financeSettings)
	m.HandleFunc("POST /api/v1/finance/settings", s.financeConfigure)
	m.HandleFunc("POST /api/v1/invoicing/invoices/{id}/{action}", s.invoiceAction)
	m.HandleFunc("POST /api/v1/invoicing/bills/{id}/{action}", s.billAction)
	m.HandleFunc("GET /api/v1/inventory/openings", s.listOpenings)
	m.HandleFunc("POST /api/v1/inventory/openings", s.createOpening)
	m.HandleFunc("POST /api/v1/inventory/openings/{id}/{action}", s.openingAction)
	m.HandleFunc("GET /api/v1/payroll/payruns", s.listPayruns)
	m.HandleFunc("POST /api/v1/payroll/payruns/{id}/{action}", s.payrunAction)
	m.HandleFunc("GET /api/v1/payroll/policies", s.payrollPolicies)
	// 0.2.2 period-end, adjustments and tax reporting
	m.HandleFunc("GET /api/v1/accounting/period-end", s.listPeriodEnd)
	m.HandleFunc("GET /api/v1/accounting/fiscal-years/{id}/close-preview", s.yearClosePreview)
	m.HandleFunc("POST /api/v1/accounting/year-close/{action}", s.controlledCommand("year-close"))
	m.HandleFunc("POST /api/v1/accounting/period-reopenings/{action}", s.controlledCommand("period-reopening"))
	m.HandleFunc("GET /api/v1/finance/adjustments", s.listAdjustments)
	m.HandleFunc("POST /api/v1/finance/adjustments/{action}", s.controlledCommand("adjustment"))
	m.HandleFunc("GET /api/v1/taxes/report", s.taxReport)
	m.HandleFunc("GET /api/v1/fx-policy", s.fxPolicy)
	m.HandleFunc("POST /api/v1/fx-policy", s.setFXPolicy)
	m.HandleFunc("GET /api/v1/exchange-rates/recorded", s.recordedRate)
	m.HandleFunc("GET /api/v1/organization/features", s.listFeatures)
	m.HandleFunc("POST /api/v1/organization/features", s.setFeature)
	m.HandleFunc("POST /api/v1/payroll/policies", s.payrollPolicyCreate)
	m.HandleFunc("POST /api/v1/payroll/policies/approve", s.payrollPolicyApprove)

	m.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) { s.fail(w, r, &problem{404, "not_found"}) })
	if s.Config.StaticDir != "" {
		files := http.FileServer(noListingFS{http.Dir(s.Config.StaticDir)})
		m.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				s.fail(w, r, &problem{405, "method_not_allowed"})
				return
			}
			if s.serveIndex(w, r) {
				return
			}
			files.ServeHTTP(w, r)
		})
	}
	return s.middleware(m)
}

func Run() error {
	ctx := context.Background()
	environment, e := config.Environment()
	if e != nil {
		return startupFailure("environment", e)
	}
	if e = config.Origin(os.Getenv("SERK_ORIGIN"), environment != "development"); e != nil {
		return startupFailure("origin", e)
	}
	dsn, e := config.Secret("DATABASE_URL")
	if e != nil {
		return startupFailure("database_secret", e)
	}
	authDSN, e := config.Secret("AUTH_DATABASE_URL")
	if e != nil {
		return startupFailure("authentication_database_secret", e)
	}
	db, e := database.Open(ctx, dsn, "serk_api")
	if e != nil {
		return startupFailure("database", e)
	}
	defer db.Close()
	a, e := database.Open(ctx, authDSN, "serk_auth")
	if e != nil {
		return startupFailure("authentication_database", e)
	}
	defer a.Close()
	var mfaKey []byte
	// Mandatory in production. A staging (test) deployment may set SERK_REQUIRE_MFA=false so
	// testers can sign in with a password and enrol an authenticator from their profile.
	requireMFA := environment == "production" || os.Getenv("SERK_REQUIRE_MFA") == "true" ||
		(environment == "staging" && os.Getenv("SERK_REQUIRE_MFA") != "false")
	if environment == "staging" && !requireMFA {
		fmt.Fprintln(os.Stderr, "WARNING: SERK_REQUIRE_MFA=false - two-factor authentication is optional in this staging deployment.")
	}
	if requireMFA || os.Getenv("SERK_MFA_KEY") != "" || os.Getenv("SERK_MFA_KEY_FILE") != "" {
		raw, err := config.Secret("SERK_MFA_KEY")
		if err != nil {
			return startupFailure("mfa_key", err)
		}
		mfaKey, err = mfa.ParseKey(raw)
		if err != nil {
			return startupFailure("mfa_key", err)
		}
	}
	devShowOTP := os.Getenv("SERK_DEV_SHOW_OTP") == "true"
	if devShowOTP && environment != "development" {
		return startupFailure("dev_show_otp", errors.New("SERK_DEV_SHOW_OTP is allowed only in development"))
	}
	if devShowOTP {
		fmt.Fprintln(os.Stderr, "WARNING: SERK_DEV_SHOW_OTP=true - MFA codes are shown on the sign-in screen. Development only.")
	}
	s, e := New(db, a, Config{DevShowOTP: devShowOTP, MFAKey: mfaKey, RequireMFA: requireMFA, OptionalMFA: environment == "staging" && !requireMFA, Origin: os.Getenv("SERK_ORIGIN"), SecureCookies: environment != "development", StaticDir: os.Getenv("SERK_WEB_DIR"), TrustedProxyCIDRs: strings.FieldsFunc(os.Getenv("SERK_TRUSTED_PROXY_CIDRS"), func(r rune) bool { return r == ',' })})
	if e != nil {
		return startupFailure("http_configuration", e)
	}
	addr := os.Getenv("SERK_LISTEN")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	server := &http.Server{Addr: addr, Handler: s.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 20 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	fmt.Println("SERK Finance API", addr)
	if e = serveWithShutdown(server); e != nil {
		return startupFailure("http_listener", e)
	}
	return nil
}
