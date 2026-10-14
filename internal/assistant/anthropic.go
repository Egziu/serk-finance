package assistant

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
)

// anthropic speaks the Claude Messages API (POST /v1/messages, tool use).
type anthropic struct {
	cfg  Config
	http *http.Client
}

func (a *anthropic) Describe() (string, string) { return "anthropic", a.cfg.Model }

type anthropicTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"input_schema"`
}

func (a *anthropic) Complete(ctx context.Context, r Request) (Response, error) {
	tools := make([]anthropicTool, len(r.Tools))
	for i, t := range r.Tools {
		tools[i] = anthropicTool{t.Name, t.Description, t.Schema}
	}
	messages := make([]map[string]any, len(r.Messages))
	for i, m := range r.Messages {
		blocks := make([]map[string]any, 0, len(m.Content))
		for _, b := range m.Content {
			switch b.Type {
			case "text":
				blocks = append(blocks, map[string]any{"type": "text", "text": b.Text})
			case "tool_use":
				input := b.Input
				if len(input) == 0 {
					input = json.RawMessage(`{}`)
				}
				blocks = append(blocks, map[string]any{"type": "tool_use", "id": b.ID, "name": b.Name, "input": input})
			case "tool_result":
				res := map[string]any{"type": "tool_result", "tool_use_id": b.ToolUseID, "content": b.Content}
				if b.IsError {
					res["is_error"] = true
				}
				blocks = append(blocks, res)
			}
		}
		messages[i] = map[string]any{"role": m.Role, "content": blocks}
	}
	body := map[string]any{"model": a.cfg.Model, "max_tokens": r.MaxTokens, "system": r.System, "messages": messages}
	if len(tools) > 0 {
		body["tools"] = tools
	}
	raw, e := json.Marshal(body)
	if e != nil {
		return Response{}, e
	}
	req, e := http.NewRequestWithContext(ctx, "POST", strings.TrimRight(a.cfg.BaseURL, "/")+"/v1/messages", bytes.NewReader(raw))
	if e != nil {
		return Response{}, e
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("x-api-key", a.cfg.APIKey)
	req.Header.Set("anthropic-version", "2023-06-01")
	resp, e := a.http.Do(req)
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
		Content []struct {
			Type  string          `json:"type"`
			Text  string          `json:"text"`
			ID    string          `json:"id"`
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		} `json:"content"`
		StopReason string `json:"stop_reason"`
	}
	if e := json.Unmarshal(data, &out); e != nil {
		return Response{}, &ProviderError{Code: "assistant_unavailable", Status: 502, Detail: "malformed response"}
	}
	res := Response{StopReason: out.StopReason}
	for _, c := range out.Content {
		switch c.Type {
		case "text":
			res.Content = append(res.Content, Block{Type: "text", Text: c.Text})
		case "tool_use":
			res.Content = append(res.Content, Block{Type: "tool_use", ID: c.ID, Name: c.Name, Input: c.Input})
		}
	}
	return res, nil
}
