package server

// The cloud speech-to-text route: POST /stt takes audio and returns a
// transcript. It is the warm-start dictation path — a new install transcribes
// here while its local model downloads, then the sidecar cuts over to on-device
// and stops calling. The sidecar sends the same WAV it would feed the local
// model; the gateway forwards it to the configured STT provider.
//
// Wire contract:
//
//	request  {"audio":"<base64>","format":"wav","language":"en"}
//	response {"transcript":"...","lease":"..."}   200
//	         {"error":"unavailable"}              502  (provider failed)
//	         {"error":"malformed request", ...}   400
//	         {"error":"limit"}                    429  (from the STT limiter)
//	         {"error":"unavailable", ...}         501  (no STT provider configured)
//
// No raw fallback: unlike /cleanup there is no text to fall back to, so a
// provider failure is a hard error and the sidecar decides what to do (retry,
// wait for the local model, or surface nothing). Cleanup is a separate call the
// sidecar makes afterwards, exactly as it does for a local transcript.

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/sunoflow/cleanup-gateway/internal/analytics"
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/caller"
)

// maxSTTBody caps the /stt request body. A SunoFlow recording is 16kHz mono
// 16-bit PCM (~32KB/s of audio); base64 inflates ~33%. 12MB covers a few
// minutes of speech, which is far longer than any single warm-start dictation —
// anything larger is rejected rather than buffered.
const maxSTTBody = 12 << 20

// maxAudioBytes is the practical cap on the decoded audio payload.
const maxAudioBytes = 10 << 20

// sttRequest mirrors the /stt API contract.
type sttRequest struct {
	// AudioB64 is the recording, base64-encoded. Raw file bytes of whatever
	// container Format names (default WAV).
	AudioB64 string `json:"audio"`
	// Format is the audio container ("wav", "mp3", …). Empty means wav — the
	// format the SunoFlow recorder produces.
	Format string `json:"format"`
	// Language is an optional BCP-47 hint ("en"). The provider auto-detects when
	// empty; the gateway's own STT_LANGUAGE config is the fallback.
	Language string `json:"language"`
}

// sttResponse is the single success shape. lease rides along so a warm-start
// device keeps its offline entitlement lease fresh, same as /cleanup.
//
// Provider and STTMs are diagnostics: which backend served the call and how long
// the gateway→provider round trip took. The sidecar logs them next to its own
// end-to-end timing, so the difference isolates the sidecar↔gateway network
// overhead from the gateway↔provider time — the split that tells us which hop to
// optimise. Both are omitempty, so an older sidecar simply ignores them.
type sttResponse struct {
	Transcript string `json:"transcript"`
	Lease      string `json:"lease,omitempty"`
	Provider   string `json:"provider,omitempty"`
	STTMs      int64  `json:"stt_ms,omitempty"`
}

// sttBackend returns the configured STT provider, or nil when none is wired
// (then /stt answers 501).
func (s *Server) sttBackend() backend.STTBackend { return s.STT }

// mimeForFormat maps the request's format field to a content type.
func mimeForFormat(format string) string {
	switch strings.ToLower(strings.TrimSpace(format)) {
	case "", "wav", "wave", "pcm":
		return "audio/wav"
	case "mp3", "mpeg":
		return "audio/mpeg"
	case "m4a", "mp4":
		return "audio/mp4"
	case "ogg":
		return "audio/ogg"
	case "flac":
		return "audio/flac"
	case "webm":
		return "audio/webm"
	default:
		return "audio/wav"
	}
}

// handleSTT is the cloud transcription endpoint. Authentication and the STT
// quota run in the middleware chain; everything here is parse → transcribe →
// respond.
func (s *Server) handleSTT(w http.ResponseWriter, r *http.Request) {
	started := time.Now()

	stt := s.sttBackend()
	if stt == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "unavailable", "message": "no stt backend"})
		return
	}

	var req sttRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxSTTBody)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed json"})
		return
	}
	audio, err := decodeAudio(req.AudioB64)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": err.Error()})
		return
	}
	if len(audio) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": "empty audio"})
		return
	}

	mime := mimeForFormat(req.Format)
	providerStart := time.Now()
	transcript, err := stt.Transcribe(r.Context(), audio, mime)
	sttMs := time.Since(providerStart).Milliseconds()
	if err != nil {
		s.Logger.Warn("stt transcription failed", "err", err.Error())
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unavailable"})
		s.captureSTT(r, started, len(audio), 0, "error")
		return
	}

	writeJSON(w, http.StatusOK, sttResponse{
		Transcript: transcript,
		Lease:      leaseFor(r),
		Provider:   s.STTProvider,
		STTMs:      sttMs,
	})
	s.captureSTT(r, started, len(audio), len(transcript), "ok")
}

// captureSTT records one transcription — lengths, timing, outcome; no content.
func (s *Server) captureSTT(r *http.Request, started time.Time, audioBytes, transcriptChars int, outcome string) {
	clientOS, clientVersion := parseClient(r.Header.Get(clientHeader))
	id, _ := caller.From(r.Context())
	s.Analytics.Capture(analytics.Event{
		Name:       "stt",
		DistinctID: id.MeterKey(),
		Properties: map[string]any{
			"os":               clientOS,
			"app_version":      clientVersion,
			"provider":         s.STTProvider,
			"audio_bytes":      audioBytes,
			"transcript_chars": transcriptChars,
			"outcome":          outcome,
			"latency_ms":       time.Since(started).Milliseconds(),
		},
		PersonProperties: map[string]any{
			"os":          clientOS,
			"app_version": clientVersion,
		},
	})
}

// decodeAudio validates and decodes the base64 audio payload. Empty is caught
// by the caller as an empty-audio request; anything present must be valid
// base64 under the cap.
func decodeAudio(b64 string) ([]byte, error) {
	if b64 == "" {
		return nil, nil
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, errors.New("audio is not valid base64")
	}
	if len(raw) > maxAudioBytes {
		return nil, errors.New("audio too large")
	}
	return raw, nil
}
