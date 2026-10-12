package httpapi

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"os"
	"path"
	"strings"
)

// csp is the page policy. A per-response nonce admits only the <style> elements the web app
// creates at runtime (its component library injects styles); scripts stay 'self' only.
func csp(nonce string) string {
	style := "style-src 'self'"
	if nonce != "" {
		style += " 'nonce-" + nonce + "'"
	}
	return "default-src 'self'; script-src 'self'; " + style + "; img-src 'self' data:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
}

// serveIndex returns the app shell with a fresh style nonce in both the header and a meta tag.
func (s *Server) serveIndex(w http.ResponseWriter, r *http.Request) bool {
	if r.URL.Path != "/" && r.URL.Path != "/index.html" {
		return false
	}
	page, e := os.ReadFile(path.Join(s.Config.StaticDir, "index.html"))
	if e != nil {
		return false
	}
	raw := make([]byte, 18)
	if _, e = rand.Read(raw); e != nil {
		return false
	}
	nonce := base64.RawURLEncoding.EncodeToString(raw)
	page = bytes.Replace(page, []byte("<head>"), []byte(`<head><meta name="csp-nonce" content="`+nonce+`"/>`), 1)
	w.Header().Set("Content-Security-Policy", csp(nonce))
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodHead {
		_, _ = w.Write(page)
	}
	return true
}

// Directories without an index are never enumerated; hidden files are private.
type noListingFS struct{ http.FileSystem }

func (fs noListingFS) Open(name string) (http.File, error) {
	for _, segment := range strings.Split(name, "/") {
		if strings.HasPrefix(segment, ".") && segment != "." {
			return nil, os.ErrNotExist
		}
	}
	f, e := fs.FileSystem.Open(name)
	if e != nil {
		return nil, e
	}
	info, e := f.Stat()
	if e != nil {
		f.Close()
		return nil, e
	}
	if info.IsDir() {
		index, err := fs.FileSystem.Open(path.Join(name, "index.html"))
		if err != nil {
			f.Close()
			return nil, os.ErrNotExist
		}
		stat, err := index.Stat()
		index.Close()
		if err != nil || stat.IsDir() {
			f.Close()
			return nil, os.ErrNotExist
		}
	}
	return f, nil
}
