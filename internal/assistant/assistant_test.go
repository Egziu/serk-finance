package assistant

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeAnthropic emulates the Messages API: the first call asks for a tool, the second answers
// with the tool result it received. It checks the request shape on every call.
func fakeAnthropic(t *testing.T) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/messages" || r.Header.Get("x-api-key") != "test-key" || r.Header.Get("anthropic-version") != "2023-06-01" {
			t.Errorf("unexpected request %s %v", r.URL.Path, r.Header)
			w.WriteHeader(400)
			return
		}
		var body struct {
			Model    string `json:"model"`
			System   string `json:"system"`
			Messages []struct {
				Role    string           `json:"role"`
				Content []map[string]any `json:"content"`
			} `json:"messages"`
			Tools []struct {
				Name        string          `json:"name"`
				InputSchema json.RawMessage `json:"input_schema"`
			} `json:"tools"`
		}
		raw, _ := io.ReadAll(r.Body)
		if e := json.Unmarshal(raw, &body); e != nil || body.Model != "claude-test" || len(body.Tools) != 1 || len(body.Tools[0].InputSchema) == 0 {
			t.Errorf("bad body %s", raw)
		}
		last := body.Messages[len(body.Messages)-1]
		if last.Content[0]["type"] == "tool_result" {
			if last.Content[0]["tool_use_id"] != "toolu_1" {
				t.Errorf("tool result not linked: %v", last.Content[0])
			}
			_, _ = w.Write([]byte(`{"content":[{"type":"text","text":"Cash is ETB ` + strings.Trim(last.Content[0]["content"].(string), `"`) + `."}],"stop_reason":"end_turn"}`))
			return
		}
		_, _ = w.Write([]byte(`{"content":[{"type":"text","text":"Checking."},{"type":"tool_use","id":"toolu_1","name":"cash","input":{"account":"1010"}}],"stop_reason":"tool_use"}`))
	}))
}

type execFunc func(ctx context.Context, name string, input json.RawMessage) (any, *Draft, error)

func (f execFunc) Execute(ctx context.Context, name string, input json.RawMessage) (any, *Draft, error) {
	return f(ctx, name, input)
}

var cashTool = []Tool{{Name: "cash", Description: "Cash balance", Schema: json.RawMessage(`{"type":"object","properties":{"account":{"type":"string"}}}`)}}

func TestAnthropicToolLoop(t *testing.T) {
	srv := fakeAnthropic(t)
	defer srv.Close()
	p, e := New(Config{Provider: "anthropic", Model: "claude-test", BaseURL: "http://127.0.0.1:" + strings.Split(srv.URL, ":")[2], APIKey: "test-key"})
	if e != nil {
		t.Fatal(e)
	}
	var got string
	res, e := Run(context.Background(), p, "system", cashTool, execFunc(func(_ context.Context, name string, in json.RawMessage) (any, *Draft, error) {
		got = name + string(in)
		return "1,250.00", nil, nil
	}), []Message{{Role: "user", Content: []Block{{Type: "text", Text: "How much cash?"}}}})
	if e != nil {
		t.Fatal(e)
	}
	if got != `cash{"account":"1010"}` || res.Reply != "Cash is ETB 1,250.00." || len(res.Steps) != 1 || !res.Steps[0].OK {
		t.Fatalf("got %q %+v", got, res)
	}
}

func TestOpenAICompatibleToolLoop(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		var body struct {
			Messages []map[string]any `json:"messages"`
			Tools    []map[string]any `json:"tools"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if r.URL.Path != "/v1/chat/completions" || body.Messages[0]["role"] != "system" || len(body.Tools) != 1 {
			t.Errorf("bad request %s %v", r.URL.Path, body)
		}
		if calls == 1 {
			_, _ = w.Write([]byte(`{"choices":[{"message":{"content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"cash","arguments":"{\"account\":\"1000\"}"}}]},"finish_reason":"tool_calls"}]}`))
			return
		}
		last := body.Messages[len(body.Messages)-1]
		if last["role"] != "tool" || last["tool_call_id"] != "call_1" {
			t.Errorf("tool message missing: %v", last)
		}
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"Done."},"finish_reason":"stop"}]}`))
	}))
	defer srv.Close()
	p, e := New(Config{Provider: "openai", Model: "llama3.1", BaseURL: srv.URL + "/v1"})
	if e != nil {
		t.Fatal(e)
	}
	res, e := Run(context.Background(), p, "system", cashTool, execFunc(func(context.Context, string, json.RawMessage) (any, *Draft, error) {
		return map[string]string{"balance": "10.00"}, nil, nil
	}), []Message{{Role: "user", Content: []Block{{Type: "text", Text: "cash?"}}}})
	if e != nil || res.Reply != "Done." || calls != 2 {
		t.Fatalf("%v %+v %d", e, res, calls)
	}
}

// scripted is a provider that always asks for the given tools, to test loop limits.
type scripted struct {
	calls int
	uses  []Block
}

