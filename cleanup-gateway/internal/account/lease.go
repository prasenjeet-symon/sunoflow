package account

// Entitlement leases.
//
// The sidecar soft-fails to raw text whenever it cannot reach the gateway,
// because an outage on our side must never cost a user their words. Without a
// bound on that, blackholing the gateway's IP was unlimited free dictation:
// speech-to-text is local, so nothing else broke.
//
// A lease is what bounds it. Every successful entitlement check hands the
// sidecar a short-lived signed token; when the gateway is unreachable the
// sidecar keeps working only while an unexpired lease is on disk, and refuses
// once it lapses. A real outage stays invisible (leases outlive any plausible
// downtime and every successful call refreshes them); a permanently blocked
// host stops working within LeaseTTL.
//
// The signature is HMAC-SHA256 over the encoded payload. Be clear-eyed about
// what that buys: the verifying secret ships inside the sidecar, so someone who
// unpacks the binary can mint their own lease. It stops the bypass that costs
// nothing to perform and spreads — editing a JSON file — not a determined
// attacker, who could patch the sidecar regardless. Moving to an asymmetric
// signature (gateway signs, sidecar verifies with an embedded public key) is a
// drop-in replacement for SignLease/verifyLease and closes that gap; it needs a
// crypto dependency in the frozen sidecar, which is the only reason it is not
// what this does today.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"
)

// LeaseTTL is how long a device may keep dictating without reaching the
// gateway. Long enough that no plausible outage locks anyone out, short enough
// that a permanently blocked host is a few days of free use, not forever.
const LeaseTTL = 72 * time.Hour

// DefaultLeaseSecret signs leases when LEASE_SECRET is unset.
//
// It is deliberately a constant and deliberately not a secret: the sidecar must
// hold the same value to verify offline, so it ships in every install either
// way. Having a working default matters more than pretending otherwise —
// without one, an operator who forgets to set LEASE_SECRET would issue no
// leases at all and turn every brief outage into a lockout. Rotating it means
// shipping a matching sidecar build; see deploy/ENTITLEMENT.md.
const DefaultLeaseSecret = "sunoflow-lease-v1"

// leasePayload is the signed body. Kept to four short fields because it is
// round-tripped through a JSON file on every dictation.
type leasePayload struct {
	KID string `json:"kid"` // first 16 hex of the key's SHA-256; ties a lease to one device
	UID string `json:"uid"`
	Iat int64  `json:"iat"`
	Exp int64  `json:"exp"`
}

// leaseKID shortens a full key id (SHA-256 hex) to the identifier a lease
// carries. The sidecar computes the same thing from the key it holds, so a
// lease copied to another device is rejected.
func leaseKID(keyID string) string {
	if len(keyID) > 16 {
		return keyID[:16]
	}
	return keyID
}

// SignLease issues a lease for a device that has just been found entitled.
// The token is `base64url(payload).hex(hmac)`.
func SignLease(secret, keyID, uid string, now time.Time, ttl time.Duration) string {
	if secret == "" {
		secret = DefaultLeaseSecret
	}
	body, err := json.Marshal(leasePayload{
		KID: leaseKID(keyID),
		UID: uid,
		Iat: now.Unix(),
		Exp: now.Add(ttl).Unix(),
	})
	if err != nil {
		return ""
	}
	encoded := base64.RawURLEncoding.EncodeToString(body)
	return encoded + "." + sign(secret, encoded)
}

func sign(secret, encoded string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(encoded))
	return hex.EncodeToString(mac.Sum(nil))
}

// VerifyLease reports whether token is a lease this gateway issued for keyID
// and has not expired. The gateway never needs this — the sidecar does the
// offline check — but keeping the verifier next to the signer is what lets the
// tests pin the wire format the Python side has to match.
func VerifyLease(secret, token, keyID string, now time.Time) bool {
	if secret == "" {
		secret = DefaultLeaseSecret
	}
	encoded, signature, ok := strings.Cut(token, ".")
	if !ok {
		return false
	}
	if !hmac.Equal([]byte(signature), []byte(sign(secret, encoded))) {
		return false
	}
	body, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return false
	}
	var p leasePayload
	if err := json.Unmarshal(body, &p); err != nil {
		return false
	}
	if p.KID != leaseKID(keyID) {
		return false
	}
	return now.Unix() < p.Exp
}
