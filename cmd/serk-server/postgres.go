package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The bundled PostgreSQL server runs on this computer only (127.0.0.1) under the account that
// runs Serk Finance, with its data in <data>/pgdata.
const operatorUser = "serk_operator"

type postgres struct {
	bin, data, logs string
	port            int
	password        string
}

func newPostgres(dataDir string, s *Settings) *postgres {
	bin := os.Getenv("SERK_PG_BIN")
	if bin == "" {
		bin = filepath.Join(installDir(), "pgsql", "bin")
	}
	return &postgres{bin: bin, data: filepath.Join(dataDir, "pgdata"), logs: filepath.Join(dataDir, "logs"), port: s.DBPort, password: s.OperatorPassword}
}

func (p *postgres) tool(name string) string {
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(p.bin, name)
}

func (p *postgres) run(name string, args ...string) error {
	cmd := exec.Command(p.tool(name), args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C", "LANG=C")
	out, e := cmd.CombinedOutput()
	if e != nil {
		text := strings.TrimSpace(string(out))
		if len(text) > 2000 {
			text = text[len(text)-2000:]
		}
		return fmt.Errorf("%s failed: %v\n%s", name, e, text)
	}
	return nil
}

func (p *postgres) initialised() bool {
	_, e := os.Stat(filepath.Join(p.data, "PG_VERSION"))
	return e == nil
}

// ensure creates the database cluster on first start.
func (p *postgres) ensure() error {
	if p.initialised() {
		return nil
	}
	if _, e := os.Stat(p.tool("initdb")); e != nil {
		return fmt.Errorf("bundled PostgreSQL not found in %s", p.bin)
	}
	if e := os.MkdirAll(p.logs, 0o700); e != nil {
		return e
	}
	pw := filepath.Join(filepath.Dir(p.data), ".initpw")
	if e := os.WriteFile(pw, []byte(p.password+"\n"), 0o600); e != nil {
		return e
	}
	defer os.Remove(pw)
	if e := p.run("initdb", "-D", p.data, "-U", operatorUser, "--pwfile="+pw, "-A", "scram-sha-256", "-E", "UTF8", "--no-locale", "--no-instructions"); e != nil {
		_ = os.RemoveAll(p.data)
		return e
	}
	conf := fmt.Sprintf(`
# Serk Finance office installation
listen_addresses = '127.0.0.1'
port = %d
max_connections = 60
shared_buffers = 128MB
password_encryption = 'scram-sha-256'
unix_socket_directories = ''
logging_collector = off
wal_level = replica
max_wal_size = 512MB
`, p.port)
	f, e := os.OpenFile(filepath.Join(p.data, "postgresql.conf"), os.O_APPEND|os.O_WRONLY, 0o600)
	if e != nil {
		return e
	}
	defer f.Close()
	_, e = f.WriteString(conf)
	return e
}

func (p *postgres) running() bool {
	c, e := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(p.port), 500*time.Millisecond)
	if e != nil {
		return false
	}
	c.Close()
	return true
}

func (p *postgres) start() error {
	if p.running() {
		return nil
	}
	if e := os.MkdirAll(p.logs, 0o700); e != nil {
		return e
	}
	// A stale lock file from a power cut would stop the server; pg_ctl removes it when safe.
	if e := p.run("pg_ctl", "start", "-w", "-t", "120", "-D", p.data, "-l", filepath.Join(p.logs, "postgres.log"), "-o", "-p "+strconv.Itoa(p.port)); e != nil {
		return e
	}
	for i := 0; i < 60 && !p.running(); i++ {
		time.Sleep(500 * time.Millisecond)
	}
	if !p.running() {
		return errors.New("PostgreSQL did not start; see " + filepath.Join(p.logs, "postgres.log"))
	}
	return nil
}

func (p *postgres) stop() error {
	if !p.initialised() {
		return nil
	}
	return p.run("pg_ctl", "stop", "-w", "-t", "60", "-m", "fast", "-D", p.data)
}

// url is the owner connection to the application database.
func (p *postgres) url(db string) string {
	u := url.URL{Scheme: "postgres", User: url.UserPassword(operatorUser, p.password), Host: "127.0.0.1:" + strconv.Itoa(p.port), Path: "/" + db, RawQuery: "sslmode=disable"}
	return u.String()
}

// ensureDatabase creates the application database on first start.
func (p *postgres) ensureDatabase(ctx context.Context) error {
	c, e := pgx.Connect(ctx, p.url("postgres"))
	if e != nil {
		return e
	}
	defer c.Close(ctx)
	var exists bool
	if e = c.QueryRow(ctx, `SELECT EXISTS(SELECT FROM pg_database WHERE datname='serk')`).Scan(&exists); e != nil || exists {
		return e
	}
	_, e = c.Exec(ctx, `CREATE DATABASE serk ENCODING 'UTF8' TEMPLATE template0`)
	return e
}
