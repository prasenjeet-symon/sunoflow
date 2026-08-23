package account

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
)

func tp(t time.Time) *time.Time { return &t }

// The entitlement table is the security-critical part, so it is tested on its
// own without any Firestore involved.
func TestEntitled(t *testing.T) {
	now := time.Date(2026, 8, 21, 12, 0, 0, 0, time.UTC)
	past := now.Add(-24 * time.Hour)
	future := now.Add(24 * time.Hour)

	cases := []struct {
		name       string
		plan       string
		trialEnds  *time.Time
		periodEnd  *time.Time
		cancelling bool
		want       bool
		reason     Reason
	}{
		{"trial still running", "trial", tp(future), nil, false, true, ReasonTrial},
		{"trial expired", "trial", tp(past), nil, false, false, ReasonTrialExpired},
		{"trial with no end date", "trial", nil, nil, false, false, ReasonTrialExpired},
		{"missing plan treated as trial", "", tp(future), nil, false, true, ReasonTrial},
		{"active", "active", nil, tp(future), false, true, ReasonActive},
		{"active, cancelling, period not over", "active", nil, tp(future), true, true, ReasonActive},
		{"active, cancelling, period over", "active", nil, tp(past), true, false, ReasonLapsed},
		{"canceled outright", "canceled", tp(future), tp(future), false, false, ReasonCanceled},
		{"unrecognised plan denied", "gift", tp(future), nil, false, false, ReasonNoAccount},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, reason := entitled(c.plan, c.trialEnds, c.periodEnd, c.cancelling, now)
			if got != c.want || reason != c.reason {
				t.Fatalf("got (%v, %s), want (%v, %s)", got, reason, c.want, c.reason)
			}
		})
	}
}

// ---------------------------------------------------------------- integration

func emulatorClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("set FIRESTORE_EMULATOR_HOST to run the Firestore-backed tests")
	}
	c, err := firestore.NewClient(context.Background(), "sunoflow-app")
	if err != nil {
		t.Fatalf("firestore: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

// seed writes one account and one device key, returning the plaintext key.
func seed(t *testing.T, fs *firestore.Client, uid, plan string, trialEnds, periodEnd *time.Time, revoked bool) string {
	t.Helper()
	ctx := context.Background()
	plaintext := "sf_test_" + uid

	key := map[string]any{"uid": uid, "deviceId": "dev-" + uid, "revokedAt": nil}
	if revoked {
		key["revokedAt"] = time.Now()
	}
	if _, err := fs.Collection("apiKeys").Doc(KeyID(plaintext)).Set(ctx, key); err != nil {
		t.Fatalf("seed key: %v", err)
	}
	acct := map[string]any{"uid": uid, "plan": plan, "cancelAtPeriodEnd": false}
	if trialEnds != nil {
		acct["trialEndsAt"] = *trialEnds
	}
	if periodEnd != nil {
		acct["currentPeriodEnd"] = *periodEnd
	}
	if _, err := fs.Collection("users").Doc(uid).Set(ctx, acct); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return plaintext
}

func TestMiddlewareAgainstFirestore(t *testing.T) {
	fs := emulatorClient(t)
	r := newWithClient(fs)
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))

	future := time.Now().Add(48 * time.Hour)
	past := time.Now().Add(-48 * time.Hour)

	okKey := seed(t, fs, "u-trial", "trial", &future, nil, false)
	expiredKey := seed(t, fs, "u-expired", "trial", &past, nil, false)
	activeKey := seed(t, fs, "u-active", "active", nil, &future, false)
	canceledKey := seed(t, fs, "u-canceled", "canceled", nil, nil, false)
	revokedKey := seed(t, fs, "u-revoked", "active", nil, &future, true)

	var reached bool
	handler := Middleware(r, nil, "", log)(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		reached = true
		res, ok := FromContext(req.Context())
		if !ok || res.UID == "" {
			t.Error("handler ran without a resolution in context")
		}
		w.WriteHeader(http.StatusOK)
	}))

	cases := []struct {
		name     string
		key      string
		wantCode int
		wantErr  string
		passes   bool
	}{
		{"trial in date", okKey, http.StatusOK, "", true},
		{"active subscription", activeKey, http.StatusOK, "", true},
		{"expired trial", expiredKey, http.StatusPaymentRequired, string(ReasonTrialExpired), false},
		{"canceled account", canceledKey, http.StatusPaymentRequired, string(ReasonCanceled), false},
		{"revoked device", revokedKey, http.StatusUnauthorized, string(ReasonRevoked), false},
		{"unknown key", "sf_nope", http.StatusUnauthorized, "invalid_key", false},
		{"no key at all", "", http.StatusUnauthorized, "missing_key", false},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			reached = false
			req := httptest.NewRequest(http.MethodPost, "/cleanup", nil)
			if c.key != "" {
				req.Header.Set("Authorization", "Bearer "+c.key)
			}
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)

			if rec.Code != c.wantCode {
				t.Fatalf("status = %d, want %d (body %s)", rec.Code, c.wantCode, rec.Body.String())
			}
			if reached != c.passes {
				t.Fatalf("handler reached = %v, want %v", reached, c.passes)
			}
			if c.wantErr != "" {
				var body map[string]string
				if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
					t.Fatalf("body not JSON: %v", err)
				}
				if body["error"] != c.wantErr {
					t.Fatalf("error = %q, want %q", body["error"], c.wantErr)
				}
				if body["message"] == "" {
					t.Error("refusal carried no message for the user")
				}
			}
		})
	}
}

