package backend

import (
	"net/http"
	"testing"
	"time"
)

// goDefaultIdleTimeout is what net/http uses when nobody says otherwise. It is
// shorter than the gap between one dictation and the next, which is exactly why
// NewHTTPClient exists.
const goDefaultIdleTimeout = 90 * time.Second

func TestProviderClientOutlivesTheGapBetweenDictations(t *testing.T) {
	tr, ok := NewHTTPClient(time.Minute).Transport.(*http.Transport)
	if !ok {
		t.Fatal("provider client must carry its own *http.Transport, not the default one")
	}
	if tr.IdleConnTimeout <= goDefaultIdleTimeout {
		t.Errorf("IdleConnTimeout %s is no better than net/http's %s — a connection dropped "+
			"between dictations makes the next one re-pay DNS, TCP and TLS before the model "+
			"sees a token (measured: 1.86s cold against 1.29s warm)",
			tr.IdleConnTimeout, goDefaultIdleTimeout)
	}
	if tr.MaxIdleConnsPerHost < 4 {
		t.Errorf("MaxIdleConnsPerHost %d is too low: every device's traffic funnels into one "+
			"provider host, so concurrent dictations would close connections on return",
			tr.MaxIdleConnsPerHost)
	}
}

func TestProviderClientDoesNotRetuneTheRestOfTheProcess(t *testing.T) {
	// http.DefaultTransport is process-global and the Firestore SDK is on it
	// too. Tuning it in place instead of cloning would silently change the
	// behaviour of every other client in the binary.
	before := http.DefaultTransport.(*http.Transport).IdleConnTimeout
	client := NewHTTPClient(time.Minute)
	after := http.DefaultTransport.(*http.Transport).IdleConnTimeout

	if before != after {
		t.Errorf("NewHTTPClient mutated http.DefaultTransport: IdleConnTimeout %s -> %s", before, after)
	}
	if client.Transport == http.DefaultTransport {
		t.Error("provider client shares http.DefaultTransport; it must clone it")
	}
}

func TestProviderClientKeepsTheRequestedTimeout(t *testing.T) {
	// The per-call deadline is the backstop on a hung provider. Swapping the
	// transport must not quietly drop it.
	if got := NewHTTPClient(25 * time.Second).Timeout; got != 25*time.Second {
		t.Errorf("Timeout = %s, want 25s", got)
	}
}
