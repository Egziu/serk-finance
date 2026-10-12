package auth

import "testing"

func TestArgon2id(t *testing.T) {
	p := "Acceptable test passphrase!"
	a, e := Hash(p)
	if e != nil {
		t.Fatal(e)
	}
	b, _ := Hash(p)
	if a == b {
		t.Fatal("salt reuse")
	}
	if !Verify(a, p) || Verify(a, "wrong") || Verify("$argon2id$v=19$m=999999999,t=3,p=1$x$x", p) {
		t.Fatal("verification failure")
	}
}
func TestSessionTokens(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		x, e := Token()
		if e != nil || len(x) != 43 || seen[x] || len(Digest(x)) != 64 {
			t.Fatal("invalid token")
		}
		seen[x] = true
	}
}
