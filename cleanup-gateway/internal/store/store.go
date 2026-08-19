// Package store provides SQLite-backed persistence for API keys and per-day usage.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

// Key is a stored API key. The plaintext is never persisted; only the SHA-256 hash.
type Key struct {
	ID        string
	KeyHash   string
	Label     string
	CreatedAt int64
	RevokedAt sql.NullInt64
	QuotaRPM  int
	QuotaDaily int
}

// Store wraps a SQLite database holding keys and usage.
type Store struct {
	db *sql.DB
}

// New opens (creating if necessary) the SQLite database at path and ensures the
// schema exists.
func New(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// SQLite handles low-concurrency admin writes fine; one writer is plenty.
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS keys (
  id          TEXT PRIMARY KEY,
  key_hash    TEXT NOT NULL UNIQUE,
  label       TEXT,
  created_at  INTEGER NOT NULL,
  revoked_at  INTEGER,
  quota_rpm   INTEGER NOT NULL DEFAULT 60,
  quota_daily INTEGER NOT NULL DEFAULT 5000
);
CREATE TABLE IF NOT EXISTS usage (
  key_id      TEXT NOT NULL,
  day         TEXT NOT NULL,
  count       INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (key_id, day)
);
`)
	if err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

// CreateKey inserts a new key record.
func (s *Store) CreateKey(ctx context.Context, id, hash, label string, rpm, daily int) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO keys (id, key_hash, label, created_at, quota_rpm, quota_daily) VALUES (?, ?, ?, ?, ?, ?)`,
		id, hash, label, time.Now().Unix(), rpm, daily)
	if err != nil {
		return fmt.Errorf("create key: %w", err)
	}
	return nil
}

// LookupByHash returns the non-revoked key with the given hash, or ErrNotFound.
func (s *Store) LookupByHash(ctx context.Context, hash string) (*Key, error) {
	var k Key
	var revokedAt sql.NullInt64
	err := s.db.QueryRowContext(ctx,
		`SELECT id, key_hash, label, created_at, revoked_at, quota_rpm, quota_daily FROM keys WHERE key_hash = ? AND revoked_at IS NULL`,
		hash,
	).Scan(&k.ID, &k.KeyHash, &k.Label, &k.CreatedAt, &revokedAt, &k.QuotaRPM, &k.QuotaDaily)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("lookup key: %w", err)
	}
	k.RevokedAt = revokedAt
	return &k, nil
}

// ListKeys returns all keys (metadata only — never the hash) for the admin view.
func (s *Store) ListKeys(ctx context.Context) ([]KeyMeta, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, label, created_at, revoked_at, quota_rpm, quota_daily FROM keys ORDER BY created_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("list keys: %w", err)
	}
	defer rows.Close()
	var out []KeyMeta
	for rows.Next() {
		var m KeyMeta
		var revokedAt sql.NullInt64
		if err := rows.Scan(&m.ID, &m.Label, &m.CreatedAt, &revokedAt, &m.QuotaRPM, &m.QuotaDaily); err != nil {
			return nil, err
		}
		m.Revoked = revokedAt.Valid
		out = append(out, m)
	}
	return out, rows.Err()
}

// RevokeKey marks a key revoked by setting revoked_at. Idempotent.
func (s *Store) RevokeKey(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE keys SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`,
		time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("revoke key: %w", err)
	}
	return nil
}

// UsageForToday returns the request count for the given key on today's UTC date.
func (s *Store) UsageForToday(ctx context.Context, keyID string) (int, error) {
	day := time.Now().UTC().Format("2006-01-02")
	var count int
	err := s.db.QueryRowContext(ctx,
		`SELECT count FROM usage WHERE key_id = ? AND day = ?`,
		keyID, day,
	).Scan(&count)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, nil
		}
		return 0, fmt.Errorf("usage lookup: %w", err)
	}
	return count, nil
}

// IncrementUsage bumps the per-key per-day counter, creating the row if needed.
func (s *Store) IncrementUsage(ctx context.Context, keyID string) error {
	day := time.Now().UTC().Format("2006-01-02")
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO usage (key_id, day, count) VALUES (?, ?, 1)
		 ON CONFLICT(key_id, day) DO UPDATE SET count = count + 1`,
		keyID, day)
	if err != nil {
		return fmt.Errorf("increment usage: %w", err)
	}
	return nil
}

// Close closes the underlying database.
func (s *Store) Close() error { return s.db.Close() }

// ErrNotFound is returned when no key matches the lookup.
var ErrNotFound = errors.New("key not found")

// KeyMeta is the metadata view returned to admin listings (no hash).
type KeyMeta struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	CreatedAt int64  `json:"created_at"`
	Revoked   bool   `json:"revoked"`
	QuotaRPM  int    `json:"quota_rpm"`
	QuotaDaily int   `json:"quota_daily"`
}