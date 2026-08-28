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
		ttl:      DecisionTTL,
		cache:    map[string]cached{},
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

func TestDecisionCacheStillExpires(t *testing.T) {
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
		t.Errorf("cache must expire after %s and re-read; store was read %d times", DecisionTTL, *lookups)
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
