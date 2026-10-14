package main

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Online backup with PostgreSQL's low-level API: pg_backup_start, copy the data directory,
// pg_backup_stop, then the write-ahead log. The archive restores to a consistent database at
// or after the end of the backup. It also holds serk.json (secrets), so keep backups as safe
// as the server itself.

// Files and directories PostgreSQL documents as safe to omit from a base backup.
var skipDirs = map[string]bool{"pg_dynshmem": true, "pg_notify": true, "pg_serial": true, "pg_snapshots": true, "pg_stat_tmp": true, "pg_subtrans": true, "pg_replslot": true}
var skipFiles = map[string]bool{"postmaster.pid": true, "postmaster.opts": true, "backup_label": true, "tablespace_map": true, "pg_internal.init": true}

func backup(ctx context.Context, p *postgres, data, out string) (string, error) {
	if !p.running() {
		return "", errors.New("the server is not running; start Serk Finance first")
	}
	if out == "" {
		out = filepath.Join(data, "backups", "serk-backup-"+time.Now().Format("20060102-150405")+".zip")
	}
	if e := os.MkdirAll(filepath.Dir(out), 0o700); e != nil {
		return "", e
	}
	_ = os.Remove(out + ".partial") // left over from an interrupted backup
	f, e := os.OpenFile(out+".partial", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if e != nil {
		return "", e
	}
	ok := false
	defer func() {
		f.Close()
		if !ok {
			os.Remove(out + ".partial")
		}
	}()
	z := zip.NewWriter(f)
	c, e := pgx.Connect(ctx, p.url("postgres"))
	if e != nil {
		return "", e
	}
	defer c.Close(context.Background())
	// A temporary replication slot keeps every write-ahead log segment from here on until this
	// connection closes, so none can be recycled while a long backup is copied.
	if _, e = c.Exec(ctx, `SELECT pg_create_physical_replication_slot('serk_backup_'||pg_backend_pid(), true, true)`); e != nil {
		return "", fmt.Errorf("backup slot: %w", e)
	}
	if _, e = c.Exec(ctx, `SELECT pg_backup_start('serk-finance', true)`); e != nil {
		return "", fmt.Errorf("backup start: %w", e)
	}
	stopped := false
	defer func() {
		if !stopped {
			_, _ = c.Exec(context.Background(), `SELECT pg_backup_stop(false)`)
		}
	}()
	// walk adds the files under root (a directory inside the data directory) to the archive.
	// The first pass skips pg_wal, which is copied after the backup stops.
	walk := func(root string, skipWAL bool) error {
		return filepath.WalkDir(root, func(name string, d fs.DirEntry, err error) error {
			if ce := ctx.Err(); ce != nil {
				return ce
			}
			if err != nil {
				if errors.Is(err, fs.ErrNotExist) {
					return nil // files come and go while the server runs
				}
				return err
			}
			rel, _ := filepath.Rel(p.data, name)
			rel = filepath.ToSlash(rel)
			top := strings.SplitN(rel, "/", 2)[0]
			if d.IsDir() {
				if rel == "." {
					return nil
				}
				if (skipDirs[top] && rel != top) || (skipWAL && top == "pg_wal" && rel != top) {
					return fs.SkipDir
				}
				_, err = z.Create("pgdata/" + rel + "/")
				return err
			}
			if skipFiles[d.Name()] || skipDirs[top] || (skipWAL && top == "pg_wal") || strings.HasPrefix(d.Name(), "pgsql_tmp") {
				return nil
			}
			return addFile(z, name, "pgdata/"+rel)
		})
	}
	if e = walk(p.data, true); e != nil {
		return "", e
	}
	var label, spcmap string
	if e = c.QueryRow(ctx, `SELECT labelfile, coalesce(spcmapfile,'') FROM pg_backup_stop(false)`).Scan(&label, &spcmap); e != nil {
		return "", fmt.Errorf("backup stop: %w", e)
	}
	stopped = true
	// Write-ahead log after the backup ends, so recovery can reach a consistent state.
	if _, e = c.Exec(ctx, `SELECT pg_switch_wal()`); e != nil {
		return "", e
	}
	copied := map[string]bool{}
	if e = filepath.WalkDir(filepath.Join(p.data, "pg_wal"), func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(p.data, name)
		copied[d.Name()] = true
		return addFile(z, name, "pgdata/"+filepath.ToSlash(rel))
	}); e != nil {
		return "", e
	}
	// Recovery starts at the segment named in the backup label; it must be in the archive.
	if m := startSegment.FindStringSubmatch(label); m == nil || !copied[m[1]] {
		return "", errors.New("backup incomplete: the starting write-ahead log segment was not found; try again")
	}
	for name, body := range map[string]string{"pgdata/backup_label": label, "pgdata/tablespace_map": spcmap} {
		if body == "" {
			continue
		}
		w, err := z.Create(name)
		if err != nil {
			return "", err
		}
		if _, err = io.WriteString(w, body); err != nil {
			return "", err
		}
	}
	if e = addFile(z, settingsPath(data), "serk.json"); e != nil {
		return "", e
	}
	w, e := z.Create("SERK-BACKUP.txt")
	if e != nil {
		return "", e
	}
	fmt.Fprintf(w, "Serk Finance backup\ncreated %s\nformat 1\nRestore with: serk-server restore --from <this file>\n", time.Now().Format(time.RFC3339))
	if e = z.Close(); e != nil {
		return "", e
	}
	if e = f.Sync(); e != nil {
		return "", e
	}
	f.Close()
	if e = os.Rename(out+".partial", out); e != nil {
		return "", e
	}
	ok = true
	return out, nil
}

