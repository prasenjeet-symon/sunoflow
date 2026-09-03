# Suno Answer — Research Ledger

*Open questions and doubts, collected 2026-09-03. Nothing here is decided; this file is the working
scratchpad for the research phase. Decisions graduate from here into an architecture doc later.*

## What we know so far (from the developer, 2026-09-03)

- **Suno Answer is a separate feature**, not an extension of dictation cleanup. Its own hotkey.
- Flow: press hotkey → speak a query (dictation) → send to the model **with**:
  1. **Screen content as a screenshot** (not OCR words — the image itself goes to the model),
  2. **Extra context about the current user** — e.g. their **LinkedIn ID**, **dictionary entries**,
- Result appears in a **small pop-up chat anchored at the cursor position**.
- Underlying research done 2026-09-03 (prior conversation): recommendation was Gemini native
  `google_search` grounding as the v1 search tool ($14/1k per search query, 5k free grounded
  prompts/mo on 3.x, zero new vendor), additive route on the cleanup gateway reusing auth/lease/
  analytics, separate ~4MB body cap + 60s timeout + smaller quota bucket.

## Answers recorded (2026-09-03, second round)

| Ref | Answer |
|-----|--------|
| A1 | **Multi-turn chat.** The popup is a real conversation with follow-ups, not a one-shot card. A2 (persistence), A4 (focusable panel) and F3 (per-turn cost) are now live questions, not hypotheticals. |
| B1/B4 | **The dictionary context is the existing corrections dictionary** — verified in source. `sidecars/shared/corrections.py`: `Corrections` persists `{from,to,count,kind}` (`kind` ∈ correction\|expansion, inferred for old files); `relevant_for(text, limit=40)` (:283) sends only entries whose text matches the transcript — corrections matched literally, expansions on distinctive tokens — capped at 40, expansions first. Gateway side (`cleanup-gateway/internal/cleanup/cleanup.go`): `NormalizeDict` (:231) trims/caps at 64, `dictionarySection` (:261) renders the `[DICTIONARY]` block as SPELLINGS (mishearing→written form) and SHORTHAND (spoken→value) sections. The file itself never leaves the machine; only matched entries ride along. **For Suno Answer the same file is the source, but the matcher must run against the *query* instead of a dictation transcript** — the 40/64 cap machinery carries over unchanged. **B1 partially resolved:** the "LinkedIn ID" already exists in this model as a user-added *expansion* — Settings copy ("Save your Instagram or LinkedIn link once…", `SettingsView.swift:1678`, `SettingsForm.cs:1630`) and `sidecar/corrections.json:9` (`my linkedin` → `https://www.linkedin.com/in/prasenjeet-kumar-0b160384/`, kind=expansion). Expansions are precisely the URL/handle/email values (`_VALUE_LIKE` in corrections.py:45). So "LinkedIn ID" may just be an instance of the dictionary, not net-new. Residual doubt: if the developer meant a *separate account-level profile field* captured at onboarding, that is still net-new — confirm which. |
| B2 | User context is **passed back to the server per request** (developer-confirmed). Gateway stays stateless, matching the cleanup design. |
| B3 | The cap exists (40 sidecar / 64 gateway) and the selection logic exists — the open bit narrows to adapting `relevant_for`'s matching basis from transcript to query. |
| D5 | **Paid feature, limit-based**: message caps **configurable per user**, with a default configuration per plan. Per-message counts (not per-search-count quotas) are the user-facing limit; the gateway quota bucket then backstops the actual cost ceiling (fan-out etc.). |
| E1/E2 | **Consent flow resolved**: show the user what will be sent and ask consent **before** Suno Answer is enabled — default OFF. E1's capture-scope question (full display vs active window) stays open as a technical matter, but consent no longer blocks proceeding. |

## Answers recorded (2026-09-03, third round)