func (s *scripted) Describe() (string, string) { return "test", "scripted" }
func (s *scripted) Complete(_ context.Context, r Request) (Response, error) {
	s.calls++
	return Response{Content: append([]Block{{Type: "text", Text: "working"}}, s.uses...), StopReason: "tool_use"}, nil
}

func TestLoopReportsToolErrorsDraftsAndStops(t *testing.T) {
	p := &scripted{uses: []Block{
		{Type: "tool_use", ID: "a", Name: "cash", Input: json.RawMessage(`{}`)},
		{Type: "tool_use", ID: "b", Name: "post_journal", Input: json.RawMessage(`{}`)},
	}}
	n := 0
	res, e := Run(context.Background(), p, "s", cashTool, execFunc(func(context.Context, string, json.RawMessage) (any, *Draft, error) {
		n++
		if n == 1 {
			return nil, nil, &ToolError{Code: "permission_denied", Message: "no"}
		}
		return "ok", &Draft{Kind: "JOURNAL", ID: "x", Number: "JRN-1"}, nil
	}), []Message{{Role: "user", Content: []Block{{Type: "text", Text: "go"}}}})
	if e != nil {
		t.Fatal(e)
	}
	// The unknown post_journal tool is never executed; the loop stops at the call limit.
	if p.calls != maxModelCalls || n != maxModelCalls-1 || res.Steps[0].OK || res.Steps[0].Note != "permission_denied" || len(res.Drafts) != maxModelCalls-2 || res.Reply != "working" {
		t.Fatalf("calls=%d n=%d %+v", p.calls, n, res)
	}
}

func TestProviderErrorsAreClassified(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
		_, _ = w.Write([]byte(`{"error":{"message":"invalid x-api-key"}}`))
	}))
	defer srv.Close()
	p, _ := New(Config{Provider: "anthropic", Model: "m", BaseURL: srv.URL, APIKey: "bad"})
	_, e := p.Complete(context.Background(), Request{MaxTokens: 10})
	pe, ok := e.(*ProviderError)
	if !ok || pe.Code != "assistant_key_rejected" {
		t.Fatalf("%v", e)
	}
}

func TestBaseURLPolicy(t *testing.T) {
	for raw, want := range map[string]bool{
		"https://api.anthropic.com":    true,
		"http://localhost:11434/v1":    true,
		"http://127.0.0.1:11434/v1":    true,
		"http://192.168.1.20:11434/v1": false,
		"http://example.com/v1":        false,
		"https://user:pw@example.com":  false,
		"ftp://example.com":            false,
		"https://example.com/v1?x=1":   false,
	} {
		if got := ValidateBaseURL(raw, false) == nil; got != want {
			t.Errorf("%s: got %v", raw, got)
		}
	}
	if ValidateBaseURL("http://192.168.1.20:11434/v1", true) != nil {
		t.Error("private HTTP should be allowed when enabled")
	}
	if _, e := New(Config{Provider: "anthropic"}); e != ErrNotConfigured {
		t.Errorf("missing key: %v", e)
	}
}

func TestRedirectsAreNotFollowed(t *testing.T) {
	var leaked bool
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked = r.Header.Get("x-api-key") != "" }))
	defer target.Close()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/v1/messages", http.StatusTemporaryRedirect)
	}))
	defer srv.Close()
	p, _ := New(Config{Provider: "anthropic", Model: "m", BaseURL: srv.URL, APIKey: "secret"})
	_, e := p.Complete(context.Background(), Request{MaxTokens: 10})
	pe, ok := e.(*ProviderError)
	if leaked || !ok || pe.Code != "assistant_redirect_refused" {
		t.Fatalf("leaked=%v err=%v", leaked, e)
	}
}

func TestExpiredContextIsReportedAsTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { time.Sleep(300 * time.Millisecond) }))
	defer srv.Close()
	p, _ := New(Config{Provider: "anthropic", Model: "m", BaseURL: srv.URL, APIKey: "k"})
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, e := p.Complete(ctx, Request{MaxTokens: 10})
	if !errors.Is(e, context.DeadlineExceeded) {
		t.Fatalf("%v", e)
	}
}

func TestLargeResultsStayValidJSONAndTypedNilToolErrorIsSafe(t *testing.T) {
	big := strings.Repeat("ብር", maxToolResult) // multi-byte characters
	out := limitResult([]byte(`"` + big + `"`))
	if len(out) > maxToolResult+1024 || !json.Valid([]byte(out)) || !strings.Contains(out, `"truncated":true`) {
		t.Fatalf("len=%d valid=%v", len(out), json.Valid([]byte(out)))
	}
	p := &scripted{uses: []Block{{Type: "tool_use", ID: "a", Name: "cash", Input: json.RawMessage(`{}`)}}}
	_, e := Run(context.Background(), p, "s", cashTool, execFunc(func(context.Context, string, json.RawMessage) (any, *Draft, error) {
		var te *ToolError
		return nil, nil, te
	}), []Message{{Role: "user", Content: []Block{{Type: "text", Text: "go"}}}})
	if e != nil {
		t.Fatal(e)
	}
}