// A revoked key must stop working, and must not be kept alive by the cache.
func TestRevocationTakesEffect(t *testing.T) {
	fs := emulatorClient(t)
	r := newWithClient(fs)
	ctx := context.Background()

	future := time.Now().Add(48 * time.Hour)
	key := seed(t, fs, "u-revoke-flow", "active", nil, &future, false)

	res, err := r.Resolve(ctx, key)
	if err != nil || !res.Entitled {
		t.Fatalf("expected entitled before revoke, got %+v err=%v", res, err)
	}

	if _, err := fs.Collection("apiKeys").Doc(KeyID(key)).
		Set(ctx, map[string]any{"revokedAt": time.Now()}, firestore.MergeAll); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	// Still cached, so still allowed — this is the window we accept by design.
	if res, _ := r.Resolve(ctx, key); !res.Entitled {
		t.Error("expected the cached decision to survive until the TTL expires")
	}

	r.Forget(key)
	after, err := r.Resolve(ctx, key)
	if err != nil {
		t.Fatalf("resolve after revoke: %v", err)
	}
	if after.Entitled || after.Reason != ReasonRevoked {
		t.Fatalf("after revoke got entitled=%v reason=%s, want false/revoked", after.Entitled, after.Reason)
	}
}

// Turning entitlement on must not lock out installs that have not paired yet.
func TestLegacyKeyStillWorks(t *testing.T) {
	fs := emulatorClient(t)
	r := newWithClient(fs)
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))

	const oldKey = "a-key-from-before-pairing-existed"
	legacy := func(_ context.Context, plaintext string) bool { return plaintext == oldKey }

	var reached bool
	handler := Middleware(r, legacy, "", log)(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		reached = true
		w.WriteHeader(http.StatusOK)
	}))

	for _, c := range []struct {
		name   string
		key    string
		code   int
		passes bool
	}{
		{"pre-pairing key is honoured", oldKey, http.StatusOK, true},
		{"an unknown key is still refused", "sf_nonsense", http.StatusUnauthorized, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			reached = false
			req := httptest.NewRequest(http.MethodPost, "/cleanup", nil)
			req.Header.Set("Authorization", "Bearer "+c.key)
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Code != c.code || reached != c.passes {
				t.Fatalf("status=%d reached=%v, want %d/%v", rec.Code, reached, c.code, c.passes)
			}
		})
	}
}

// A revoked device must NOT be rescued by the legacy table.
func TestRevokedKeyIsNotRescuedByLegacy(t *testing.T) {
	fs := emulatorClient(t)
	r := newWithClient(fs)
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))

	future := time.Now().Add(48 * time.Hour)
	revoked := seed(t, fs, "u-legacy-revoked", "active", nil, &future, true)

	// A permissive legacy lookup that would wave anything through.
	handler := Middleware(r, func(context.Context, string) bool { return true }, "", log)(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			t.Error("a revoked device reached the handler")
			w.WriteHeader(http.StatusOK)
		}))

	req := httptest.NewRequest(http.MethodPost, "/cleanup", nil)
	req.Header.Set("Authorization", "Bearer "+revoked)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}
