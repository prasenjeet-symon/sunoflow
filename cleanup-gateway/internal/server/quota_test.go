package server

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/sunoflow/cleanup-gateway/internal/account"
	"github.com/sunoflow/cleanup-gateway/internal/ratelimit"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// Quotas through the production middleware chain.
//
// The unit tests in internal/ratelimit drive the limiter behind a stub identity
// middleware, which is exactly the blind spot that let finding 04 ship: the
// limiter worked fine in isolation and did nothing once the account middleware
// was the one in front of it. These wire the real thing — account.Middleware
// resolving against Firestore, then the limiter — and assert that a configured
// quota actually bites.

// countingBackend records how many cleanups actually cost us a provider call.
type countingBackend struct{ calls int }

func (b *countingBackend) Cleanup(context.Context, string) (string, error) {
	b.calls++
	return "cleaned", nil
}
func (b *countingBackend) Healthy(context.Context) bool { return true }
func (b *countingBackend) Name() string                 { return "counting" }

type quotaFixture struct {
	url     string
	backend *countingBackend
}

func newQuotaFixture(t *testing.T, rpm, daily int, seed func(ctx context.Context, fs *firestore.Client)) quotaFixture {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("set FIRESTORE_EMULATOR_HOST to run the Firestore-backed quota tests")
	}
	ctx := context.Background()
	fs, err := firestore.NewClient(ctx, "sunoflow-quota-test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = fs.Close() })
	seed(ctx, fs)

	resolver, err := account.New(ctx, "sunoflow-quota-test", "")
	if err != nil {
		t.Fatal(err)
	}
	st, err := store.New(t.TempDir() + "/keys.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	be := &countingBackend{}
	srv := &Server{
		Backend: be, Store: st,
		Logger:      slog.New(slog.NewTextHandler(io.Discard, nil)),
		LeaseSecret: "quota-test",
	}
	ts := httptest.NewServer(NewMux(srv, ratelimit.New(st, rpm, daily, nil), "admin", resolver))
	t.Cleanup(ts.Close)
	return quotaFixture{url: ts.URL, backend: be}
}

// seedEntitled writes a paired device on an account with a running trial.
func seedEntitled(key, uid string) func(context.Context, *firestore.Client) {
	return func(ctx context.Context, fs *firestore.Client) {
		if _, err := fs.Collection("apiKeys").Doc(account.KeyID(key)).Set(ctx, map[string]any{
			"uid": uid, "deviceId": "d-" + key, "revokedAt": nil,
		}); err != nil {
			panic(err)
		}
		if _, err := fs.Collection("users").Doc(uid).Set(ctx, map[string]any{
			"plan": "trial", "trialEndsAt": time.Now().Add(48 * time.Hour), "cancelAtPeriodEnd": false,
		}); err != nil {
			panic(err)
		}
	}
}

func cleanupN(t *testing.T, url, key string, n int) (served, limited int) {
	t.Helper()
	for i := 0; i < n; i++ {
		req, _ := http.NewRequest("POST", url+"/cleanup", strings.NewReader(`{"text":"hello"}`))
		req.Header.Set("Authorization", "Bearer "+key)
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		switch resp.StatusCode {
		case http.StatusOK:
			served++
		case http.StatusTooManyRequests:
			limited++
		default:
			t.Fatalf("unexpected status %d", resp.StatusCode)
		}
	}
	return served, limited
}

// The regression. Before the fix this served 25 of 25 against a 2/min quota and
// billed 25 provider calls.
func TestQuotaAppliesThroughTheAccountMiddleware(t *testing.T) {
	const key = "sf_quota_probe"
	f := newQuotaFixture(t, 2, 100, seedEntitled(key, "u-quota"))

	served, limited := cleanupN(t, f.url, key, 25)

	if limited == 0 {
		t.Fatalf("no request was rate limited: %d served against a 2/min quota", served)
	}
	if served != 2 {
		t.Errorf("served %d of 25 against a 2/min quota, want 2", served)
	}
	if f.backend.calls != served {
		t.Errorf("backend billed %d calls but only %d were served", f.backend.calls, served)
	}
}

func TestDailyQuotaAppliesThroughTheAccountMiddleware(t *testing.T) {
	const key = "sf_quota_daily"
	f := newQuotaFixture(t, 1000, 3, seedEntitled(key, "u-daily"))

	served, limited := cleanupN(t, f.url, key, 10)

	if served != 3 || limited != 7 {
		t.Errorf("served %d / limited %d against a 3/day quota, want 3 / 7", served, limited)
	}
}

// One subscription is one allowance however many devices it has paired.
func TestTwoDevicesOnOneAccountShareTheQuota(t *testing.T) {
	const laptop, desktop = "sf_quota_laptop", "sf_quota_desktop"
	f := newQuotaFixture(t, 1000, 4, func(ctx context.Context, fs *firestore.Client) {
		seedEntitled(laptop, "u-shared")(ctx, fs)
		seedEntitled(desktop, "u-shared")(ctx, fs)
	})

	a, _ := cleanupN(t, f.url, laptop, 3)
	b, _ := cleanupN(t, f.url, desktop, 3)

	if a+b != 4 {
		t.Errorf("two devices on one account served %d against a 4/day quota, want 4", a+b)
	}
}

// A refused request must not consume the caller's allowance — otherwise an
// expired account could exhaust nothing but our patience, and a paying user
// behind a flapping key would lose quota to failures.
func TestRefusedRequestsDoNotConsumeQuota(t *testing.T) {
	const key = "sf_quota_after_refusal"
	f := newQuotaFixture(t, 1000, 3, func(ctx context.Context, fs *firestore.Client) {
		seedEntitled(key, "u-refused")(ctx, fs)
	})

	// Ten unauthenticated attempts: refused before the limiter, so they cost
	// the account nothing.
	for i := 0; i < 10; i++ {
		req, _ := http.NewRequest("POST", f.url+"/cleanup", strings.NewReader(`{"text":"hi"}`))
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("unauthenticated attempt got %d, want 401", resp.StatusCode)
		}
	}

	if served, _ := cleanupN(t, f.url, key, 3); served != 3 {
		t.Errorf("account served %d of its 3/day allowance after unrelated refusals, want 3", served)
	}
}
