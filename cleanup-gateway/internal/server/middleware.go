package server

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
)

type wrappedWriter struct {
	http.ResponseWriter
	status int
}

func (w *wrappedWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

// withLogging wraps the handler in request-id generation and structured logging.
// It logs metadata only (request id, method, path, status, latency) — never
// transcript contents.
func withLogging(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqID := r.Header.Get("X-Request-Id")
		if reqID == "" {
			reqID = uuid.NewString()
		}
		w.Header().Set("X-Request-Id", reqID)

		start := time.Now()
		ww := &wrappedWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(ww, r)

		logger.Info("request",
			"request_id", reqID,
			"method", r.Method,
			"path", r.URL.Path,
			"status", ww.status,
			"latency_ms", time.Since(start).Milliseconds(),
		)
	})
}