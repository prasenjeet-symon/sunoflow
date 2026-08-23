package account

import (
	"testing"
	"time"
)

// The sidecars verify leases in Python, so the wire format is a cross-language
// contract. This vector is asserted byte-for-byte here and again in
// sidecars/shared/tests/test_lease.py; if one side changes, both tests fail and
// the mismatch is caught at build time rather than as a lockout in the field.
const (
	vectorSecret = "test-secret"
	// SHA-256 of the plaintext key "sf_test_device_key", so the Python test can
	// start from a real key and arrive at the same lease.
	vectorKeyID     = "b47e78ba09f3eca966ce0ccf24fc1d922ef9fbd95fe376128117b5e8dbb2a0a8"
	vectorPlaintext = "sf_test_device_key"
	vectorUID       = "user-1"
	vectorIssued    = 1_700_000_000
	vectorToken     = "eyJraWQiOiJiNDdlNzhiYTA5ZjNlY2E5IiwidWlkIjoidXNlci0xIiwiaWF0IjoxNzAwMDAwMDAwLCJleHAiOjE3MDAyNTkyMDB9.6d89be9115a017100035b2e4e721b8b8d0b3612a3b93c1c5a06e6a30c3430168"
)

func TestLeaseWireFormat(t *testing.T) {
	// The Python side starts from the plaintext key, so pin that it lands on
	// the same key id this vector was built from.
	if KeyID(vectorPlaintext) != vectorKeyID {
		t.Fatalf("KeyID(%q) = %s, want %s", vectorPlaintext, KeyID(vectorPlaintext), vectorKeyID)
	}

	issued := time.Unix(vectorIssued, 0).UTC()
	got := SignLease(vectorSecret, vectorKeyID, vectorUID, issued, LeaseTTL)
	if got != vectorToken {
		t.Errorf("lease wire format changed.\n got %s\nwant %s\n\nIf this is deliberate, update the matching vector in sidecars/shared/tests/test_lease.py and ship a sidecar build before the gateway.", got, vectorToken)
	}
}

func TestLeaseRoundTrip(t *testing.T) {
	now := time.Unix(vectorIssued, 0).UTC()
	token := SignLease(vectorSecret, vectorKeyID, vectorUID, now, LeaseTTL)

	if !VerifyLease(vectorSecret, token, vectorKeyID, now) {
		t.Error("a lease did not verify against the secret and key that made it")
	}
	if !VerifyLease(vectorSecret, token, vectorKeyID, now.Add(LeaseTTL-time.Minute)) {
		t.Error("a lease expired before its TTL was up")
	}
}

func TestLeaseRejections(t *testing.T) {
	now := time.Unix(vectorIssued, 0).UTC()
	token := SignLease(vectorSecret, vectorKeyID, vectorUID, now, LeaseTTL)
	otherKey := "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

	cases := []struct {
		name   string
		secret string
		token  string
		keyID  string
		at     time.Time
	}{
		{"expired", vectorSecret, token, vectorKeyID, now.Add(LeaseTTL + time.Second)},
		{"another device's lease", vectorSecret, token, otherKey, now},
		{"signed with a different secret", "not-the-secret", token, vectorKeyID, now},
		{"payload edited to extend the expiry", vectorSecret, forge(t, now), vectorKeyID, now},
		{"no signature", vectorSecret, "eyJhIjoxfQ", vectorKeyID, now},
		{"empty", vectorSecret, "", vectorKeyID, now},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if VerifyLease(c.secret, c.token, c.keyID, c.at) {
				t.Error("accepted a lease it should have refused")
			}
		})
	}
}

// forge builds the lease a user would hand-write into lease.json: a valid
// payload with a far-future expiry, but no matching signature.
func forge(t *testing.T, now time.Time) string {
	t.Helper()
	honest := SignLease(vectorSecret, vectorKeyID, vectorUID, now, LeaseTTL)
	tampered := SignLease("attacker-does-not-have-this", vectorKeyID, vectorUID, now, 100*365*24*time.Hour)
	if honest == tampered {
		t.Fatal("forged lease is identical to the honest one")
	}
	return tampered
}

// The default must be used when no secret is configured, or a deployment that
// never sets LEASE_SECRET would sign with "" and no sidecar could verify.
func TestEmptySecretFallsBackToDefault(t *testing.T) {
	now := time.Unix(vectorIssued, 0).UTC()
	if SignLease("", vectorKeyID, vectorUID, now, LeaseTTL) !=
		SignLease(DefaultLeaseSecret, vectorKeyID, vectorUID, now, LeaseTTL) {
		t.Error("an empty secret did not fall back to the built-in default")
	}
}
