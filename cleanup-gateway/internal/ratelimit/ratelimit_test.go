package ratelimit

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/sunoflow/cleanup-gateway/internal/caller"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// served counts how many of n requests reached the handler, and returns the
// status of the last refusal.
func drive(t *testing.T, h http.Handler, n int) (served int, lastStatus int) {
	t.Helper()
	for i := 0; i < n; i++ {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("POST", "/cleanup", nil))
		if rec.Code == http.StatusOK {
			served++
		} else {
			lastStatus = rec.Code
		}
	}
	return served, lastStatus
}

func newLimiter(t *testing.T, rpm, daily int) *Limiter {
	t.Helper()
	st, err := store.New(t.TempDir() + "/keys.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return New(st, rpm, daily, nil)
}

// withIdentity stands in for whichever authenticating middleware ran first.
func withIdentity(id caller.Identity, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(w, r.WithContext(caller.With(r.Context(), id)))
	})
}

var ok = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })

// This is the one that matters: the bug shipped because nothing asserted that a
// configured quota is actually applied.
func TestPerMinuteQuotaIsEnforced(t *testing.T) {
	l := newLimiter(t, 3, 1000)
	h := withIdentity(caller.Identity{KeyID: "k1", UID: "u1"}, l.Middleware(ok))

	served, status := drive(t, h, 10)
	if served != 3 {
		t.Errorf("served %d of 10 with a 3/min quota, want 3", served)
	}
	if status != http.StatusTooManyRequests {
		t.Errorf("refusal status = %d, want 429", status)
	}
}

func TestDailyQuotaIsEnforced(t *testing.T) {
	l := newLimiter(t, 1000, 4)
	h := withIdentity(caller.Identity{KeyID: "k1", UID: "u1"}, l.Middleware(ok))

	served, status := drive(t, h, 10)
	if served != 4 {
		t.Errorf("served %d of 10 with a 4/day quota, want 4", served)
	}
	if status != http.StatusTooManyRequests {
		t.Errorf("refusal status = %d, want 429", status)
	}
}

// A request the limiter cannot attribute is the exact shape of the original
// bug. It must refuse, not serve: serving is how an unmetered request becomes a
// provider bill nobody notices.
func TestAnUnidentifiedRequestIsRefusedNotServed(t *testing.T) {
	l := newLimiter(t, 1000, 1000)
	h := l.Middleware(ok) // no authenticating middleware in front

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/cleanup", nil))

	if rec.Code == http.StatusOK {
		t.Fatal("served a request it could not meter — this is finding 04 all over again")
	}
	if rec.Code != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500 (a broken chain is our bug, not the caller's)", rec.Code)
	}
}

func TestAnEmptyIdentityIsAlsoRefused(t *testing.T) {
	l := newLimiter(t, 1000, 1000)
	h := withIdentity(caller.Identity{}, l.Middleware(ok))

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/cleanup", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", rec.Code)
	}
}

// One subscription, one allowance. Metering per device would multiply a
// customer's quota by the number of machines they pair.
func TestDevicesOnOneAccountShareTheQuota(t *testing.T) {
	l := newLimiter(t, 1000, 6)
	laptop := withIdentity(caller.Identity{KeyID: "key-laptop", UID: "u1"}, l.Middleware(ok))
	desktop := withIdentity(caller.Identity{KeyID: "key-desktop", UID: "u1"}, l.Middleware(ok))

	a, _ := drive(t, laptop, 4)
	b, _ := drive(t, desktop, 4)

	if a+b != 6 {
		t.Errorf("two devices on one account served %d requests against a 6/day quota, want 6", a+b)
	}
}

func TestSeparateAccountsGetSeparateQuotas(t *testing.T) {
	l := newLimiter(t, 1000, 3)
	alice := withIdentity(caller.Identity{KeyID: "k-a", UID: "alice"}, l.Middleware(ok))
	bob := withIdentity(caller.Identity{KeyID: "k-b", UID: "bob"}, l.Middleware(ok))

	if a, _ := drive(t, alice, 5); a != 3 {
		t.Errorf("alice served %d, want 3", a)
	}
	if b, _ := drive(t, bob, 5); b != 3 {
		t.Errorf("bob served %d — alice's usage should not count against him", b)
	}
}

// A legacy key belongs to no account, so it meters against itself rather than
// falling into a shared empty-string bucket with every other legacy key.
func TestALegacyKeyMetersAgainstItself(t *testing.T) {
	l := newLimiter(t, 1000, 2)
	one := withIdentity(caller.Identity{KeyID: "legacy-1"}, l.Middleware(ok))
	two := withIdentity(caller.Identity{KeyID: "legacy-2"}, l.Middleware(ok))

	if a, _ := drive(t, one, 4); a != 2 {
		t.Errorf("first legacy key served %d, want 2", a)
	}
	if b, _ := drive(t, two, 4); b != 2 {
		t.Errorf("second legacy key served %d, want its own allowance of 2", b)
	}
}

func TestMeterKeyPrefersTheAccount(t *testing.T) {
	if got := (caller.Identity{KeyID: "k", UID: "u"}).MeterKey(); got != "u" {
		t.Errorf("MeterKey() = %q, want the uid", got)
	}
	if got := (caller.Identity{KeyID: "k"}).MeterKey(); got != "k" {
		t.Errorf("MeterKey() with no uid = %q, want the key id", got)
	}
	if got := (caller.Identity{}).MeterKey(); got != "" {
		t.Errorf("an empty identity must not meter as %q", got)
	}
}
