// Package assistant runs the Serk Finance AI assistant: a bounded tool-use loop over a
// language-model provider. The package knows nothing about the database; the caller supplies
// the tools and executes them as the signed-in user, so the assistant can never read or do
// more than that user may.
package assistant

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Block is one piece of message content, in a provider-neutral shape.
type Block struct {
	Type      string          `json:"type"` // text | tool_use | tool_result
	Text      string          `json:"text,omitempty"`
	ID        string          `json:"id,omitempty"`
	Name      string          `json:"name,omitempty"`
	Input     json.RawMessage `json:"input,omitempty"`
	ToolUseID string          `json:"tool_use_id,omitempty"`
	Content   string          `json:"content,omitempty"`
	IsError   bool            `json:"is_error,omitempty"`
}

// Message is one turn of the conversation.
type Message struct {
	Role    string  `json:"role"` // user | assistant
	Content []Block `json:"content"`
}

// Tool describes a function the model may call.
type Tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Schema      json.RawMessage `json:"input_schema"`
}

// Request and Response of one model call.
type Request struct {
	System    string
	Messages  []Message
	Tools     []Tool
	MaxTokens int
}
type Response struct {
	Content    []Block
	StopReason string // end_turn | tool_use | max_tokens
}

// Provider is a language-model backend.
type Provider interface {
	Complete(ctx context.Context, r Request) (Response, error)
	Describe() (provider, model string)
}

// Config selects and configures a provider.
type Config struct {
	Provider string // anthropic | openai
	Model    string
	BaseURL  string
	APIKey   string
	// AllowPrivateHTTP permits plain-HTTP base URLs on private networks (an office LLM server).
	AllowPrivateHTTP bool
}

// ErrNotConfigured means no provider is set up for this company or server.
var ErrNotConfigured = errors.New("assistant_not_configured")

// ProviderError is a failure reported by, or on the way to, the model provider. Its Code is a
// stable snake_case value that is safe to show; the detail stays in server logs.
type ProviderError struct {
	Code   string
	Status int
	Detail string
}

func (e *ProviderError) Error() string { return e.Code + ": " + e.Detail }

const (
	DefaultAnthropicModel = "claude-sonnet-5-5"
	anthropicURL          = "https://api.anthropic.com"
	callTimeout           = 60 * time.Second
)

// New builds a provider after validating its configuration.
func New(c Config) (Provider, error) {
	c.Provider = strings.ToLower(strings.TrimSpace(c.Provider))
	if c.Provider == "" {
		c.Provider = "anthropic"
	}
	if c.Model == "" && c.Provider == "anthropic" {
		c.Model = DefaultAnthropicModel
	}
	if c.Model == "" {
		return nil, ErrNotConfigured
	}
	if c.BaseURL == "" && c.Provider == "anthropic" {
		c.BaseURL = anthropicURL
	}
	if e := ValidateBaseURL(c.BaseURL, c.AllowPrivateHTTP); e != nil {
		return nil, e
	}
	client := &http.Client{Timeout: callTimeout}
	switch c.Provider {
	case "anthropic":
		if c.APIKey == "" {
			return nil, ErrNotConfigured
		}
		return &anthropic{cfg: c, http: client}, nil
	case "openai":
		return &openAI{cfg: c, http: client}, nil
	}
	return nil, fmt.Errorf("unknown provider %q", c.Provider)
}

// ValidateBaseURL accepts HTTPS anywhere and plain HTTP only on this machine (or, when allowed,
// on a private network), so a misconfigured URL cannot send keys or books over the internet in
// clear text.
func ValidateBaseURL(raw string, allowPrivateHTTP bool) error {
	u, e := url.Parse(raw)
	if e != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("invalid_base_url")
	}
	switch u.Scheme {
	case "https":
		return nil
	case "http":
		host := u.Hostname()
		if host == "localhost" {
			return nil
		}
		ip := net.ParseIP(host)
		if ip != nil && (ip.IsLoopback() || (allowPrivateHTTP && ip.IsPrivate())) {
			return nil
		}
	}
	return errors.New("invalid_base_url")
}

func readLimited(resp *http.Response) ([]byte, error) {
	const limit = 2 << 20
	body, e := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if e != nil {
		return nil, &ProviderError{Code: "assistant_unavailable", Status: 502, Detail: e.Error()}
	}
	if len(body) > limit {
		return nil, &ProviderError{Code: "assistant_response_too_large", Status: 502, Detail: "response over 2 MiB"}
	}
	return body, nil
}

func classify(status int, body []byte) error {
	detail := string(body)
	if len(detail) > 500 {
		detail = detail[:500]
	}
	switch {
	case status == 401 || status == 403:
		return &ProviderError{Code: "assistant_key_rejected", Status: 502, Detail: detail}
	case status == 429:
		return &ProviderError{Code: "assistant_rate_limited", Status: 503, Detail: detail}
	case status == 400 || status == 404 || status == 422:
		return &ProviderError{Code: "assistant_request_rejected", Status: 502, Detail: detail}
	default:
		return &ProviderError{Code: "assistant_unavailable", Status: 503, Detail: fmt.Sprintf("status %d: %s", status, detail)}
	}
}
