# SunoFlow Sidecar HTTP Contract

This document is the **single source of truth** for the HTTP API every SunoFlow
sidecar exposes on `127.0.0.1:8765`, and that every native client app
(macOS Swift, Windows C#) consumes. Both sidecar implementations —
`sidecars/mac` (parakeet-mlx) and `sidecars/windows` (onnxruntime-directml) — MUST
implement this contract identically. The native apps MUST consume it identically.

The contract is derived from the existing macOS sidecar (`sidecar/server.py`) and
Swift client (`TranscriptionClient.swift`). When the two disagree, the server's
actual JSON is authoritative and the doc says so.

---

## Transport

- Host: `127.0.0.1` (loopback only — never network-facing)
- Port: `8765`
- The sidecar is unauthenticated. The only secret (the cleanup-gateway API key)
  lives in the sidecar's process env, never sent to the client app.
- Content types:
  - `multipart/form-data` — `/transcribe` (file upload + form fields)
  - `application/x-www-form-urlencoded` — `/learn`, `/corrections/*`
  - JSON response bodies — every endpoint

---

## Endpoints

### `GET /health`

Lightweight liveness probe. The client polls this every ~3s for the menu-bar
status dot.

**Response 200** — `application/json`:
```json
{
  "status": "ok",
  "model_loaded": true,
  "model_present": true
}
```
| Field | Type | Meaning |
|---|---|---|
| `status` | string | Always `"ok"`. |
| `model_loaded` | bool | True iff the STT model is resident in memory and ready to transcribe. |
| `model_present` | bool | True iff all model files exist on disk (may be present but not yet loaded). |

The client treats HTTP 200 as "sidecar alive"; it does not inspect the fields for
the status dot (only for the Model tab).

---

### `POST /transcribe`

Transcribe a WAV clip, optionally clean it, apply learned corrections, and
remember the result for context continuity.

**Request** — `multipart/form-data`:

| Part name | Type | Required | Notes |
|---|---|---|---|
| `file` | binary (audio/wav) | yes | PCM WAV, 16 kHz, mono recommended. Filename conventionally `audio.wav`. |
| `context` | string | no (default `""`) | Accessibility context of the focused field (app/name/role). Sent to cleanup. |
| `screen` | string | no (default `""`) | OCR words from the screen (reference-only vocabulary). Sent to cleanup. |

**Headers**:
| Name | Required | Notes |
|---|---|---|
| `X-SunoFlow-Device-Key` | yes, in practice | `Bearer <device key>`. The app reads it from the platform credential store (macOS Keychain / Windows DPAPI) and sends it on **every** call. The sidecar strips the `Bearer ` prefix and forwards it to the cleanup gateway, which is where the account's trial and subscription are checked. Sent per request rather than held in the sidecar's environment so re-pairing takes effect with no restart. **A request without it is refused with 402** — an unpaired install, or anything posting to the port directly, gets no dictation. |

**Query**:
| Name | Type | Default | Notes |
|---|---|---|---|
| `cleanup` | bool | `true` | If `false`, skip the cleanup-gateway call and return raw STT text (corrections still applied). |

**Response 200** — `application/json`:
```json
{
  "raw": "hello world",
  "cleaned": "Hello world."
}
```
| Field | Type | Meaning |
|---|---|---|
| `raw` | string | Raw STT output, stripped. Empty string on any soft-fail (audio too short, model not loaded, transcription error). |
| `cleaned` | string | `raw` run through the cleanup gateway (if `cleanup=true`) and then `apply_corrections`. Equals `raw` when `cleanup=false`. Empty on soft-fail. |

**Response 402** — `application/json`. The one deliberate non-200:

```json
{
  "error": "not_entitled",
  "message": "Your free trial has ended. Activate your subscription to keep dictating."
}
```

Returned when the gateway refuses this device — expired trial, lapsed
subscription, disconnected device, unpaired install — or when the gateway
cannot be reached and no valid lease covers the gap. `message` is the gateway's
own wording and the app MUST show it verbatim rather than inventing its own, so
every surface explains a lapse the same way. Nothing is transcribed back and
nothing is pasted.

**Soft-fail contract (critical):** apart from that 402, `/transcribe` NEVER
returns a non-200 for a bad clip, a missing model, or a cleanup outage. It
returns HTTP 200 with `{"raw": "", "cleaned": ""}` so dictation degrades
gracefully instead of surfacing errors. The other non-200s are transport-level
(connection refused, malformed multipart) or a 500 from an unhandled server bug.

**Entitlement is not part of the soft-fail contract.** An expired account must
stop working, not quietly downgrade to a free tier. Both sidecars classify the
gateway's answer identically:

| Gateway says | Sidecar does |
|---|---|
| 2xx | Serve the dictation, and store the `lease` from the body. |
| 401 / 402 / 403 **with a JSON `error` body** | Hard stop: raise, return 402 to the app. This includes 401 — a revoked device and an unknown key are refusals, not outages. |
| 401 / 403 with a non-JSON body | An intermediary (a proxy), not us. Treat as an outage. |
| 429, 5xx, timeout, DNS failure | Outage. The stored lease decides: serve the raw transcript while a valid lease exists, else 402. |

**Pipeline order:**
1. Validate clip duration ≥ `MIN_AUDIO_SECONDS` (0.1s). Else → empty.
2. If `model is None` → empty (model not downloaded/loaded yet).
3. `model.transcribe(path)` → `raw_text`. On exception → empty.
4. If `cleanup=true`: POST `{text, context, recent, screen, dictionary}` to the
   cleanup gateway with the device key. `dictionary` is the subset of the user's
   entries that look relevant to *this* transcript (`relevant_for`) — the file
   itself never leaves the machine. A refusal → 402 (see the table above). An
   outage covered by a valid lease → fall back to `raw_text` (never fail
   dictation because cleanup is down). An outage with no valid lease → 402.
   If `cleanup=false`: call the gateway's `GET /entitlement` instead, applying
   exactly the same rules. Skipping it would make the cleanup toggle a
   free-dictation switch, because it is the only server call in the path.
5. `apply_corrections(cleaned_text)` — the `correction`-kind entries only,
   applied client-side of the gateway, longest-phrase-first, case-insensitive
   word-boundary replace. `expansion`-kind entries are **not** applied here:
   whether a spoken phrase means the speaker is *giving* a value or merely
   mentioning the thing is a judgement call, so the cleanup model makes it. A
   consequence worth knowing: with `cleanup=false` there is no model in the
   path, so expansions do not fire at all.
6. If `raw_text` non-empty: append `cleaned_text` to `recent_transcripts`
   (deque, maxlen 3) for next dictation's continuity context.
7. Return `{raw, cleaned}`.

`recent_transcripts` is in-process state (not per-client). It is sent to the
cleanup gateway as `recent[]` on the next `/transcribe`.

---

### `POST /learn`

Learn corrections from a user's manual edit of a pasted transcript.

**Request** — `application/x-www-form-urlencoded`:
| Field | Type | Required |
|---|---|---|
| `original` | string | yes |
| `edited` | string | yes |

**Response 200** — `application/json`:
```json
{
  "learned": [
    {"from": "Jon", "to": "John", "count": 3}
  ],
  "total": 12
}
```
| Field | Type | Meaning |
|---|---|---|
| `learned` | array<{from:string, to:string, count:int}> | Pairs learned from this edit. **No `key` field.** May be empty. |
| `total` | int | Total number of corrections now in the dictionary. |

> The Swift client decodes `learned` into a lighter `{from, to, count}` struct
> (`LearnedItem`) — the server sends no `key` field here, so decoding into
> `Correction` (which requires `key`) would fail silently and the learned count
> would always read 0. A Windows client should do the same.

Learning heuristics (in `shared/`):
- Word-level diff (`SequenceMatcher`) → keep only `replace` ops where both sides
  are 1–3 words (mishearing-like, not a rewrite).
- Character-similarity of normalized forms ≥ 0.5 (reject rewrites).
- `_worth_learning`: proper nouns / acronyms / digit-containing terms are safe;
  swaps involving `_COMMON_WORDS` are rejected.

---

### `GET /corrections`

List the full dictionary, sorted by normalized key.

**Response 200**:
```json
{
  "corrections": [
    {"key": "jon", "from": "Jon", "to": "John", "count": 3, "kind": "correction"},
    {"key": "my instagram", "from": "my Instagram", "to": "https://instagram.com/someone",
     "count": 0, "kind": "expansion"}
  ]
}
```
| Field | Type | Meaning |
|---|---|---|
| `corrections[].key` | string | Normalized "from" (`_norm_key`: strip + lower). |
| `corrections[].from` | string | Display "from" text. |
| `corrections[].to` | string | Replacement text. |
| `corrections[].count` | int | Times learned/seen. |
| `corrections[].kind` | string | `correction` or `expansion` — see below. |

**The two kinds.** They differ in *who applies them*, which is the only thing a
client needs to understand:

| Kind | What it is | Applied by |
|---|---|---|
| `correction` | A word the transcript mis-hears, paired with its correct spelling (`cavach` → `Kavach`). Learned from the user's edits, or added by hand. | The sidecar, mechanically, after cleanup — and the model, from the prompt. |
| `expansion` | A phrase the user says out loud, paired with the literal value it stands for (`my Instagram` → a profile URL). Added by hand. | The cleanup model only. Never blind-replaced: "I don't have an Instagram" must not sprout a URL. |

`kind` is absent from entries saved before it existed and is inferred on read
from the shape of the pair (a URL/handle/email/phone `to`, or one very unlike
its `from`, is an expansion). Old `corrections.json` files need no migration.

---

### `POST /corrections/add`

Manually add an entry from the Settings UI.

**Request** — `application/x-www-form-urlencoded`:
| Field | Type | Required | Notes |
|---|---|---|---|
| `frm` | string | yes | The "from" text. Named `frm` on the wire (not `from`) because `from` is a Python keyword and FastAPI would reject it as a parameter name. |
| `to` | string | yes | |
| `kind` | string | no | `correction` or `expansion`. Omitted or unrecognised → inferred from the pair. Clients that do not offer the choice should omit it. |

**Response 200**:
```json
{
  "added": true,
  "corrections": [ /* full list, same shape as GET /corrections */ ]
}
```
On blank-normalized `frm`: `{"added": false, "corrections": [...]}`. Preserves an
existing entry's `count` when the key already exists.

> The Swift client sends the field as `frm` (matching the wire name). A Windows
> client MUST do the same.

---

### `POST /corrections/update`

Edit an existing entry's from/to. Renormalizes the key.

**Request** — `application/x-www-form-urlencoded`:
| Field | Type | Required | Notes |
|---|---|---|---|
| `key` | string | yes | Current normalized key to find/replace. |
| `frm` | string | yes | New "from" text (named `frm` on the wire — see note above). |
| `to` | string | yes | New "to" text. |
| `kind` | string | no | As for `/corrections/add`. Omitted → re-inferred from the edited pair. |

**Response 200**:
```json
{
  "updated": true,
  "corrections": [ /* full list */ ]
}
```
On blank-normalized new `from`: restores the old entry and returns
`{"updated": false, "corrections": [...]}`.

---

### `POST /corrections/delete`

**Request** — `application/x-www-form-urlencoded`:
| Field | Type | Required |
|---|---|---|
| `key` | string | yes |

**Response 200**: `{"deleted": true}` or `{"deleted": false}`.

---

### `POST /corrections/clear`

**Request**: empty body.

**Response 200**: `{"cleared": true}`.

---

### `GET /model/status`

Report STT model presence, load state, and download progress.

**Response 200**:
```json
{
  "model_present": true,
  "model_loaded": true,
  "active": false,
  "phase": "idle",
  "current_file": "",
  "downloaded": 0,
  "file_total": 0,
  "overall_done": 0,
  "overall_total": 0,
  "error": "",
  "model_dir": "/Users/.../parakeet-tdt-0.6b-v3",
  "model_id": "mlx-community/parakeet-tdt-0.6b-v3"
}
```
| Field | Type | Meaning |
|---|---|---|
| `model_present` | bool | All model files on disk. |
| `model_loaded` | bool | Model resident in memory. |
| `active` | bool | A download is currently running. |
| `phase` | string | `idle` \| `downloading` \| `loading` \| `done` \| `error` |
| `current_file` | string | Filename being downloaded (empty when idle). |
| `downloaded` | int64 | Bytes downloaded for `current_file`. |
| `file_total` | int64 | Total bytes for `current_file`. |
| `overall_done` | int | Count of files completed in this download. |
| `overall_total` | int | Count of files in the model. |
| `error` | string | Last download error, empty if none. |
| `model_dir` | string | Absolute path to the on-disk model directory. |
| `model_id` | string | Source HF model id (for display). |

`model_id` and `model_dir` are platform-specific (mac shows the mlx-community id;
Windows shows the onnx export id). The client displays them read-only.

---

### `POST /model/download`

Start a background download of the STT model into `model_dir`. Returns
immediately; the client polls `/model/status` for progress.

**Request**: empty body.

**Response 200**:
```json
{"started": true}
```
or
```json
{"started": false, "reason": "already_running"}
```
or
```json
{"started": false, "reason": "already_present"}
```
When the download completes, the model is loaded in-process — no sidecar restart
needed. Idempotent: a no-op if a download is already running or the model is
already present and loaded.

---

## Shared behavior both sidecars MUST implement

These live in `sidecars/shared/` and are inherited, not re-implemented:

- **Personal dictionary** — `corrections.json` next to the sidecar, normalized
  keys, load/save, `_COMMON_WORDS`, `extract_correction_pairs`, `learn_from_edit`,
  `infer_kind`, `apply_corrections` (corrections only, longest-phrase-first,
  case-insensitive word boundary), and `relevant_for` (which entries ride along
  with a cleanup request).
- **Recent history** — `recent_transcripts` deque (maxlen 3), sent as `recent[]`
  to cleanup, appended after each successful transcription.
- **Cleanup gateway POST** — `clean_with_gateway(text, context, recent, screen, key, dictionary)`
  POSTs to `SUNOFLOW_CLEANUP_URL` (default
  `https://cleanup.mirrorli.art/cleanup`) with the caller's device key as the
  bearer token, 60s timeout. Soft-fails to raw text on an outage; raises
  `NotEntitled` on a refusal.
- **Entitlement probe** — `check_entitlement(key)` GETs `/entitlement` for the
  `cleanup=false` path, applying the same rules with no LLM call.
- **Offline lease** (`sidecars/shared/lease.py`) — every entitled response
  carries a signed token, stored under the platform data directory, that bounds
  how long a device keeps working while the gateway is unreachable (72h). It is
  what stops blocking the gateway's hostname from being unlimited free
  dictation. The wire format is shared with
  `cleanup-gateway/internal/account/lease.go` and pinned by a test vector on
  both sides.
- **WAV duration guard** — `_wav_duration_seconds`, skip clips < 0.1s.
- **FastAPI skeleton** — routes, lifespan, the `transcribe` pipeline orchestrator
  (the only thing the platform adapter plugs into).

## Platform adapter (the ONLY per-sidecar code)

Each sidecar implements the `SttAdapter` interface (`sidecars/shared/app.py`),
wired into the shared skeleton:

- `is_loaded() / is_present()` — model lifecycle state.
- `load()` — load the STT engine into memory; soft-fail (leave unloaded) on
  error so the sidecar still serves `/health` and `/model/status`.
- `transcribe_file(path: str) -> str` — run inference on a WAV path; return
  text. Must raise on failure — the shared app catches and soft-fails to empty.
- `status_snapshot() / start_download()` — the download manager.

macOS adapter (`sidecars/mac/adapter.py`):
`parakeet_mlx.from_pretrained(MODEL_DIR)` + `model.transcribe(path).text`. Model
source = `mlx-community/parakeet-tdt-0.6b-v3` (5 safetensors/tokenizer files).

Windows adapter (`sidecars/windows/adapter.py`): the `onnx-asr` package
(`istupakov/onnx-asr`) owns the **full** pipeline — log-mel preprocessor
(`nemo128.onnx`), Conformer encoder, TDT decoder/joint, and the TDT decoding
loop — on top of ONNX Runtime. We do **not** implement the decode loop ourselves
(NeMo's ONNX export only covers encoder+decoder; the preprocessor and TDT
decode are separate, which is exactly what `onnx-asr` provides). The adapter is:

```python
import onnx_asr
model = onnx_asr.load_model(
    "nemo-parakeet-tdt-0.6b-v3", path=MODEL_DIR,
    providers=["DmlExecutionProvider", "CPUExecutionProvider"],
)
text = model.recognize(wav_path)   # accepts a file path; resamples to 16k
```

- Execution provider: `DmlExecutionProvider` (DirectML, serves NVIDIA/AMD/Intel
  via DirectX 12) when available, else CPU (dev fallback only — production is
  GPU-mandatory). `onnxruntime-directml`, `onnxruntime-gpu`, and `onnxruntime`
  are mutually exclusive; the Windows sidecar installs `onnxruntime-directml`.
- Model source = `istupakov/parakeet-tdt-0.6b-v3-onnx` (6 files: encoder graph +
  ~2.4 GB external weights `.data`, decoder/joint, preprocessor, vocab, config).

## Model download

The download manager (file list, HF base URL, streaming, progress snapshot) is
**platform-specific** — the file manifests and download URLs differ between the
MLX snapshot and the ONNX export. It stays in each sidecar, not in `shared/`.
The `/model/status` and `/model/download` response *shapes* are identical
(documented above); only the file list and source URLs differ.

| | macOS | Windows |
|---|---|---|
| HF repo | `mlx-community/parakeet-tdt-0.6b-v3` | `istupakov/parakeet-tdt-0.6b-v3-onnx` |
| Files | 5 (safetensors + tokenizer + vocab + config) | 6 (encoder.onnx + .data + decoder_joint.onnx + nemo128.onnx preprocessor + vocab.txt + config.json) |
| `model_id` | `mlx-community/parakeet-tdt-0.6b-v3` | `istupakov/parakeet-tdt-0.6b-v3-onnx` |
| `model_dir` default | `~/Library/Application Support/SunoFlow/model` | `%LOCALAPPDATA%/SunoFlow/model` |
| Load | `parakeet_mlx.from_pretrained(MODEL_DIR)` | `onnx_asr.load_model(id, path=MODEL_DIR, providers=[Dml,...])` |
| Inference | `model.transcribe(path).text` | `model.recognize(path)` |