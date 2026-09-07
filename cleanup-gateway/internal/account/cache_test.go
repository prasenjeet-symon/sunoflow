package account

import (
	"context"
	"testing"
	"time"
)

// medianDictationGap is the measured median gap between one dictation and the
// next in real usage. The decision cache is only worth having if it survives
// this, and at the old 60s TTL it did not: 70% of dictations missed the cache
// and paid a live Firestore read (p50 3437ms against 1131ms on a hit).
const medianDictationGap = 124 * time.Second

// cachedResolver builds a Resolver with a controllable clock and a counting
// lookup, so the cache can be exercised without a Firestore emulator.
func cachedResolver() (r *Resolver, lookups *int, advance func(time.Duration)) {
	now := time.Date(2026, 8, 28, 12, 0, 0, 0, time.UTC)
	count := 0
	r = &Resolver{
		ttl:        DecisionTTL,
		cache:      map[string]cached{},
		refreshing: map[string]bool{},
		// Run background refreshes inline so the stale-while-revalidate path is
		// observable deterministically in a test (production launches a goroutine).
		spawn:    func(f func()) { f() },
		lastSeen: map[string]time.Time{},
		seenGap:  5 * time.Minute,
		now:      func() time.Time { return now },
	}
	r.lookupFn = func(ctx context.Context, keyID string) (Resolution, error) {
		count++
		return Resolution{UID: "u1", DeviceID: "dev-1", KeyID: keyID, Entitled: true}, nil
	}
	return r, &count, func(d time.Duration) { now = now.Add(d) }
}

func TestDecisionCacheSurvivesTheGapBetweenDictations(t *testing.T) {
	r, lookups, advance := cachedResolver()
	ctx := context.Background()

	if _, err := r.Resolve(ctx, "sf_key"); err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	if *lookups != 1 {
		t.Fatalf("cold resolve should read the store once, got %d", *lookups)
	}

	// The regression this guards: a user dictates, pauses to think, dictates
	// again. That pause used to be long enough to expire the cache, putting a
	// Firestore round trip between their last word and their pasted text.
	advance(medianDictationGap)
	if _, err := r.Resolve(ctx, "sf_key"); err != nil {
		t.Fatalf("second resolve: %v", err)
	}
	if *lookups != 1 {
		t.Errorf("a dictation %s after the last one must be served from cache; store was read %d times",
			medianDictationGap, *lookups)
	}
}

func TestStaleDecisionIsRefreshedInBackground(t *testing.T) {
	// Past the TTL the decision is renewed — but the renewal is what happens, not
	// a blocking re-read on the way to the answer. The dictation is served from
	// the cached decision; Firestore is consulted behind it.
	r, lookups, advance := cachedResolver()
	ctx := context.Background()

	if _, err := r.Resolve(ctx, "sf_key"); err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	advance(DecisionTTL + time.Second)
	if _, err := r.Resolve(ctx, "sf_key"); err != nil {
		t.Fatalf("resolve after expiry: %v", err)
	}
	if *lookups != 2 {
		t.Errorf("a stale decision must be refreshed; store was read %d times, want 2", *lookups)
	}
}

func TestStaleDecisionIsServedBeforeTheRefreshLands(t *testing.T) {
	// The point of the change: a dictation past the TTL gets the last-known
	// verdict immediately, and only then is the fresh one fetched. So a device
	// that just lost entitlement still serves ONE stale dictation, then flips.
	r, _, advance := cachedResolver()
	ctx := context.Background()

	if res, err := r.Resolve(ctx, "sf_key"); err != nil || !res.Entitled {
		t.Fatalf("cold resolve should be entitled: %+v %v", res, err)
	}
	// The account lapses in Firestore.
	r.lookupFn = func(ctx context.Context, keyID string) (Resolution, error) {
		return Resolution{KeyID: keyID, Entitled: false, Reason: ReasonLapsed}, nil
	}

	advance(DecisionTTL + time.Second)
	// This one is served from the (entitled) cache even though Firestore now says no…
	res, err := r.Resolve(ctx, "sf_key")
	if err != nil || !res.Entitled {
		t.Fatalf("the stale read must serve the last-known (entitled) verdict: %+v %v", res, err)
	}
	// …and the background refresh (inline here) has since flipped the cache.
	res, err = r.Resolve(ctx, "sf_key")
	if err != nil || res.Entitled {
		t.Fatalf("after the refresh the verdict must be the fresh (not entitled) one: %+v %v", res, err)
	}
}