| Ref | Answer |
|-----|--------|
| A4 | **The popup is focusable — typed follow-ups are in.** The answer chat panel takes key focus so follow-ups can be entered two ways: typed into the popup (built-in CTA) or dictated via the hotkey. The non-activating-overlay rule still governs the dictation pill; the answer panel is deliberately a different window class that is allowed to activate. Residual: does the panel take focus the moment it appears, or only click-to-focus — decide in the G2 prototype. |
| A9 / F3 | **The screenshot is sent once per chat session.** Once the popup appears the screen is frozen: capture happens once at session start and rides the first turn only. Follow-ups do **not** re-send it — they carry text history only (the gateway stays stateless, so the model's memory of the screen is the turn-1 answer inside the history text). Dismissing the bubble ends the session; the next hotkey press starts over with a fresh capture. Multi-turn therefore multiplies text tokens, not image tokens — the ~5× cost fear doesn't materialize. Implication: on follow-up turns the client drops the image from the history it re-sends; the model cannot "re-look" at the screen mid-session. |

## Answers recorded (2026-09-03, fourth round — batch 1, product/UX)

| Ref | Answer |
|-----|--------|
| A2 | **Ephemeral.** "Once the popup dismisses, everything is gone." History lives in memory for the life of one popup session only — no persistence, no on-disk privacy surface, no history browser, no clear-history control needed. |
| A3 | **Mouse cursor.** The popup anchors at the mouse pointer (not the text caret — no AX work), clamped to screen edges like the pill already does. |
| A5 | **Insertion is in scope.** The answer can go into the focused app: copy + "insert at cursor" — hide popup → refocus last app → pasteboard + Cmd+V via the existing dictation insertion path (`TextInjector`). Accepted trade-off: insertion clobbers the clipboard. |
| A6 | **Developer delegated the choice → default ⌃⌥Space, default OFF.** No collision with dictation or tone (⌥⇧Space / fallback ⌘⇧Space); enabling runs through the consent flow (E1/E2), so there is no default-ON exposure. Machinery: `HotkeyManager(id: 3)` + `DefaultAnswerHotkey.fallback*` (pattern copied from the tone hotkey); fallback combo ⌘⌥Space (⌃⌘Space is macOS's emoji picker — avoid). |
| A7 | **Totally distinct visual: an animated "magic bubble".** Not the dictation pill — own geometry, own chrome, with a magical bubble-like animation while recording (and likely while waiting for the answer). New overlay window class; exact look/feel settled in the G2 prototype. |
| A8 | **Mutually exclusive, one at a time.** Starting one cancels the other — Answer hotkey mid-dictation cancels dictation; dictation hotkey mid-Answer cancels (and aborts) Answer. Deliberate developer-made exception to the "dictation never blocks" house rule: the two contend for the mic and the state machine stays trivial. Implication accepted: starting a dictation aborts a paid in-flight grounded request. |
| A10 | **Dismiss = click-outside or re-pressing the same Answer hotkey (toggle).** Dismissal ends the session (consistent with A2/A9): an in-flight request is **aborted**, not silently finished — no orphaned quota spend, no stale popup reappearing. Esc/X are natural additions; confirm in G2. |

Still open after this round: B1 (LinkedIn residual), A11, B5, C1–C6, D1–D4, D6–D11, E1, E3–E7, F1, F2, F4, G1–G3.

### C2 live check (2026-09-03, docs research)

`gemini-3.5-flash-lite` **supports image input (GA)** and **`google_search` grounding ("Search as a tool: Yes")** on the same tier — model card + product page confirm both. Caveats found: (1) flash-lite defaults to `minimal` thinking — grounded answers likely need thinking raised above the default; (2) **per-search-query pricing is not published in the docs surfaced** — only token pricing ($0.30/$2.50 per 1M). The $14/1k-per-search figure in F1 came from the earlier pricing research and remains the working number, but it must be re-verified against current docs (or measured from a real bill) before launch. Residual decision (batch 2): stick with flash-lite vs a larger model for answer quality, and the thinking level.

## Answers recorded (2026-09-03, fifth round — batch 2, backend / architecture / scope)

| Ref | Answer |
|-----|--------|
| C2 | **Config-split: server-side `RESEARCH_MODEL` env, default `gemini-3.5-flash-lite`.** The answer model can be swapped/upgraded without client changes; default runs flash-lite with thinking at low (the cleanup prompt already runs `thinkingLevel: low`). |
| C3 + D10 | **Streaming from day one (SSE).** Developer chose streaming over non-streaming-first: "better user experience, properly communicating to the user." Gateway `POST /answer` returns a stream backed by Gemini `:streamGenerateContent`; the sidecar proxies the stream; the magic bubble hands off to progressive answer text. Consequences: D3's single-response 60s deadline becomes a **stream deadline** (proposal: ~90s total, TTFB soft target ~15s — confirm in batch 4); quota counts a message **when its stream starts** — an aborted in-flight grounded request has already spent tokens, so A10's "no orphaned quota spend" is aspirational; the attempt still bills. |
| D1 | **`POST /answer`.** Product name wins; the internal Go package may stay `internal/research`. |
| D5 | **Default 50 messages/day, gateway hard cap 100/day** per account (per-user caps stay configurable per the earlier D5 answer); the proposed 5 rpm stands unless changed. Paid-plan only stands. |
| A11 | **macOS only for v1.** Windows follows later; no WinForms screenshot/popup rework in this track. |
| E1 | **Full-display capture** — same proven path as `ScreenContext.captureAndRecognize` (minus OCR: the image itself is the payload). Exposure is handled by consent + paid-tier keys, not by narrowing the capture. |
| B1 + B5 | **Dictionary expansions only.** No net-new account-level profile field; "my linkedin"-style expansions already resolve profile data when the query mentions it. B5 unchanged: cleanup is untouched — the dictionary is the only way to capture manual context, and Suno Answer reads from it. |

Still open after this round: C1 (confirm grounding as assumed), C4, C5, C6, B3, B6, D2–D4, D6–D9, D11 (confirm cannot-re-look is accepted), E3–E7, F1, F2, G1–G3.

## Answers recorded (2026-09-03, sixth round — batch 3, error UX / mechanics / sequencing)

| Ref | Answer |
|-----|--------|
| D6 | **Separate seam; cleanup's `Backend` untouched.** A distinct backend interface for answers (name tracks the package per D1 — `internal/research`), implemented by Gemini alongside `Cleanup`. No generic `[]Part{Text\|Image}` contract for a hypothetical Serper swap — cleanup and answer share nothing textually (prompts, multimodal parts, streaming, grounding metadata), and the swap, if it ever happens, lives entirely inside the answer package either way. |
| D2 | **Per-route body caps.** `/cleanup` keeps its tight 1MB; `/answer` gets a per-route `MaxBytesReader` of 4MB. The mandatory-downscale idea is adopted as **client policy, not a server rule**: capture downscales to ~1600px max edge before upload — a 1600px JPEG @0.55 is ~200–400KB (~550KB base64), so 4MB leaves generous Retina headroom while the edge nginx limit stays meaningful. |
| D4 | **Inline error card + "Try again"** (re-sends the identical turn — the turn-1 image is still on the client, so retry is cheap). Error taxonomy with plain copy: `unavailable` (network/gateway), `timed out`, `limit reached — resets tomorrow` (quota), `unable to answer` (model refusal). No raw fallback, ever — a non-grounded guess is hallucination. |
| D7 | **Framing only for v1.** The server-owned prompt declares screen text and web results as untrusted data (same posture as cleanup's `[SCREEN — reference only]`). Mechanical guards (cap web-result length, strip instruction patterns) are deferred and only promoted if analytics or testing shows real injection attempts — stripping is brittle and mangles legitimate content. Blast radius of a successful injection stays "a wrong answer in a popup" — never executed, never inserted without the user clicking. |
| D9 | **Field list confirmed, plus two additions:** `error_code` (feeds the D4 taxonomy) and `aborted_at_ms` (where in the stream the user gave up — the cheapest honest measure of whether streaming actually helps). Full set: `latency_ttfb_ms`, `latency_total_ms`, `had_image`, `turn_index`, `query_length`, `source_count`, `search_queries`, `outcome` (`ok\|timeout\|error\|aborted`), `model`, `error_code`, `aborted_at_ms`. Still zero transcript content. |
| C6 | **Sources visible: compact chips under each answer** — 2–4 clickable domains (trust + lets the user verify). Grounded answers without visible sources read as confident hallucination. Affects the G2 prototype and the response payload shape (grounding metadata must ride the stream), so settled now. |
| G1–G3 | **G2 popup prototype FIRST**, with a stubbed streaming response and the real hotkey/capture/insertion machinery; then the gateway route (grounding proven end-to-end via curl) → sidecar proxy → Swift wiring. The popup is the riskiest unknown (focus, dismissal, streaming UI, insertion) and prototypes are free; G3's smallest slice falls out naturally: single-turn, no user context, sources on. |

**Parked non-decisions (2026-09-03):** **C4/C5** — v1 ships always-grounded with prompt steering ("prefer one well-formed search"); analytics measures real fan-out before any gate gets built. **B3** — reuse the existing `relevant_for` machinery keyed on the *query*, capped like cleanup (40 sidecar / 64 gateway).

Still open after this round: B6 (PII consent surface wording), D3 (stream deadline numbers — ~90s total / ~15s TTFB proposed, confirm in batch 4), D8 (context assembly: sidecar reads corrections itself and matches on the query — confirm field shape), D11 (accept the model cannot re-look mid-session), E3–E7 (paid-tier keys, metadata-logging audit, retention), F1 (re-verify per-search pricing), F2 (confirm image-token budget with real screenshots), F4 (quota math vs. paid price), G2 residuals (focus-on-appear vs click-to-focus; Esc/X dismissal).

---

## A. Product / UX questions

| # | Question | Doubt / tension |
|---|----------|-----------------|
| A1 | **One-shot or multi-turn chat?** Is the popup a single Q&A card, or a real conversation with follow-ups? | "Pop-up chat" implies multi-turn. Multi-turn ⇒ state (where does history live?), cost per follow-up, and a text input in the popup. Single-turn is far cheaper and simpler. |
| A2 | **Does chat history persist?** Per-hotkey-press session only, app lifetime, or across days? | If persistent, storage location (client-only? sidecar? Firestore?) and privacy posture change materially. |
| A3 | **Which "cursor" anchors the popup — mouse pointer or text caret?** | Dictation pill anchors near the caret via AX; caret can be hard to get in every app. Mouse pointer is trivial but may be far from where the user is looking. |
| A4 | **Can the user type follow-ups in the popup?** | If yes, the panel must become key-focusable → it *activates*, stealing focus from the app the user was working in. Our whole overlay philosophy so far is `NSPanel` non-activating. This is a real UX conflict to resolve (e.g. click-to-focus, or voice-only follow-ups). |
| A5 | **Does the answer ever get inserted into the focused app** (copy button, "insert at cursor"), or is it purely read-in-popup? | Insertion reuses the pasteboard+CmdV machinery but risks clobbering the user's clipboard; also unclear if wanted given "chat" framing. |
| A6 | **What is the hotkey?** Same machinery as the tone hotkey (`HotkeyManager(id: 3)`) — default combo, default ON or OFF? | Tone hotkey shipped default-OFF after the Fn saga. A third global hotkey increases collision odds; needs a default + collision fallback (pattern exists: `DefaultToneHotkey.fallback*`). |
| A7 | **Recording UX**: same pill overlay as dictation, or a distinct visual? | Reusing the pill is cheap but may confuse "am I dictating or asking?". |
| A8 | **Can dictation and Suno Answer run concurrently?** What happens if the dictation hotkey fires mid-research? | Dictation must never be blocked (house rule). Need explicit state-machine rules in `AppDelegate`. |
| A9 | **Screenshot timing**: captured once at hotkey press, or refreshed for each follow-up? | Follow-ups about a changed screen would need re-capture; each capture is another image token cost + privacy exposure. |
| A10 | **Dismissal**: Esc? click-away? auto-timeout? Does an in-flight request cancel on dismiss? | Cancellation semantics for an in-flight 5–30s grounded request need defining. |
| A11 | **Windows parity**: does Suno Answer ship on Windows in v1 of the feature, or macOS first? | Windows has no tone support today; screen-capture + popup overlay would need WinForms equivalents. |

## B. User-context questions (LinkedIn ID, dictionary)

| # | Question | Doubt / tension |
|---|----------|-----------------|
| B1 | **What exactly is the "LinkedIn ID"?** A profile URL/username stored in account settings? Where is it captured — onboarding, settings, the website? | I don't know of any LinkedIn field in the current account model (`AccountManager`, Firestore pairing). This is net-new data. |
| B2 | **Is user context sent on every request, or cached server-side?** | Sending per-request keeps the server stateless (matches cleanup design); caching server-side means PII lands in our infra. Default per-request. |
| B3 | **Which dictionary entries go in — the whole `corrections.json`, or a capped subset?** | The corrections file can be large; prompt-bloat vs usefulness. Probably cap (e.g. top-N by count, or ≤ 2k chars). |
| B4 | **Is the dictionary context the *corrections* dictionary (user's vocabulary fixes) or a user-curated "about me" dictionary?** | Two different things; the former exists, the latter is new. |
| B5 | **Does user context also apply to cleanup**, or strictly to Suno Answer? | If cleanup benefits too, the context assembly belongs in shared sidecar code; if not, keep it isolated. |
| B6 | **PII posture**: LinkedIn ID is PII. Does it ride through the gateway (metadata-only logging must hold), and is the user told? | Consent surface needed: one toggle "personalize answers with my profile & dictionary"? |

## C. Search / model questions

| # | Question | Doubt / tension |
|---|----------|-----------------|
| C1 | Confirm **Gemini `google_search` grounding** as v1 (vs Serper/Tavily/Brave loop). | Prior research still stands, but the popup-chat framing may want *faster* answers → fewer searches → maybe one well-formed search steered via prompt. |
| C2 | **Which model?** `gemini-3.5-flash-lite` with grounding (same as cleanup), or a config-split `RESEARCH_MODEL`? | Split costs nothing and lets us upgrade synthesis independently. Also: does flash-lite handle multimodal (image) + grounding equally well? Needs a live check. |
| C3 | **Thinking budget / latency**: grounded requests legitimately take 5–30s. Is that acceptable for a popup? | If not, options: streaming (SSE), "searching…" progressive UI, or skipping grounding for queries that don't need it. |
| C4 | **Search gating**: does every Suno Answer call pay for search even when the answer needs none (pure screen-reading, pure rephrasing)? | Cost waste; possible heuristic gate (model decides `tools` per call) or two-tier prompt. Unclear if we can reliably detect "no search needed" cheaply. |
| C5 | **Fan-out control**: 3.x bills per search query executed, and there's no hard cap knob. | Steer via prompt ("prefer one well-formed search"), measure actual fan-out in analytics, revisit if P50 fan-out > 2. |
| C6 | **Source rendering**: do we show sources/citations in the popup? Grounding returns `sources[]` + query count. | Almost certainly yes (trust), but affects popup design + response payload shape. |

## D. Architecture questions (additive route on cleanup-gateway)

| # | Question | Doubt / tension |
|---|----------|-----------------|
| D1 | New `POST /research` (or `/answer`?) on the gateway reusing `account.Middleware` (device key + lease). Name it? | Cosmetic but settles payload/docs. |
| D2 | **Body cap**: current `MaxBytesReader` is 1MB (`server.go:172`); screenshots need ~4MB. Confirm the size, and whether the cap is per-route. | One shared cap can't serve both routes; need route-specific limits. |
| D3 | **Timeout**: dedicated 60s client/timeout for this route, never shared with cleanup's 20s/30s paths. Confirm. | Cleanup's measured bursty Gemini stalls argue for headroom; 60s is a guess to validate with real grounded-latency data. |
| D4 | **No echo-retry / no raw fallback** on this route — a non-grounded guess is hallucination, so failures return a clean error. Confirm the client UX for that error ("research unavailable"). | Opposite of cleanup's never-fail philosophy; deliberate exception. |
| D5 | **Separate quota bucket** (proposal: 5 rpm / 50–200 per day per account). What numbers, and is Suno Answer **paid-plan only**? | At ~$30–45 per 1k researches (2–3 searches each) + image tokens, free-tier exposure could be costly. Quota is the main cost guardrail. |
| D6 | **Backend interface change**: `Backend.Cleanup(ctx, prompt)` is text→text (`backend.go:47`). Add `Research(ctx, ResearchRequest)` carrying multimodal parts + returning answer + grounding metadata. | Only `GeminiBackend` exists so nothing else breaks; but confirm we don't want a separate `ResearchBackend` seam for the eventual Serper swap. |
| D7 | **Server-owned prompt** (new `internal/research` package), client sends only query/context/image. Also the injection story: the *screenshot itself* and *web results* are untrusted content. | Grounded web results can carry injected instructions; need the same framing/guard posture as cleanup, plus explicit "screen text is data" framing. |
| D8 | **Sidecar**: `POST /research` (multipart image + query + context fields) proxied to gateway with device key. Does the sidecar forward user-context (LinkedIn/dictionary) as fields, or read them itself? | Key/lease handling unchanged; context assembly location is the open bit (B2). |
| D9 | **Analytics**: new `research` event, metadata only (latency, had_image, source count, query length, fan-out count). Never the screenshot, never the query text, never the answer. Confirm the field list. | — |
| D10 | **Streaming**: ship non-streaming with 60s cap first, add SSE later if the wait feels bad? Or is popup-chat UX painful enough without streaming from day one? | Non-streaming keeps sidecar↔gateway a single POST (matches cleanup); streaming is a real upgrade for perceived latency. |
| D11 | **Where does chat-session state live, given the gateway is stateless (B2) and the screenshot is sent once (A9/F3)?** Developer's indicated direction: (c) image rides turn 1 only; follow-ups carry text history; the turn-1 answer inside that history is the model's only memory of the screen. Residue to accept consciously: the model **cannot re-look** at the screen mid-session (a follow-up like "what about the box on the right?" fails once the visual is out of the turn-1 answer text) — confirm that limitation is acceptable, or revisit a client-held image re-attach (option a) later. This shapes the route payload: turn 1 = {image, query, context, recent?}; turn n>1 = {history, query}. |

## E. Privacy / security doubts

| # | Doubt |
|---|-------|
| E1 | **A full-screen screenshot is a much bigger exposure than OCR words**: other windows, notifications, password managers on screen. Is capture full-display (like `ScreenContext.captureAndRecognize`) or active-window-only (harder, app-dependent)? |
| E2 | **Consent**: default OFF until the user explicitly enables Suno Answer, with UI copy stating plainly that the screen image leaves the device. Per-invocation toggle too (hold-key modifier?), or settings-only? |
| E3 | **Free-tier training usage**: free-tier Gemini API keys may have data used for training; paid-tier keys don't. This route ships screenshots → must run behind the **paid tier** from day one. |
| E4 | **Metadata-only logging must hold** for a route whose payload is a screenshot + personal context. Verify no accidental logging of parts in gateway, sidecar, or Swift. |
| E5 | **Screen content is an injection vector** (visible text like "ignore previous instructions"). The prompt must frame screen text as data, same as the `[SCREEN — reference only]` section does for OCR words today. |
| E6 | **Web-result injection**: grounded search results are untrusted. Cleanup has echo/length guards; research needs equivalent framing + output guards. |
| E7 | **Retention**: does Google retain grounded prompts? Do we? Currently we log metadata only and keep nothing; confirm the same for Suno Answer (no transcript/screenshot persistence anywhere). |

## F. Cost doubts

| # | Doubt |
|---|-------|
| F1 | Grounding: $14/1k **per search query** on 3.x (fan-out multiplies); 5k free grounded prompts/mo shared across 3.x family. Actual per-request cost = searches×$0.014 + tokens. Needs a real measurement, not an estimate. |
| F2 | Image tokens: ~258 tokens per 768px tile; a 1280×800 screenshot ≈ 1–1.5k tokens (pennies). But Swift capture→JPEG(~0.55, ~1280px max edge)→base64 inflates ~1.37×; ~100–250KB typical. Confirm the budget with real screenshots. |
| F3 | Multi-turn chat multiplies everything: does each follow-up re-send the screenshot + user context? If yes, a 5-turn chat costs ~5×. Context-reuse or drop-image-on-follow-up policy needed. |
| F4 | Quota math: 50/day/account worst case ≈ $10–15/active user/mo. Acceptable only behind paid plan (D5). |

## G. Sequencing questions

| # | Question |
|---|----------|
| G1 | Build order assumed: gateway route + grounding backend → sidecar proxy → Swift capture/entry/popup. Still right with the chat-popup framing? |
| G2 | Can we prototype the popup chat (Swift `NSPanel` focusable, typing, dismissal) *before* any gateway work, using a stubbed response? De-risks the hardest unknown (A4, A1) cheaply. |
| G3 | What's the smallest end-to-end slice that proves value: dictate → screenshot → grounded answer in popup, single-turn, no user context? User context (B) and multi-turn (A1) layered after? |