var startSegment = regexp.MustCompile(`START WAL LOCATION: [0-9A-F/]+ \(file ([0-9A-F]{24})\)`)

func addFile(z *zip.Writer, src, name string) error {
	in, e := os.Open(src)
	if errors.Is(e, fs.ErrNotExist) {
		return nil
	}
	if e != nil {
		return e
	}
	defer in.Close()
	info, e := in.Stat()
	if e != nil {
		return e
	}
	h, e := zip.FileInfoHeader(info)
	if e != nil {
		return e
	}
	h.Name, h.Method = name, zip.Deflate
	w, e := z.CreateHeader(h)
	if e != nil {
		return e
	}
	_, e = io.Copy(w, in)
	return e
}

// restore replaces the database with a backup. The server must be stopped. The current data
// directory is kept beside the restored one, so a mistaken restore can be undone.
func restore(p *postgres, data, from string, withSettings bool) (string, error) {
	if p.running() {
		return "", errors.New("stop Serk Finance before restoring")
	}
	z, e := zip.OpenReader(from)
	if e != nil {
		return "", fmt.Errorf("cannot open backup: %w", e)
	}
	defer z.Close()
	marker, label := false, false
	for _, f := range z.File {
		switch f.Name {
		case "SERK-BACKUP.txt":
			marker = true
		case "pgdata/backup_label":
			label = true
		}
	}
	if !marker {
		return "", errors.New("this file is not a Serk Finance backup")
	}
	if !label {
		return "", errors.New("this backup is incomplete (no backup_label)")
	}
	staging := p.data + ".restoring"
	if e = os.RemoveAll(staging); e != nil {
		return "", fmt.Errorf("cannot clear %s: %w", staging, e)
	}
	for _, f := range z.File {
		if !strings.HasPrefix(f.Name, "pgdata/") && !(withSettings && f.Name == "serk.json") {
			continue
		}
		clean := path.Clean(f.Name)
		if strings.Contains(clean, "..") || path.IsAbs(clean) {
			return "", errors.New("backup contains an unsafe path")
		}
		// Server configuration is never taken from an archive: it is written fresh below, so a
		// tampered backup cannot change how the database runs or who may connect.
		if serverConfig[strings.TrimPrefix(clean, "pgdata/")] {
			continue
		}
		target := filepath.Join(staging, filepath.FromSlash(strings.TrimPrefix(clean, "pgdata")))
		if f.Name == "serk.json" {
			target = settingsPath(data) + ".restored"
		}
		if f.FileInfo().IsDir() {
			if e = os.MkdirAll(target, 0o700); e != nil {
				return "", e
			}
			continue
		}
		if e = extract(f, target); e != nil {
			return "", e
		}
	}
	for _, d := range []string{"pg_wal", "pg_wal/archive_status", "pg_dynshmem", "pg_notify", "pg_serial", "pg_snapshots", "pg_stat_tmp", "pg_subtrans", "pg_replslot", "pg_tblspc", "pg_logical/snapshots", "pg_logical/mappings"} {
		if e = os.MkdirAll(filepath.Join(staging, filepath.FromSlash(d)), 0o700); e != nil {
			return "", e
		}
	}
	if e = writeServerConfig(staging, p); e != nil {
		return "", e
	}
	kept := ""
	if _, e = os.Stat(p.data); e == nil {
		kept = p.data + ".before-restore-" + time.Now().Format("20060102-150405")
		if e = os.Rename(p.data, kept); e != nil {
			return "", e
		}
	}
	if e = os.Rename(staging, p.data); e != nil {
		if kept != "" {
			if back := os.Rename(kept, p.data); back != nil {
				return "", fmt.Errorf("restore failed (%v) and the previous database could not be put back; rename %s to %s by hand", e, kept, p.data)
			}
		}
		return "", fmt.Errorf("restore failed; the previous database is unchanged: %w", e)
	}
	if withSettings {
		if e = os.Rename(settingsPath(data)+".restored", settingsPath(data)); e != nil {
			return kept, fmt.Errorf("the database was restored but serk.json was not: %w", e)
		}
	}
	return kept, nil
}

// tablespace_map is also never restored: Serk Finance uses no tablespaces, and the map would
// let an archive point the database at other folders.
var serverConfig = map[string]bool{"postgresql.conf": true, "postgresql.auto.conf": true, "pg_hba.conf": true, "pg_ident.conf": true, "tablespace_map": true}

// writeServerConfig gives a restored data folder this installation's own configuration: the
// files of the current database when there is one, otherwise Serk Finance's standard settings.
func writeServerConfig(dir string, p *postgres) error {
	standard := map[string]string{"postgresql.conf": p.config(), "postgresql.auto.conf": "# Do not edit this file manually.\n", "pg_hba.conf": hbaConfig, "pg_ident.conf": ""}
	for name, body := range standard {
		if current, e := os.ReadFile(filepath.Join(p.data, name)); e == nil {
			body = string(current)
		}
		if e := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); e != nil {
			return e
		}
	}
	return nil
}

func extract(f *zip.File, target string) error {
	if e := os.MkdirAll(filepath.Dir(target), 0o700); e != nil {
		return e
	}
	in, e := f.Open()
	if e != nil {
		return e
	}
	defer in.Close()
	out, e := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if e != nil {
		return e
	}
	// The zip reader checks each file's size and checksum against its header as it reads.
	n, e := io.Copy(out, in)
	if e == nil && uint64(n) != f.UncompressedSize64 {
		e = fmt.Errorf("%s: size mismatch", f.Name)
	}
	if e == nil {
		e = out.Sync()
	}
	if ce := out.Close(); e == nil {
		e = ce
	}
	return e
}
