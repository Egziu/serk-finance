// Package mfa combines an established TOTP implementation with AES-256-GCM
// secret protection. Single-use counters are enforced transactionally in SQL.
package mfa

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"github.com/pquerna/otp"
	"github.com/pquerna/otp/totp"
	"time"
)

func ParseKey(raw string) ([]byte, error) {
	key, e := base64.StdEncoding.DecodeString(raw)
	if e != nil || len(key) != 32 {
		return nil, errors.New("MFA key must be 32 random bytes encoded as base64")
	}
	return key, nil
}
func Generate(account string) (*otp.Key, error) {
	return totp.Generate(totp.GenerateOpts{Issuer: "SERK Finance", AccountName: account, SecretSize: 20, Period: 30, Digits: otp.DigitsSix, Algorithm: otp.AlgorithmSHA1})
}
func ValidSecret(secret string) bool {
	b, e := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(secret)
	return e == nil && len(b) >= 20 && len(b) <= 64
}
func aead(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, errors.New("MFA key unavailable")
	}
	block, e := aes.NewCipher(key)
	if e != nil {
		return nil, e
	}
	return cipher.NewGCMWithRandomNonce(block)
}
func Encrypt(key []byte, user, secret string) (string, error) {
	if !ValidSecret(secret) {
		return "", errors.New("invalid MFA secret")
	}
	a, e := aead(key)
	if e != nil {
		return "", e
	}
	return base64.StdEncoding.EncodeToString(a.Seal(nil, nil, []byte(secret), []byte("serk-mfa-v1:"+user))), nil
}
func Decrypt(key []byte, user, encrypted string) (string, error) {
	a, e := aead(key)
	if e != nil {
		return "", e
	}
	b, e := base64.StdEncoding.DecodeString(encrypted)
	if e != nil {
		return "", errors.New("invalid encrypted MFA secret")
	}
	plain, e := a.Open(nil, nil, b, []byte("serk-mfa-v1:"+user))
	if e != nil {
		return "", errors.New("MFA secret authentication failed")
	}
	return string(plain), nil
}
// CurrentCode is used only by the development-mode code display (SERK_DEV_SHOW_OTP).
func CurrentCode(secret string, now time.Time) (string, error) {
	return totp.GenerateCodeCustom(secret, now, totp.ValidateOpts{Period: 30, Digits: otp.DigitsSix, Algorithm: otp.AlgorithmSHA1})
}
func MatchStep(secret, code string, now time.Time) (int64, bool) {
	if len(code) != 6 {
		return -1, false
	}
	for _, r := range code {
		if r < '0' || r > '9' {
			return -1, false
		}
	}
	step := now.Unix() / 30
	for _, offset := range []int64{0, -1, 1} {
		candidate := step + offset
		ok, e := totp.ValidateCustom(code, secret, time.Unix(candidate*30, 0), totp.ValidateOpts{Period: 30, Skew: 0, Digits: otp.DigitsSix, Algorithm: otp.AlgorithmSHA1})
		if e == nil && ok {
			return candidate, true
		}
	}
	return -1, false
}
