package server

import (
	"encoding/json"
	"net/http"

	"github.com/sunoflow/cleanup-gateway/internal/auth"
)

// adminCreateKeyRequest is the body for POST /admin/keys.
type adminCreateKeyRequest struct {
	Label string `json:"label"`
}

// adminCreateKeyResponse returns the plaintext key ONCE plus metadata.
type adminCreateKeyResponse struct {
	ID        string `json:"id"`
	Key       string `json:"key"` // plaintext — shown only here, never again
	Label     string `json:"label"`
	CreatedAt int64  `json:"created_at"`
}

// handleAdminCreateKey issues a new API key. The plaintext is returned once.
func (s *Server) handleAdminCreateKey(w http.ResponseWriter, r *http.Request) {
	var body adminCreateKeyRequest
	// Body is optional; empty label is fine.
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body)

	id, plaintext, hash, err := auth.IssueKey()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "key generation failed"})
		return
	}
	if err := s.Store.CreateKey(r.Context(), id, hash, body.Label, s.QuotaRPM, s.QuotaDaily); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "key storage failed"})
		return
	}
	writeJSON(w, http.StatusOK, adminCreateKeyResponse{
		ID:        id,
		Key:       plaintext,
		Label:     body.Label,
		CreatedAt: now().Unix(),
	})
}

// handleAdminListKeys returns metadata for all keys (never the hash).
func (s *Server) handleAdminListKeys(w http.ResponseWriter, r *http.Request) {
	keys, err := s.Store.ListKeys(r.Context())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "list failed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"keys": keys})
}

// handleAdminRevokeKey marks a key revoked by id.
func (s *Server) handleAdminRevokeKey(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing key id"})
		return
	}
	if err := s.Store.RevokeKey(r.Context(), id); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "revoke failed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "revoked", "id": id})
}