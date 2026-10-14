// serk-server runs Serk Finance on an office computer: its own PostgreSQL database, the
// application and the web interface, with a first-run setup wizard, online backups and
// password recovery. It is what the Windows and Linux installers install.
//
//	serk-server [run]                       start (default); opens the browser on first run
//	serk-server backup [--out FILE]          online backup to a .zip (server running)
//	serk-server restore --from FILE          restore a backup (server stopped)
//	serk-server reset-password --workspace W --email E   set a new password (asks for it)
//	serk-server stop-database                stop the bundled database after a crash
//	serk-server version
//
// Options: --data DIR (default: %ProgramData%\SerkFinance, /var/lib/serk-finance or
// ~/.serk-finance), --no-browser.
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"serk.finance/internal/demo"
	"serk.finance/internal/platform/bootstrap"
	"serk.finance/internal/platform/database"
	"serk.finance/internal/platform/httpapi"
	"serk.finance/internal/provisioning"
)

func usage() {
	fmt.Fprintln(os.Stderr, `Serk Finance office server `+database.ReleaseVersion+`

Usage:
  serk-server [run]                                   start Serk Finance
  serk-server backup [--out FILE]                      back up the database (while running)
  serk-server restore --from FILE [--with-settings]    restore a backup (stop Serk Finance first)
  serk-server reset-password --workspace W --email E  set a user's password
  serk-server stop-database                            stop the bundled database
  serk-server version

Options:
  --data DIR      data folder (default `+defaultDataDir()+`)
  --no-browser    do not open the browser on first run
  --local-only    serve this computer only (not other computers on the network)`)
}

func main() {
	cmd := "run"
	args := os.Args[1:]
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	fs.Usage = usage
	data := fs.String("data", defaultDataDir(), "data folder")
	noBrowser := fs.Bool("no-browser", false, "do not open the browser")
	localOnly := fs.Bool("local-only", false, "serve this computer only, not the office network")
	out := fs.String("out", "", "backup file")
	from := fs.String("from", "", "backup file to restore")
	withSettings := fs.Bool("with-settings", false, "also restore serk.json from the backup")
	workspace := fs.String("workspace", "", "workspace")
	email := fs.String("email", "", "user email")
	_ = fs.Parse(args)
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))
	var e error
	switch cmd {
	case "run":
		e = runServer(*data, !*noBrowser, *localOnly, nil)
	case "service":
		e = runService(*data, *localOnly)
	case "backup":
		e = withSettingsDo(*data, func(s *Settings, p *postgres) error {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
			defer cancel()
			file, err := backup(ctx, p, *data, *out)
			if err == nil {
				fmt.Println("Backup written to", file)
			}
			return err
		})
	case "restore":
		if *from == "" {
			e = errors.New("--from is required")
			break
		}
		e = withSettingsDo(*data, func(s *Settings, p *postgres) error {
			kept, err := restore(p, *data, *from, *withSettings)
			if err == nil {
				fmt.Println("Restored. Start Serk Finance to complete recovery.")
				if kept != "" {
					fmt.Println("The previous database is kept in", kept)
				}
			}
			return err
		})
	case "reset-password":
		e = resetPassword(*data, *workspace, *email)
	case "stop-database":
		e = withSettingsDo(*data, func(s *Settings, p *postgres) error { return p.stop() })
	case "version":
		fmt.Println("Serk Finance", database.ReleaseVersion, runtime.GOOS+"/"+runtime.GOARCH)
	case "help", "-h", "--help":
		usage()
	default:
		usage()
		os.Exit(2)
	}
	if e != nil {
		fmt.Fprintln(os.Stderr, "Error:", database.RedactedError(e))
		os.Exit(1)
	}
}

func withSettingsDo(data string, fn func(*Settings, *postgres) error) error {
	s, created, e := loadSettings(data)
	if e != nil {
		return e
	}
	if created {
		_ = os.Remove(settingsPath(data))
		return errors.New("Serk Finance has not been started in " + data + " yet")
	}
	return fn(s, newPostgres(data, s))
}

// origins lists the addresses browsers may use: this computer's names and, when serving the
// network, its local network addresses.
func origins(s *Settings) []string {
	port := strconv.Itoa(s.Port)
	set := map[string]bool{"http://localhost:" + port: true, "http://127.0.0.1:" + port: true}
	if s.ListenAll {
		if host, e := os.Hostname(); e == nil && host != "" && !strings.ContainsAny(host, " /") {
			set["http://"+strings.ToLower(host)+":"+port] = true
		}
		if addrs, e := net.InterfaceAddrs(); e == nil {
			for _, a := range addrs {
				if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil && !ipn.IP.IsLoopback() && !ipn.IP.IsLinkLocalUnicast() {
					set["http://"+ipn.IP.String()+":"+port] = true
				}
			}
		}
	}
	for _, o := range s.ExtraOrigins {
		set[o] = true
	}
	list := []string{"http://localhost:" + port}
	rest := []string{}
	for o := range set {
		if o != list[0] {
			rest = append(rest, o)
		}
	}
	sort.Strings(rest)
	return append(list, rest...)
}

