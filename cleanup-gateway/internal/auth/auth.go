// Package auth implements API-key authentication: key issuance, hash verification,
// and the HTTP middleware that rejects requests without a valid Bearer key.
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/sunoflow/cleanup-gateway/internal/store"
)

type ctxKey int

const keyIDCtxKey ctxKey = 1

// FromContext returns the authenticated key ID from the request context, or "".
func FromContext(ctx context.Context) string {
	if v, ok := ctx.Value(keyIDCtxKey).(string); ok {
		return v
	}
	return ""
}

// HashKey returns the SHA-256 hex digest of an API key plaintext.
func HashKey(plaintext string) string {
	sum := sha256.Sum256([]byte(plaintext))
	return string(sum[:])
}

// ErrInvalidAuth is returned when the Authorization header is missing or malformed.
var ErrInvalidAuth = errors.New("invalid authorization header")

// ExtractBearer pulls the raw key out of "Authorization: Bearer <key>".
func ExtractBearer(h http.Header) (string, error) {
	v := h.Get("Authorization")
	if v == "" {
		return "", ErrInvalidAuth
	}
	parts := strings.SplitN(v, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || parts[1] == "" {
		return "", ErrInvalidAuth
	}
	return strings.TrimSpace(parts[1]), nil
}

// IssueKey generates a new opaque API key (32 random bytes, base64url) plus its
// UUID id and SHA-256 hash. The plaintext is returned once; only the hash is stored.
func IssueKey() (id, plaintext, hash string, err error) {
	buf := make([]byte, 32)
	if _, err = rand.Read(buf); err != nil {
		return "", "", "", err
	}
	plaintext = base64.RawURLEncoding.EncodeToString(buf)
	id = uuid.NewString()
	hash = HashKey(plaintext)
	return id, plaintext, hash, nil
}

// Middleware verifies the Bearer key against the store and attaches the key id
// to the request context. Unauthenticated requests get 401.
func Middleware(s *store.Store) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			plaintext, err := ExtractBearer(r.Header)
			if err != nil {
				writeUnauthorized(w)
				return
			}
			k, err := s.LookupByHash(r.Context(), HashKey(plaintext))
			if err != nil {
				if errors.Is(err, store.ErrNotFound) {
					writeUnauthorized(w)
					return
				}
				writeInternalError(w)
				return
			}
			// Constant-time-ish: hash equality already enforced by the SQL lookup.
			ctx := context.WithValue(r.Context(), keyIDCtxKey, k.ID)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// AdminMiddleware guards /admin/* with a separate admin token (constant-time compare).
func AdminMiddleware(token string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			plaintext, err := ExtractBearer(r.Header)
			if err != nil || !subtleEqual(plaintext, token) {
				writeUnauthorized(w)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// subtleEqual is a constant-time string comparison.
func subtleEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var v byte
	for i := 0; i < len(a); i++ {
		v |= a[i] ^ b[i]
	}
	return v == 0
}

func writeUnauthorized(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
}

func writeInternalError(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusInternalServerError)
	_, _ = w.Write([]byte(`{"error":"internal"}`))
}

// now is overridable for tests.
var now = func() time.Time { return time.Now() }