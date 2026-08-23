// Package caller carries the identity of an authenticated request from the
// middleware that established it to whatever downstream meters or bills it.
//
// It exists because there were two of these. `auth` stashed a key id under its
// own unexported context key; `account` stashed a resolution under a different
// unexported key of a different type. Go compares context keys by type as well
// as value, so the rate limiter — which read auth's — found nothing whenever
// the account middleware was the one in the chain, which is to say always, in
// production. It then took its "shouldn't happen here" branch and served every
// request unmetered, with both the per-minute and the daily quota silently off.
//
// One type, one key, populated by every authenticating middleware, is the fix.
// Adding a third middleware means setting this, and the limiter refuses a
// request that arrives without it rather than waving it through — so the next
// wiring mistake is an outage on a dev machine, not an unbounded provider bill
// discovered on an invoice.
package caller

import "context"

type ctxKey int

const identityKey ctxKey = 1

// Identity is who is making a request, for metering purposes.
type Identity struct {
	// KeyID is the device key doing the calling. Always set.
	KeyID string
	// UID is the account that owns the key, where it is known. Empty for a
	// legacy key from the gateway's own table, which belongs to no account.
	UID string
}

// MeterKey is what usage is attributed to: the account where we know it, the
// device key otherwise.
//
// Per account rather than per device, deliberately. Quotas bound what one
// paying customer can cost us, and a customer who pairs five machines is still
// one subscription — metering per device would hand them five times the
// allowance for the same money.
func (i Identity) MeterKey() string {
	if i.UID != "" {
		return i.UID
	}
	return i.KeyID
}

// With returns a context carrying id.
func With(ctx context.Context, id Identity) context.Context {
	return context.WithValue(ctx, identityKey, id)
}

// From returns the identity an authenticating middleware established. The
// boolean is false when no middleware set one, which is always a bug in the
// route's middleware chain rather than anything the caller did.
func From(ctx context.Context) (Identity, bool) {
	v, ok := ctx.Value(identityKey).(Identity)
	return v, ok
}
