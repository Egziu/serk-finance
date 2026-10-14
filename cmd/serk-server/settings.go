package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

// Settings of one office installation, kept in <data>/serk.json. The file holds secrets (the
// database owner password, runtime login passwords and the key that encrypts authenticator
// secrets and AI keys), so it is readable only by the account that runs Serk Finance.
type Settings struct {
	Version          int      `json:"version"`
	Port             int      `json:"port"`
	ListenAll        bool     `json:"listen_on_network"` // false: this computer only
	DBPort           int      `json:"database_port"`
	OperatorPassword string   `json:"database_owner_password"`
	APIPassword      string   `json:"api_login_password"`
	AuthPassword     string   `json:"auth_login_password"`
	MFAKey           string   `json:"encryption_key"`
	ExtraOrigins     []string `json:"extra_origins,omitempty"`
	Practice         bool     `json:"practice_workspace,omitempty"`
	PracticePassword string   `json:"practice_password,omitempty"`
}

func secret(n int) string {
	b := make([]byte, n)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func settingsPath(data string) string { return filepath.Join(data, "serk.json") }

// loadSettings reads the settings, creating them with fresh secrets on first start.
func loadSettings(data string) (*Settings, bool, error) {
	raw, e := os.ReadFile(settingsPath(data))
	if errors.Is(e, os.ErrNotExist) {
		key := make([]byte, 32)
		if _, e := rand.Read(key); e != nil {
			return nil, false, e
		}
		s := &Settings{Version: 1, Port: 8080, ListenAll: true, DBPort: 55432, OperatorPassword: secret(24), APIPassword: secret(24),
			AuthPassword: secret(24), MFAKey: base64.StdEncoding.EncodeToString(key)}
		return s, true, s.save(data)
	}
	if e != nil {
		return nil, false, fmt.Errorf("cannot read settings: %w", e)
	}
	var s Settings
	if e = json.Unmarshal(raw, &s); e != nil {
		return nil, false, fmt.Errorf("settings file is damaged: %w", e)
	}
	if s.Port < 1 || s.Port > 65535 || s.DBPort < 1 || s.DBPort > 65535 || len(s.OperatorPassword) < 24 || len(s.APIPassword) < 24 || len(s.AuthPassword) < 24 {
		return nil, false, errors.New("settings file is incomplete")
	}
	return &s, false, nil
}

func (s *Settings) save(data string) error {
	if e := os.MkdirAll(data, 0o700); e != nil {
		return e
	}
	raw, _ := json.MarshalIndent(s, "", "  ")
	tmp := settingsPath(data) + ".tmp"
	if e := os.WriteFile(tmp, raw, 0o600); e != nil {
		return e
	}
	return os.Rename(tmp, settingsPath(data))
}

// defaultDataDir is where an installation keeps its database, settings, logs and backups.
func defaultDataDir() string {
	if v := os.Getenv("SERK_DATA_DIR"); v != "" {
		return v
	}
	switch runtime.GOOS {
	case "windows":
		if pd := os.Getenv("ProgramData"); pd != "" {
			return filepath.Join(pd, "SerkFinance")
		}
		return `C:\ProgramData\SerkFinance`
	case "linux":
		if info, e := os.Stat("/var/lib/serk-finance"); e == nil && info.IsDir() {
			return "/var/lib/serk-finance"
		}
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".serk-finance")
}

// installDir is the folder holding serk-server, web/ and pgsql/.
func installDir() string {
	exe, e := os.Executable()
	if e != nil {
		return "."
	}
	if resolved, e := filepath.EvalSymlinks(exe); e == nil {
		exe = resolved
	}
	return filepath.Dir(exe)
}
