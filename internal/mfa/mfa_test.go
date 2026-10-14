package mfa

import (
	"bytes"
	"encoding/base32"
	"encoding/base64"
	"testing"
	"time"
)

func TestRFC6238AndWindow(t *testing.T) {
	secret := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString([]byte("12345678901234567890"))
	// RFC 6238 Appendix B SHA-1 vectors, truncated to the configured six digits.
	for _, tc := range []struct {
		timestamp int64
		code      string
	}{{59, "287082"}, {1111111109, "081804"}, {1111111111, "050471"}, {1234567890, "005924"}, {2000000000, "279037"}, {20000000000, "353130"}} {
		step, ok := MatchStep(secret, tc.code, time.Unix(tc.timestamp, 0))
		if !ok || step != tc.timestamp/30 {
			t.Fatal("RFC vector failed", tc)
		}
		if _, ok = MatchStep(secret, tc.code, time.Unix(tc.timestamp+120, 0)); ok {
			t.Fatal("expired code accepted")
		}
	}
}
func TestEncryptedSecretBinding(t *testing.T) {
	key := bytes.Repeat([]byte{7}, 32)
	k, e := Generate("test@example.test")
	if e != nil {
		t.Fatal(e)
	}
	a, e := Encrypt(key, "user-one", k.Secret())
	if e != nil {
		t.Fatal(e)
	}
	b, _ := Encrypt(key, "user-one", k.Secret())
	if a == b {
		t.Fatal("nonce reused")
	}
	if plain, e := Decrypt(key, "user-one", a); e != nil || plain != k.Secret() {
		t.Fatal(e)
	}
	if _, e := Decrypt(key, "user-two", a); e == nil {
		t.Fatal("cross-user ciphertext accepted")
	}
	raw, _ := base64.StdEncoding.DecodeString(a)
	raw[len(raw)-1] ^= 1
	if _, e := Decrypt(key, "user-one", base64.StdEncoding.EncodeToString(raw)); e == nil {
		t.Fatal("tampering accepted")
	}
	if _, e := ParseKey("short"); e == nil {
		t.Fatal("weak key accepted")
	}
	if _, e := ParseKey(base64.StdEncoding.EncodeToString(key)); e != nil {
		t.Fatal(e)
	}
}

func TestSealedSecretBinding(t *testing.T) {
	key := make([]byte, 32)
	sealed, e := Seal(key, "ai:company-a", "sk-ant-test-123")
	if e != nil {
		t.Fatal(e)
	}
	if got, e := Open(key, "ai:company-a", sealed); e != nil || got != "sk-ant-test-123" {
		t.Fatalf("%q %v", got, e)
	}
	if _, e := Open(key, "ai:company-b", sealed); e == nil {
		t.Fatal("a secret sealed for one company must not open for another")
	}
}
