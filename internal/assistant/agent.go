package assistant

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
)

// Executor runs one tool as the signed-in user. A *ToolError is reported back to the model
// (and the user) with its code; any other error is reported as an internal error.
type Executor interface {
	Execute(ctx context.Context, name string, input json.RawMessage) (result any, draft *Draft, err error)
}

// ToolError is a safe, user-meaningful tool failure (permission denied, not found, invalid
// input). The model sees the code and message and can explain or correct itself.
type ToolError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *ToolError) Error() string { return e.Code }

// Draft is something the assistant prepared for a person to review.
type Draft struct {
	Kind    string `json:"kind"` // JOURNAL | INVOICE | BILL
	ID      string `json:"id"`
	Number  string `json:"number"`
	Summary string `json:"summary"`
}

// Step records one tool call, for the user to see what the assistant looked at.
type Step struct {
	Tool string `json:"tool"`
	OK   bool   `json:"ok"`
	Note string `json:"note,omitempty"`
}

type Result struct {
	Reply    string  `json:"reply"`
	Steps    []Step  `json:"steps"`
	Drafts   []Draft `json:"drafts"`
	Provider string  `json:"provider"`
	Model    string  `json:"model"`
}

const (
	maxModelCalls   = 8
	maxToolsPerTurn = 6
	maxToolResult   = 24 << 10
	maxTokens       = 2048
)

// Run answers the last user message. history alternates user/assistant text turns; tool
// traffic of earlier turns is not replayed.
func Run(ctx context.Context, p Provider, system string, tools []Tool, exec Executor, history []Message) (Result, error) {
	provider, model := p.Describe()
	res := Result{Provider: provider, Model: model, Steps: []Step{}, Drafts: []Draft{}}
	msgs := append([]Message(nil), history...)
	known := map[string]bool{}
	for _, t := range tools {
		known[t.Name] = true
	}
	for call := 0; call < maxModelCalls; call++ {
		last := call == maxModelCalls-1
		if last && len(msgs) > 0 && msgs[len(msgs)-1].Role == "user" {
			// Tools stay declared (the API requires it once tool blocks exist); the model is told to stop.
			m := &msgs[len(msgs)-1]
			m.Content = append(m.Content, Block{Type: "text", Text: "Step limit reached. Answer now with what you have; do not call more tools."})
		}
		resp, e := p.Complete(ctx, Request{System: system, Messages: msgs, Tools: tools, MaxTokens: maxTokens})
		if e != nil {
			return res, e
		}
		var text []string
		var uses []Block
		for _, b := range resp.Content {
			switch b.Type {
			case "text":
				if strings.TrimSpace(b.Text) != "" {
					text = append(text, b.Text)
				}
			case "tool_use":
				uses = append(uses, b)
			}
		}
		if len(uses) == 0 || last {
			res.Reply = strings.TrimSpace(strings.Join(text, "\n\n"))
			if res.Reply == "" {
				res.Reply = "I could not produce an answer. Please rephrase the question."
			}
			return res, nil
		}
		msgs = append(msgs, Message{Role: "assistant", Content: resp.Content})
		results := make([]Block, 0, len(uses))
		for i, u := range uses {
			out := Block{Type: "tool_result", ToolUseID: u.ID}
			switch {
			case i >= maxToolsPerTurn:
				out.IsError, out.Content = true, `{"code":"too_many_tools","message":"Call at most six tools at a time."}`
			case !known[u.Name]:
				out.IsError, out.Content = true, `{"code":"unknown_tool","message":"No such tool."}`
			default:
				value, draft, err := exec.Execute(ctx, u.Name, u.Input)
				step := Step{Tool: u.Name, OK: err == nil}
				if err != nil {
					var te *ToolError
					if !errors.As(err, &te) {
						if ctx.Err() != nil {
							return res, ctx.Err()
						}
						te = &ToolError{Code: "internal_error", Message: "The tool failed. Try again later."}
					}
					step.Note = te.Code
					b, _ := json.Marshal(te)
					out.IsError, out.Content = true, string(b)
				} else {
					b, e := json.Marshal(value)
					if e != nil {
						return res, e
					}
					if len(b) > maxToolResult {
						b = append(b[:maxToolResult], []byte(`… [truncated: narrow the request, for example a shorter date range]`)...)
					}
					out.Content = string(b)
					if draft != nil {
						res.Drafts = append(res.Drafts, *draft)
						step.Note = draft.Kind + " " + draft.Number
					}
				}
				res.Steps = append(res.Steps, step)
			}
			results = append(results, out)
		}
		msgs = append(msgs, Message{Role: "user", Content: results})
	}
	res.Reply = "I stopped after several steps without a final answer. Please narrow the question."
	return res, nil
}
