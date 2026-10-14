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
	defer c.Close(ctx)
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
		return addFile(z, name, "pgdata/"+filepath.ToSlash(rel))
	}); e != nil {
		return "", e
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
	marker := false
	for _, f := range z.File {
		if f.Name == "SERK-BACKUP.txt" {
			marker = true
		}
	}
	if !marker {
		return "", errors.New("this file is not a Serk Finance backup")
	}
	staging := p.data + ".restoring"
	_ = os.RemoveAll(staging)
	for _, f := range z.File {
		if !strings.HasPrefix(f.Name, "pgdata/") && !(withSettings && f.Name == "serk.json") {
			continue
		}
		clean := path.Clean(f.Name)
		if strings.Contains(clean, "..") || path.IsAbs(clean) {
			return "", errors.New("backup contains an unsafe path")
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
	kept := ""
	if _, e = os.Stat(p.data); e == nil {
		kept = p.data + ".before-restore-" + time.Now().Format("20060102-150405")
		if e = os.Rename(p.data, kept); e != nil {
			return "", e
		}
	}
	if e = os.Rename(staging, p.data); e != nil {
		return "", e
	}
	if withSettings {
		if e = os.Rename(settingsPath(data)+".restored", settingsPath(data)); e != nil {
			return "", e
		}
	}
	return kept, nil
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
	if _, e = io.Copy(out, io.LimitReader(in, 8<<30)); e != nil {
		out.Close()
		return e
	}
	return out.Close()
}
