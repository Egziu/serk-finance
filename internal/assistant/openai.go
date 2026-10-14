package assistant

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
)

// openAI speaks the OpenAI-compatible Chat Completions API (POST {base}/chat/completions),
// which local model servers such as Ollama and vLLM also offer. It lets an office installation
// run the assistant without sending data to the internet.
type openAI struct {
	cfg  Config
	http *http.Client
}

func (o *openAI) Describe() (string, string) { return "openai", o.cfg.Model }

func (o *openAI) Complete(ctx context.Context, r Request) (Response, error) {
	msgs := []map[string]any{{"role": "system", "content": r.System}}
	for _, m := range r.Messages {
		var text strings.Builder
		var calls []map[string]any
		for _, b := range m.Content {
			switch b.Type {
			case "text":
				text.WriteString(b.Text)
			case "tool_use":
				args := string(b.Input)
				if args == "" {
					args = "{}"
				}
				calls = append(calls, map[string]any{"id": b.ID, "type": "function", "function": map[string]any{"name": b.Name, "arguments": args}})
			case "tool_result":
				msgs = append(msgs, map[string]any{"role": "tool", "tool_call_id": b.ToolUseID, "content": b.Content})
			}
		}
		if text.Len() > 0 || len(calls) > 0 {
			msg := map[string]any{"role": m.Role, "content": text.String()}
			if len(calls) > 0 {
				msg["tool_calls"] = calls
			}
			msgs = append(msgs, msg)
		}
	}
	tools := make([]map[string]any, len(r.Tools))
	for i, t := range r.Tools {
		tools[i] = map[string]any{"type": "function", "function": map[string]any{"name": t.Name, "description": t.Description, "parameters": t.Schema}}
	}
	body := map[string]any{"model": o.cfg.Model, "messages": msgs, "max_tokens": r.MaxTokens}
	if len(tools) > 0 {
		body["tools"] = tools
	}
	raw, e := json.Marshal(body)
	if e != nil {
		return Response{}, e
	}
	req, e := http.NewRequestWithContext(ctx, "POST", strings.TrimRight(o.cfg.BaseURL, "/")+"/chat/completions", bytes.NewReader(raw))
	if e != nil {
		return Response{}, e
	}
	req.Header.Set("Content-Type", "application/json")
	if o.cfg.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+o.cfg.APIKey)
	}
	resp, e := o.http.Do(req)
	if e != nil {
		return Response{}, &ProviderError{Code: "assistant_unavailable", Status: 503, Detail: e.Error()}
	}
	defer resp.Body.Close()
	data, e := readLimited(resp)
	if e != nil {
		return Response{}, e
	}
	if resp.StatusCode != 200 {
		return Response{}, classify(resp.StatusCode, data)
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content   *string `json:"content"`
				ToolCalls []struct {
					ID       string `json:"id"`
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
	}
	if e := json.Unmarshal(data, &out); e != nil || len(out.Choices) == 0 {
		return Response{}, &ProviderError{Code: "assistant_unavailable", Status: 502, Detail: "malformed response"}
	}
	c := out.Choices[0]
	res := Response{StopReason: "end_turn"}
	if c.Message.Content != nil && *c.Message.Content != "" {
		res.Content = append(res.Content, Block{Type: "text", Text: *c.Message.Content})
	}
	for _, call := range c.Message.ToolCalls {
		input := json.RawMessage(call.Function.Arguments)
		if !json.Valid(input) {
			input = json.RawMessage(`{}`)
		}
		res.Content = append(res.Content, Block{Type: "tool_use", ID: call.ID, Name: call.Function.Name, Input: input})
	}
	if len(c.Message.ToolCalls) > 0 {
		res.StopReason = "tool_use"
	} else if c.FinishReason == "length" {
		res.StopReason = "max_tokens"
	}
	return res, nil
}
