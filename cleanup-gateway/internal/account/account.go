// Package account resolves a device's API key to the SunoFlow account that owns
// it, and decides whether that account is currently entitled to use the service.
//
// Keys are issued by the pairing Cloud Function, not by this gateway: Firestore
// holds `apiKeys/{sha256(key)} -> {uid, deviceId, revokedAt}` and
// `users/{uid} -> {plan, trialEndsAt, currentPeriodEnd, cancelAtPeriodEnd}`.
// Deciding entitlement here — rather than in the browser — is the point: the
// dashboard can only ever express an intent, this is where it is enforced.
package account

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"sync"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/option"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// ErrUnknownKey means the key has never existed. Distinct from a revoked key so
// callers can log the difference.
var ErrUnknownKey = errors.New("account: unknown key")

// Reason explains an entitlement decision, for logging and for the message the
// app shows the user.
type Reason string

const (
	ReasonTrial        Reason = "trial"
	ReasonActive       Reason = "active"
	ReasonTrialExpired Reason = "trial_expired"
	ReasonCanceled     Reason = "canceled"
	ReasonLapsed       Reason = "lapsed"
	ReasonRevoked      Reason = "revoked"
	ReasonNoAccount    Reason = "no_account"
)

// Resolution is what the gateway needs to know about the caller.
type Resolution struct {
	UID      string
	DeviceID string
	KeyID    string
	Entitled bool
	Reason   Reason
	// Lease is a signed permission to keep dictating while the gateway is
	// unreachable. Stamped by the middleware on an entitled request, never by
	// the resolver — so it is always empty in the decision cache and every
	// served request gets a lease minted fresh. See lease.go.
	Lease string
}

type cached struct {
	res Resolution
	at  time.Time
}

// Resolver answers "who is this and may they use the service?", caching results
// briefly so a busy device does not cost a Firestore read per dictation.
type Resolver struct {
	fs  *firestore.Client
	ttl time.Duration

	mu    sync.RWMutex
	cache map[string]cached

	// lastSeen throttles device heartbeat writes.
	seenMu   sync.Mutex
	lastSeen map[string]time.Time
	seenGap  time.Duration

	now func() time.Time
}

// New connects to Firestore. credentialsFile may be empty, in which case
// Application Default Credentials are used (and FIRESTORE_EMULATOR_HOST is
// honoured, which is how the tests run).
func New(ctx context.Context, projectID, credentialsFile string) (*Resolver, error) {
	var opts []option.ClientOption
	if credentialsFile != "" {
		opts = append(opts, option.WithCredentialsFile(credentialsFile))
	}
	fs, err := firestore.NewClient(ctx, projectID, opts...)
	if err != nil {
		return nil, err
	}
	return newWithClient(fs), nil
}

func newWithClient(fs *firestore.Client) *Resolver {
	return &Resolver{
		fs:       fs,
		ttl:      60 * time.Second,
		cache:    map[string]cached{},
		lastSeen: map[string]time.Time{},
		seenGap:  5 * time.Minute,
		now:      time.Now,
	}
}

func (r *Resolver) Close() error { return r.fs.Close() }

// KeyID is the stored identifier for a plaintext key: its SHA-256, hex encoded.
// It must match what the pairing function writes.
func KeyID(plaintext string) string {
	sum := sha256.Sum256([]byte(plaintext))
	return hex.EncodeToString(sum[:])
}

// Resolve looks up a key and evaluates entitlement.
func (r *Resolver) Resolve(ctx context.Context, plaintext string) (Resolution, error) {
	id := KeyID(plaintext)

	r.mu.RLock()
	if c, ok := r.cache[id]; ok && r.now().Sub(c.at) < r.ttl {
		r.mu.RUnlock()
		return c.res, nil
	}
	r.mu.RUnlock()

	res, err := r.lookup(ctx, id)
	if err != nil {
		return Resolution{}, err
	}

	r.mu.Lock()
	r.cache[id] = cached{res: res, at: r.now()}
	r.mu.Unlock()
	return res, nil
}

func (r *Resolver) lookup(ctx context.Context, keyID string) (Resolution, error) {
	snap, err := r.fs.Collection("apiKeys").Doc(keyID).Get(ctx)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Resolution{}, ErrUnknownKey
		}
		return Resolution{}, err
	}

	var key struct {
		UID       string     `firestore:"uid"`
		DeviceID  string     `firestore:"deviceId"`
		RevokedAt *time.Time `firestore:"revokedAt"`
	}
	if err := snap.DataTo(&key); err != nil {
		return Resolution{}, err
	}
	res := Resolution{UID: key.UID, DeviceID: key.DeviceID, KeyID: keyID}

	if key.RevokedAt != nil {
		res.Reason = ReasonRevoked
		return res, nil
	}

	userSnap, err := r.fs.Collection("users").Doc(key.UID).Get(ctx)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			res.Reason = ReasonNoAccount
			return res, nil
		}
		return Resolution{}, err
	}

	var acct struct {
		Plan              string     `firestore:"plan"`
		TrialEndsAt       *time.Time `firestore:"trialEndsAt"`
		CurrentPeriodEnd  *time.Time `firestore:"currentPeriodEnd"`
		CancelAtPeriodEnd bool       `firestore:"cancelAtPeriodEnd"`
	}
	if err := userSnap.DataTo(&acct); err != nil {
		return Resolution{}, err
	}

	res.Entitled, res.Reason = entitled(acct.Plan, acct.TrialEndsAt, acct.CurrentPeriodEnd, acct.CancelAtPeriodEnd, r.now())
	return res, nil
}

// entitled mirrors the states the dashboard shows, so what a user sees and what
// the gateway enforces cannot drift apart.
func entitled(plan string, trialEndsAt, periodEnd *time.Time, cancelAtPeriodEnd bool, now time.Time) (bool, Reason) {
	switch plan {
	case "active":
		// A cancelled subscription keeps working to the end of the paid period.
		if cancelAtPeriodEnd && periodEnd != nil && now.After(*periodEnd) {
			return false, ReasonLapsed
		}
		return true, ReasonActive
	case "canceled":
		return false, ReasonCanceled
	case "trial", "":
		if trialEndsAt != nil && now.Before(*trialEndsAt) {
			return true, ReasonTrial
		}
		return false, ReasonTrialExpired
	default:
		return false, ReasonNoAccount
	}
}

// TouchDevice records that a device was used, at most once every seenGap. Errors
// are deliberately swallowed: a failed heartbeat must never fail a dictation.
func (r *Resolver) TouchDevice(ctx context.Context, uid, deviceID string) {
	if uid == "" || deviceID == "" {
		return
	}
	k := uid + "/" + deviceID

	r.seenMu.Lock()
	if last, ok := r.lastSeen[k]; ok && r.now().Sub(last) < r.seenGap {
		r.seenMu.Unlock()
		return
	}
	r.lastSeen[k] = r.now()
	r.seenMu.Unlock()

	_, _ = r.fs.Collection("users").Doc(uid).Collection("devices").Doc(deviceID).
		Set(ctx, map[string]any{"lastSeenAt": r.now()}, firestore.MergeAll)
}

// Forget drops a cached decision, so a revoke takes effect without waiting out
// the TTL. Used by tests and available to an admin endpoint.
func (r *Resolver) Forget(plaintext string) {
	r.mu.Lock()
	delete(r.cache, KeyID(plaintext))
	r.mu.Unlock()
}