func TestStaleDecisionSurvivesAFirestoreOutage(t *testing.T) {
	// Serving stale through an outage is deliberate: today a cache miss during a
	// Firestore outage 503s the dictation, and the offline lease already grants a
	// lapsed device 72h, so keeping a known-good device working here costs nothing.
	r, _, advance := cachedResolver()
	ctx := context.Background()

	if _, err := r.Resolve(ctx, "sf_key"); err != nil {
		t.Fatalf("cold resolve: %v", err)
	}
	r.lookupFn = func(ctx context.Context, keyID string) (Resolution, error) {
		return Resolution{}, context.DeadlineExceeded // Firestore unreachable
	}
	advance(DecisionTTL + time.Second)
	res, err := r.Resolve(ctx, "sf_key")
	if err != nil {
		t.Fatalf("a stale read must not surface the refresh error: %v", err)
	}
	if !res.Entitled {
		t.Errorf("the last-known (entitled) verdict must be served through the outage")
	}
}

func TestConcurrentStaleReadsRefreshOnce(t *testing.T) {
	// A burst of stale reads for one key must collapse to a single Firestore
	// refresh, not one per request.
	r, lookups, advance := cachedResolver()
	var queued []func()
	r.spawn = func(f func()) { queued = append(queued, f) } // hold refreshes in-flight
	ctx := context.Background()

	if _, err := r.Resolve(ctx, "sf_key"); err != nil { // cold → lookups 1
		t.Fatalf("cold resolve: %v", err)
	}
	advance(DecisionTTL + time.Second)
	_, _ = r.Resolve(ctx, "sf_key") // stale → queues one refresh, marks in-flight
	_, _ = r.Resolve(ctx, "sf_key") // stale again → deduped, nothing queued
	if len(queued) != 1 {
		t.Fatalf("concurrent stale reads must queue one refresh, got %d", len(queued))
	}
	for _, f := range queued { // let the refresh run → lookups 2, in-flight cleared
		f()
	}
	if *lookups != 2 {
		t.Fatalf("the single refresh must read the store once more, got %d", *lookups)
	}
	// Once the in-flight refresh clears, a later stale read refreshes again.
	queued = nil
	advance(DecisionTTL + time.Second)
	_, _ = r.Resolve(ctx, "sf_key")
	if len(queued) != 1 {
		t.Fatalf("after the refresh cleared, a new stale read should refresh; got %d", len(queued))
	}
}

func TestDecisionTTLIsWorthHavingButBoundedByTheLease(t *testing.T) {
	// Lower bound: a TTL that does not outlive a normal pause between
	// dictations buys nothing — every dictation pays the read anyway.
	if DecisionTTL <= medianDictationGap {
		t.Errorf("DecisionTTL %s does not survive the median dictation gap %s, so most "+
			"dictations would still pay a live lookup", DecisionTTL, medianDictationGap)
	}
	// Upper bound: the cache must stay well inside the offline lease, which is
	// the window that actually governs how long a lapsed device keeps working.
	// If this ever inverts, the cache — not the lease — has become the binding
	// constraint on revocation, and that is a deliberate decision, not a default.
	if DecisionTTL >= LeaseTTL {
		t.Errorf("DecisionTTL %s is not comfortably inside LeaseTTL %s", DecisionTTL, LeaseTTL)
	}
}

func TestForgetRevokesWithoutWaitingOutTheTTL(t *testing.T) {
	// The safety counterpart to a wider TTL: a revoke that must land now still
	// can, without anyone shortening the cache for everybody.
	r, lookups, _ := cachedResolver()
	ctx := context.Background()

	if _, err := r.Resolve(ctx, "sf_key"); err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	r.Forget("sf_key")
	if _, err := r.Resolve(ctx, "sf_key"); err != nil {
		t.Fatalf("resolve after forget: %v", err)
	}
	if *lookups != 2 {
		t.Errorf("Forget must drop the cached decision; store was read %d times", *lookups)
	}
}
