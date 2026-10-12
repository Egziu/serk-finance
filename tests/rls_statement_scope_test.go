package tests

import (
	"context"
	"regexp"
	"testing"
)

// Row-independent security context must be evaluated once per statement (InitPlan),
// never per row. A bare call such as tenant_id=security.tenant() in a policy or
// helper is re-executed for every examined row because SECURITY DEFINER functions
// are not inlined; on native PostgreSQL that made a 500-line journal exceed the
// runtime statement timeout (fixed by migration 010).
var bareSecurityCall = regexp.MustCompile(`security\.(actor|tenant|company)\(\)|security\.has\('|security\.can\('`)
var hoistedSecurityCall = regexp.MustCompile(`\(\s*SELECT\s+security\.(actor|tenant|company)\(\)\s*(AS\s+\w+\s*)?\)|\(\s*SELECT\s+security\.(has|can)\('[^']*'(::text)?\)\s*(AS\s+\w+\s*)?\)`)

func assertStatementScoped(t *testing.T, where, source string) {
	t.Helper()
	remaining := hoistedSecurityCall.ReplaceAllString(source, "")
	if loc := bareSecurityCall.FindStringIndex(remaining); loc != nil {
		t.Errorf("%s evaluates security context per row: %q", where, remaining[loc[0]:loc[1]])
	}
}

func TestSecurityContextIsStatementScoped(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	rows, e := f.admin.Query(ctx, `SELECT schemaname||'.'||tablename||' '||policyname, coalesce(qual,''), coalesce(with_check,'') FROM pg_policies ORDER BY 1`)
	if e != nil {
		t.Fatal(e)
	}
	policies := 0
	for rows.Next() {
		var name, qual, check string
		if e = rows.Scan(&name, &qual, &check); e != nil {
			t.Fatal(e)
		}
		policies++
		assertStatementScoped(t, "policy "+name+" USING", qual)
		assertStatementScoped(t, "policy "+name+" WITH CHECK", check)
	}
	if e = rows.Err(); e != nil {
		t.Fatal(e)
	}
	if policies < 22 {
		t.Fatalf("expected the reviewed policy set, found %d policies", policies)
	}
	for _, fn := range []string{"tenant", "company", "can", "has"} {
		var body string
		if e = f.admin.QueryRow(ctx, `SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='security' AND p.proname=$1`, fn).Scan(&body); e != nil {
			t.Fatal(fn, e)
		}
		assertStatementScoped(t, "function security."+fn, body)
	}
	var version string
	if e = f.admin.QueryRow(ctx, `SELECT security.release_version()`).Scan(&version); e != nil || version != "0.2.0-rc4" {
		t.Fatal("unexpected schema version", version, e)
	}
}
