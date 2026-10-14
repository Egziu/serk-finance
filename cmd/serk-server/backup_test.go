package main

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeZip(t *testing.T, name string, files map[string]string) {
	t.Helper()
	f, e := os.Create(name)
	if e != nil {
		t.Fatal(e)
	}
	z := zip.NewWriter(f)
	for n, body := range files {
		w, _ := z.Create(n)
		_, _ = w.Write([]byte(body))
	}
	if e = z.Close(); e != nil {
		t.Fatal(e)
	}
	f.Close()
}

// A backup cannot bring its own server configuration: the installation's files are kept.
func TestRestoreKeepsTheInstallationsServerConfiguration(t *testing.T) {
	data := t.TempDir()
	p := newPostgres(data, &Settings{DBPort: 1})
	if e := os.MkdirAll(p.data, 0o700); e != nil {
		t.Fatal(e)
	}
	_ = os.WriteFile(filepath.Join(p.data, "pg_hba.conf"), []byte("host all all 127.0.0.1/32 scram-sha-256\n"), 0o600)
	_ = os.WriteFile(filepath.Join(p.data, "PG_VERSION"), []byte("17\n"), 0o600)
	archive := filepath.Join(data, "evil.zip")
	writeZip(t, archive, map[string]string{
		"SERK-BACKUP.txt": "Serk Finance backup", "pgdata/backup_label": "START WAL LOCATION: 0/2000028 (file 000000010000000000000002)\n",
		"pgdata/PG_VERSION": "17\n", "pgdata/pg_hba.conf": "host all all 0.0.0.0/0 trust\n",
		"pgdata/postgresql.auto.conf": "archive_command = 'touch /tmp/pwned'\n", "pgdata/base/1/1": "data",
	})
	kept, e := restore(p, data, archive, false)
	if e != nil {
		t.Fatal(e)
	}
	hba, _ := os.ReadFile(filepath.Join(p.data, "pg_hba.conf"))
	auto, _ := os.ReadFile(filepath.Join(p.data, "postgresql.auto.conf"))
	if strings.Contains(string(hba), "trust") || strings.Contains(string(auto), "archive_command") {
		t.Fatalf("archive configuration was used: %s / %s", hba, auto)
	}
	if body, _ := os.ReadFile(filepath.Join(p.data, "base", "1", "1")); string(body) != "data" || kept == "" {
		t.Fatal("data not restored or previous database not kept")
	}
	// With the database folder gone and a kept copy beside it, no new empty database is created.
	if e = os.RemoveAll(p.data); e != nil {
		t.Fatal(e)
	}
	if e = p.ensure(); e == nil || !strings.Contains(e.Error(), "before-restore") {
		t.Fatal("ensure would create an empty database:", e)
	}
}

func TestRestoreRefusesIncompleteArchives(t *testing.T) {
	data := t.TempDir()
	p := newPostgres(data, &Settings{DBPort: 1})
	archive := filepath.Join(data, "partial.zip")
	writeZip(t, archive, map[string]string{"SERK-BACKUP.txt": "x", "pgdata/PG_VERSION": "17\n"})
	if _, e := restore(p, data, archive, false); e == nil || !strings.Contains(e.Error(), "backup_label") {
		t.Fatal(e)
	}
	writeZip(t, archive, map[string]string{"SERK-BACKUP.txt": "x", "pgdata/backup_label": "x", "pgdata/../../escape": "x"})
	if _, e := restore(p, data, archive, false); e == nil || !strings.Contains(e.Error(), "unsafe") {
		t.Fatal(e)
	}
}

func TestStartSegmentIsReadFromTheLabel(t *testing.T) {
	m := startSegment.FindStringSubmatch("START WAL LOCATION: 0/9000028 (file 000000010000000000000009)\nCHECKPOINT LOCATION: 0/9000060\n")
	if m == nil || m[1] != "000000010000000000000009" {
		t.Fatal(m)
	}
}
