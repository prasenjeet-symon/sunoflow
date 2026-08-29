# Sidecar test data

Shared fixtures for the sidecar test suites. Platform-agnostic on purpose — the
Windows and macOS tracks run the same audio through different engines, and a
fixture that lived under one of them would quietly become that track's fixture.

## `dictation-smoke.wav`

3.5 s, 16 kHz mono 16-bit PCM. The clip the CI dictation smoke test
(`sidecars/windows/dictation_smoke.py`) transcribes to prove the STT engine
produces *words* and not merely a completed forward pass.

Spoken content:

> The quick brown fox jumps over the lazy dog near the river bank.

Regenerate with macOS `say` (the voice and rate matter — a different voice
changes what the model hears, so keep these if you re-record):

```
say -v Samantha -r 170 -o smoke.wav --data-format=LEI16@16000 --channels=1 \
  "The quick brown fox jumps over the lazy dog near the river bank."
```

then rewrite it through Python's `wave` module to drop the 4 KB of header
padding `say` emits, leaving a canonical 44-byte header.

**This is synthesised speech, not a human recording.** It is a regression gate —
"the decoder and vocab are wired up and the right words come out" — and nothing
more. It is not a transcription-accuracy benchmark, and a WER measured against
it would not describe any real user. Swapping in a real recording of a real
voice would strictly improve it; the assertion in the smoke test is a word-set
containment check precisely so that swap does not require rewriting the test.
