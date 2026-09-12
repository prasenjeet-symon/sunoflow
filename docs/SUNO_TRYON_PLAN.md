# Suno Try-on — Plan

*Status: plan (2026-09-12), not yet built. Branch `feature/suno-tryon`. Nothing deployed — no VPS changes in this feature until explicitly requested.*

## What it is

While browsing a shopping site, the user asks Suno Answer "how would this look on
me?" and gets a generated image: **their** person photo wearing the item visible
on screen. It rides the existing Suno Answer flow end to end — same hotkey, same
popup, same STT — with the answer model deciding when a query is a try-on request
and handing off to a new image-generation capability.

Two inputs are needed:

1. **The garment** — already captured: the per-turn screen screenshot Answer
   takes today.
2. **The person** — a photo of the user, set once in Settings and stored on the
   Mac. Never uploaded except with an explicit try-on request.

## Intent routing (the core design decision)

No new hotkey and no new mode. The user talks to Suno Answer as usual; the
**answer model is the intent engine** (it already sees the query + screenshot).
When the query is about wearing the item on screen, it leads its reply with a
`[[TRYON]]` directive; the gateway translates that into an SSE event and keeps
streaming the rest of the sentence as normal deltas (the "Let me put that on
you…" ack). The app, on seeing the `tryon` SSE event, fires the image request.

Why not app-side classification: it would add a serial model call before the
answer stream; the answer model already has everything it needs. Why not a
separate hotkey/mode: invisible feature, users won't discover it. Why not inside
`/answer`'s stream doing generation: image gen is a different model, deadline,
quota, and response shape (binary, not SSE text) — it gets its own route.

Capability gating: the app sends a `tryon: true/false` flag on the `/answer`
request (true when a person photo is on file). The prompt only offers the
directive when the device can actually fulfill it — no ack-then-failure.

Wire protocol inside the answer stream:

- Model writes `[[TRYON]] <item description>` as the first line, then the ack
  sentence as normal text.
- Gateway `answer.go` holds back the first line until `\n` (or ~120 chars) to
  see whether it starts with the marker; if yes it emits
  `event: tryon {"item": "…", "ack": null}` and streams the remainder as
  regular `delta` events; if no marker, the buffered line flushes as deltas and
  nothing changes. Temperature 0 + "lead with it" instruction makes
  stream-start detection reliable; mid-stream markers are also handled by the
  same line buffer.

## Gateway (Go, `cleanup-gateway/`)

Same seams pattern as answer/control:

- `internal/config/config.go`: `TRYON_MODEL` (default `gemini-3.1-flash-image`,
  GA nano banana 2), `TRYON_TIMEOUT` (60s), `TRYON_QUOTA_RPM` (3) /
  `TRYON_QUOTA_DAILY` (30) / `TRYON_QUOTA_HARD` (60) — conservative, image gen
  costs ~$0.034–0.067/image; env-tunable like every other quota.
- `internal/tryon/`: prompt package, mirroring `internal/research` for answer.
  `BuildPrompt(item string) string` — server-owned instruction (client never
  sends the prompt): person = first image, garment = from the second image (the
  screenshot), preserve face/hair/body/skin tone exactly, natural fit and drape,
  plain neutral background, front-facing. Item description comes from the answer
  model, plus the raw user query as context.
- `internal/backend/backend.go`: `TryonBackend` interface
  `{ TryOn(ctx, TryonRequest) (TryonResult, error) }` with
  `TryonRequest{Item, Instruction string, PersonJPEG, GarmentJPEG []byte}`,
  `TryonResult{Image []byte, MIME string, Note string, Usage Usage}`. Route
  returns 501 when the backend doesn't implement it (existing pattern).
- `internal/backend/gemini.go`: `TryOn` via a one-shot `generateContent`
  (shares `callOneShotRaw`'s wire types): contents = [person inline_data,
  garment inline_data, text part], `generationConfig.responseModalities:
  ["TEXT","IMAGE"]`. Parse candidate parts for `inlineData` → base64-decode.
  `tryonModel()` = `TRYON_MODEL || Model` (mirrors `answerModel()`).
- `internal/server/tryon.go`: `POST /tryon`, JSON body
  `{instruction, item, person (b64), garment (b64)}`, body cap 12MB, per-image
  cap 3MB (`decodeImage` reused). Response is plain JSON
  `{image (b64), mime, note}` — **not SSE** (a single image needs no stream).
  Statuses: 401 missing/invalid key, 402 not entitled, 429 limiter (Retry-After),
  502 unavailable/blocked, 400 malformed. Analytics event `tryon` (latency,
  outcome, usage, image sizes — metadata only).
- `internal/ratelimit`: `NewTryon` (copy of `NewAnswer`/`NewControl` shape).
- `internal/server/server.go`: 6th limiter param on `NewMux` (all test call
  sites gain a `nil`), `TryonModel` field on `Server` (analytics-only naming).
- `internal/research/research.go`: `AnswerPrompt.TryonAvailable bool` +
  framing line in `BuildAnswerPrompt` describing the directive and when to use
  it (item visible on screen + question is about wearing it — NOT price/reviews/
  sizing/availability questions) + the `tryon` capability flag on
  `answerRequest`.

## Sidecar (Python)

- `sidecars/shared/tryon.py` + `/tryon` routes in `sidecars/shared/app.py` and
  `sidecar/server.py` (mirror parity — tests enforce it). Multipart
  `instruction, item, person, garment` + `X-SunoFlow-Device-Key` header;
  applies corrections to the item text; caps (instruction 500 chars, 3MB per
  image); streams the gateway's JSON response back verbatim with the gateway's
  status (402/429/502 mapping mirrors `stream_answer`).
- `/answer` route + `stream_answer`: pass the new `tryon` multipart flag
  through; the `tryon` SSE event passes through untouched (it is just an event
  in the SSE pipe — `_pump` is already a passthrough).
- New pooled session `_tryon_session` + keepalive ping (same pattern as
  `_answer_session`), timeout ~70s (gateway 60s + margin).

## Swift app (macOS — Windows has no Answer client, so no Windows work)

- `PersonPhoto.swift` (new): stores a downscaled JPEG (max edge 1024, q0.85) at
  `Application Support/SunoFlow/person.jpg`; `save(data:)`, `load()`, `exists`,
  `wipe()`. Not in UserDefaults (binary blob); not synced anywhere.
- `TryonClient.swift` (new): multipart POST to sidecar `/tryon`, ~90s deadline,
  decode `{image, mime, note}` → `NSImage`; error enum mirrors
  `AnswerError` (notEntitled/limit/timeout/unavailable/blocked).
- `AnswerClient.swift`: new `.tryon(item: String)` event case; `Request` gains
  `tryonAvailable: Bool` (multipart field `tryon`).
- `AnswerFlow.swift`: on `.tryon` — if person photo exists, run the try-on with
  garment = this turn's screenshot (already captured, no recapture) + person
  photo; show a generating card, then the image. If no photo, show a setup card
  ("Add a photo of yourself in Settings → Try-on") instead of calling /tryon.
  Uses the existing gen-guard + failure mapping (402 → `.sunoAnswerNotEntitled`).
- `AnswerPopup.swift` / panel view: image bubble — rounded card, aspect-fit
  NSImageView (max ~300pt tall), spinner state while generating, action row:
  **Copy** (pasteboard) + **Save** (NSSavePanel). No Insert (it's an image, not
  text).
- `Preferences.swift` / `SettingsView.swift`: new "Try-on" group — status row
  ("Ready — photo on file" / "Add a photo to enable try-on"), Choose Photo…
  / Remove buttons, privacy note ("Your photo stays on this Mac and is sent
  only to generate try-ons"). No toggle: presence of the photo IS the switch —
  with no photo the feature is fully dormant and Answer behaves exactly as
  today. No new hotkey.

## What the user sees

1. Hotkey → "hey Suno, how would this hoodie look on me?" (STT ~0.3s)
2. Answer panel opens; ack streams ("Let me put that on for you…") ~1.5s
3. Spinner card "Trying it on…" while image generates (~5–10s)
4. Image bubble appears with Copy / Save actions. Follow-up questions still work
   (history preserved; next turn re-routes normally).

Total added latency over today's answer: the image-gen call only, and the ack
streams while it runs.

## Privacy posture (consistent with the rest of the stack)

- Person photo: on-disk only, sent per-request to `/tryon` over HTTPS, never
  persisted server-side, never logged. Gateway/sidecar analytics carry sizes +
  latency + outcome only, never pixels or transcripts.
- The screenshot already rides `/answer` today under the same posture.

## Build order

1. Gateway: config → `internal/tryon` prompt → backend iface + gemini impl →
   `/tryon` route + limiter + NewMux 6th param + research directive → tests
   (`go build ./... && go test ./...`).
2. Sidecar: shared `tryon.py` + routes + `/answer` flag passthrough + mirror +
   tests (pytest, ~318 existing must stay green).
3. Swift: PersonPhoto + Settings group + client/flow/popup wiring
   (`swift build`).
4. Local E2E: gateway on :8099 (FIREBASE_PROJECT empty, admin-minted key) →
   sidecar passthrough → scripted app-side call with a real person + garment
   image pair. No deploy.

## Known risks / later levers

- **Garment grounding**: v1 sends the full screenshot + item text. If results
  are sloppy, v2 has the answer model emit a garment bbox in the tryon event and
  the app crops before calling /tryon (one more field, zero extra calls).
- **Refusals**: photorealistic person edits can hit Gemini block reasons —
  mapped to a `blocked` 502 and shown as a normal error card.
- **Latency tail**: pro-tier models are slower; we stay on flash-image. If
  quality disappoints, `TRYON_MODEL=gemini-3-pro-image` is a one-env flip.
- **Resolution/aspect**: default output (1K, model-chosen aspect) for v1;
  `imageConfig` (match_input / 2K) is a config lever if needed.
- **Cost**: ~$0.03–0.07/image; default daily quota 30 keeps worst case ~$2/day
  per account; tighten from live usage.