// runServer starts the database and the application and blocks until stopped.
func runServer(data string, openBrowser, localOnly bool, stop <-chan struct{}) error {
	if runtime.GOOS != "windows" && os.Geteuid() == 0 {
		return errors.New("do not run Serk Finance as root; use the serk-finance service account")
	}
	if e := os.MkdirAll(data, 0o700); e != nil {
		return fmt.Errorf("cannot create data folder %s: %w", data, e)
	}
	s, created, e := loadSettings(data)
	if e != nil {
		return e
	}
	if localOnly {
		s.ListenAll = false
	}
	p := newPostgres(data, s)
	if e = p.ensure(); e != nil {
		return fmt.Errorf("database setup: %w", e)
	}
	if e = p.start(); e != nil {
		return fmt.Errorf("database start: %w", e)
	}
	defer func() {
		if err := p.stop(); err != nil {
			slog.Error("database_stop_failed", "error", err.Error())
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	if e = p.ensureDatabase(ctx); e != nil {
		return fmt.Errorf("database create: %s", database.RedactedError(e))
	}
	operator := p.url("serk")
	logins := bootstrap.Logins{API: s.APIPassword, Auth: s.AuthPassword}
	os.Setenv("SERK_ENV", "office")
	os.Setenv("MIGRATOR_DATABASE_URL", operator)
	db, e := database.Operator(ctx)
	if e != nil {
		return fmt.Errorf("operator connection: %w", e)
	}
	if e = bootstrap.Prepare(ctx, db, logins, os.Stdout); e != nil {
		db.Close(ctx)
		return e
	}
	if s.Practice {
		if e = demo.Upgrade(ctx, db); e != nil {
			slog.Warn("practice_workspace_upgrade_failed", "error", e.Error())
		}
	}
	db.Close(ctx)
	os.Unsetenv("MIGRATOR_DATABASE_URL")
	list := origins(s)
	st, e := newSetup(ctx, operator, data, s, list)
	if e != nil {
		return e
	}
	apiURL, authURL, e := bootstrap.RuntimeURLs(operator, logins)
	if e != nil {
		return e
	}
	listen := "127.0.0.1"
	if s.ListenAll {
		listen = "0.0.0.0"
	}
	for k, v := range map[string]string{"DATABASE_URL": apiURL, "AUTH_DATABASE_URL": authURL, "SERK_ORIGIN": strings.Join(list, ","),
		"SERK_LISTEN": listen + ":" + strconv.Itoa(s.Port), "SERK_WEB_DIR": filepath.Join(installDir(), "web"), "SERK_MFA_KEY": s.MFAKey} {
		os.Setenv(k, v)
	}
	address := "http://localhost:" + strconv.Itoa(s.Port)
	fmt.Println("Serk Finance is starting at", address)
	if s.ListenAll && len(list) > 2 {
		fmt.Println("Other computers on the network can use:", strings.Join(list[2:], "  "))
	}
	if st.isNeeded() {
		fmt.Println("First-time setup:", address+"/setup")
		if openBrowser {
			go func() { time.Sleep(1500 * time.Millisecond); browse(address + "/setup") }()
		}
	} else if openBrowser && created {
		go func() { time.Sleep(1500 * time.Millisecond); browse(address) }()
	}
	if e = httpapi.RunWith(httpapi.RunOptions{Wrap: st.wrap, Stop: stop}); e != nil {
		var detail *httpapi.StartupError
		if errors.As(e, &detail) {
			return fmt.Errorf("startup failed at %s: %s", detail.Stage, detail.Code)
		}
		return e
	}
	return nil
}

func browse(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	_ = cmd.Start()
}

func resetPassword(data, workspace, email string) error {
	if workspace == "" || email == "" {
		return errors.New("--workspace and --email are required")
	}
	pw, e := askPassword("New password (at least 14 characters): ")
	if e != nil {
		return e
	}
	again, e := askPassword("Repeat the new password: ")
	if e != nil {
		return e
	}
	if pw != again {
		return errors.New("the passwords do not match")
	}
	return withSettingsDo(data, func(s *Settings, p *postgres) error {
		if !p.running() {
			return errors.New("start Serk Finance first")
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		os.Setenv("SERK_ENV", "office")
		os.Setenv("MIGRATOR_DATABASE_URL", p.url("serk"))
		db, err := database.Operator(ctx)
		if err != nil {
			return err
		}
		defer db.Close(ctx)
		if err = provisioning.Administer(ctx, db, provisioning.AdminRequest{Tenant: workspace, Email: strings.ToLower(email), Action: "reset_password",
			Password: pw, Reason: "Password reset on the server computer"}); err != nil {
			return err
		}
		fmt.Println("Password changed. The user's sessions were signed out.")
		return nil
	})
}

var stdin = bufio.NewReader(os.Stdin)

// askPassword reads a line without echo when the input is a terminal.
func askPassword(prompt string) (string, error) {
	fmt.Print(prompt)
	restore := hideInput()
	line, e := stdin.ReadString('\n')
	if restore != nil {
		restore()
		fmt.Println()
	}
	return strings.TrimRight(line, "\r\n"), e
}
