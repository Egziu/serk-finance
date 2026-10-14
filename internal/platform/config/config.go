// Package config validates deployment inputs before any network connection.
package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
)

func Environment() (string, error) {
	e := os.Getenv("SERK_ENV")
	switch e {
	case "development", "staging", "production", "office":
		return e, nil
	default:
		return "", errors.New("SERK_ENV must be development, staging, production or office")
	}
}

// Secret supports mounted secrets without placing credentials in command arguments.
func Secret(name string) (string, error) {
	v, path := os.Getenv(name), os.Getenv(name+"_FILE")
	if v != "" && path != "" {
		return "", fmt.Errorf("configure only %s or %s_FILE", name, name)
	}
	if path != "" {
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 16384 {
			return "", fmt.Errorf("invalid %s_FILE", name)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("cannot read %s_FILE", name)
		}
		v = strings.TrimSpace(string(b))
	}
	if v == "" {
		return "", fmt.Errorf("%s is required", name)
	}
	return v, nil
}

func Origin(raw string, secure bool) error {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil || u.Opaque != "" || u.Path != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || raw != u.Scheme+"://"+u.Host || strings.ContainsAny(raw, "\r\n\\") {
		return errors.New("SERK_ORIGIN must be an exact origin without path, credentials, query, or fragment")
	}
	if secure {
		if u.Scheme != "https" {
			return errors.New("secure environments require an HTTPS origin")
		}
	} else if raw != "http://localhost:8080" && raw != "http://127.0.0.1:8080" {
		return errors.New("development origin must be loopback port 8080")
	}
	return nil
}

// OfficeOrigins validates the origins an office installation answers on: exact http or https
// origins (this computer's name and addresses on the local network). At least one is required.
func OfficeOrigins(list []string) error {
	if len(list) == 0 || len(list) > 64 {
		return errors.New("an office installation needs 1 to 64 origins")
	}
	for _, raw := range list {
		u, err := url.Parse(raw)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || raw != u.Scheme+"://"+u.Host || strings.ContainsAny(raw, "\r\n\\") {
			return fmt.Errorf("invalid office origin %q", raw)
		}
	}
	return nil
}
