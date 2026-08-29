"""Parakeet TDT 0.6B ONNX STT adapter for Windows.

Wraps the ``onnx-asr`` package (istupakov/onnx-asr) behind the platform-agnostic
``SttAdapter`` interface. ``onnx-asr`` owns the full pipeline — log-mel
preprocessor, Conformer encoder, TDT decoder/joint, and the TDT decoding loop —
all as a single ``load_model`` + ``recognize`` call on top of ONNX Runtime. The
only heavy dependency is ``onnxruntime-directml`` (the DirectML execution
provider), which serves NVIDIA / AMD / Intel GPUs alike via DirectX 12 — this is
why we picked ONNX Runtime over NeMo for the Windows track (NeMo would have been
NVIDIA-only). No PyTorch, NeMo, or FFmpeg is needed.

The machine's hardware picks the model variant. A box with a DX12 GPU and room
for the weights gets the fp32 export on DirectML; anything else gets the int8
export on the CPU, which is what lets the sidecar run at all where there is no
usable GPU. The probe runs before the download, not at load time, because the
two variants are different files — see the variant table below.

The download manager pulls the ONNX export of Parakeet TDT 0.6B v3 from
``istupakov/parakeet-tdt-0.6b-v3-onnx``. ``onnx-asr`` can download it itself via
huggingface_hub, but we manage the download ourselves so the dashboard gets
byte-level progress (the contract's ``/model/status`` fields) and so the model
lands in our stable, app-owned directory — mirroring the macOS MLX adapter.
Once all files are present, ``load()`` resolves the model offline
(``offline=True`` + ``path=MODEL_DIR``) so there's no startup network call.

See ``docs/CONTRACT.md`` for the HTTP contract and ``sidecars/shared/app.py``
for the routes this adapter plugs into.
"""
import array
import math
import os
import re
import shutil
import tempfile
import threading
import time
import wave

from sidecars.shared.app import SttAdapter, create_app
from sidecars.shared.audio import wav_duration_seconds  # noqa: F401  (re-exported)

# --- onnx-asr (lazy import) ---------------------------------------------------
# ``onnx_asr`` imports ``onnxruntime`` at module load. We don't import it here so
# that ``import sidecars.windows.adapter`` works on any OS for tooling/tests;
# the real import happens in ``load()`` / ``transcribe_file()`` on the Windows
# host. ``onnxruntime`` itself exposes ``get_available_providers()`` which tells
# us whether DirectML is compiled in.

MODEL_ID = "nemo-parakeet-tdt-0.6b-v3"
HF_REPO = "istupakov/parakeet-tdt-0.6b-v3-onnx"

# --- Managed model directory ---------------------------------------------------
# %LOCALAPPDATA%/SunoFlow/model on Windows. Stable across reinstalls so a sidecar
# upgrade doesn't force a re-download. Override with SUNOFLOW_MODEL_DIR.
_DEFAULT_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
    "SunoFlow",
    "model",
)
MODEL_DIR = os.path.abspath(
    os.environ.get("SUNOFLOW_MODEL_DIR", _DEFAULT_DIR)
)

# --- Model variants ------------------------------------------------------------
# The repo ships the same model at two precisions, and which one a machine should
# run is a hardware question rather than a preference. It has to be answered
# BEFORE the download: the variants are different files, so a wrong answer is
# paid for in a second multi-gigabyte transfer, not in a reload.
#
# fp32 is the accuracy reference and wants a DX12 GPU with room for 2.4 GB of
# encoder weights. int8 is not merely "fp32 for weaker GPUs" — it is the CPU
# path. That export is dynamically quantized (DynamicQuantizeLinear +
# MatMulInteger), ops that exist to reach the CPU's VNNI/AVX integer kernels;
# DirectML's coverage of them is patchy enough that int8 on the GPU is routinely
# *slower* than fp32 once the per-run quantize/dequantize overhead is counted.
# So each variant carries its own execution providers and int8 is never paired
# with DirectML — see _select_providers.
#
# ``files`` are the names in the HF repo and ``bytes`` their published total.
# onnx-asr picks between them from ``quantization``: it globs
# ``encoder-model?int8.onnx`` for int8 and matches the literal
# ``encoder-model.onnx`` for fp32, so the two can share MODEL_DIR without
# colliding and a box that already has fp32 never has to re-fetch to keep it.
VARIANT_FP32 = "fp32"
VARIANT_INT8 = "int8"

VARIANTS = {
    VARIANT_FP32: {
        "files": [
            "config.json",
            "encoder-model.onnx",
            # The encoder graph is split: .onnx is the graph, .onnx.data is
            # ~2.4 GB of external weights. Both MUST be present or the session
            # fails to load. This is the easiest file to forget.
            "encoder-model.onnx.data",
            "decoder_joint-model.onnx",
            "nemo128.onnx",   # log-mel preprocessor
            "vocab.txt",
        ],
        "bytes": 2_550_000_000,
        "quantization": None,
        "label": "full precision",
    },
    VARIANT_INT8: {
        "files": [
            "config.json",
            # 652 MB — under the 2 GB protobuf ceiling, so unlike its fp32
            # counterpart this encoder has NO external .data sibling. Requiring
            # one here would make every int8 install look permanently incomplete.
            "encoder-model.int8.onnx",
            "decoder_joint-model.int8.onnx",
            "nemo128.onnx",
            "vocab.txt",
        ],
        "bytes": 671_000_000,
        "quantization": "int8",
        "label": "int8",
    },
}

#: The fp32 manifest under its historical name — the only variant this adapter
#: shipped before the int8 path existed.
MODEL_FILES = VARIANTS[VARIANT_FP32]["files"]
MODEL_BYTES_TOTAL = VARIANTS[VARIANT_FP32]["bytes"]

HF_BASE = f"https://huggingface.co/{HF_REPO}/resolve/main"

# Free space is checked before the first byte is fetched: discovering a full disk
# 2.3 GB into a 2.5 GB download wastes the transfer and leaves a half-written
# model behind — and a truncated external weights file loads cleanly, failing
# only on the first inference, which is the exact failure the preflight exists
# to prevent.
DISK_HEADROOM_BYTES = 300_000_000

# Dedicated VRAM below which we will not ask a GPU to hold 2.4 GB of encoder
# weights plus activations plus whatever the desktop compositor already owns.
# A judgement call rather than a measured cliff: 4 GB is tight but workable for
# the few seconds of audio a dictation produces, and under it DirectML starts
# paging over PCIe — slower than simply running int8 on the CPU.
MIN_VRAM_BYTES_FP32 = 4 * 1024 ** 3

# Display-adapter class key; each numbered subkey (0000, 0001, ...) is one
# adapter. Read instead of WMI — see _dedicated_vram_bytes.
_GPU_CLASS_KEY = (
    r"SYSTEM\CurrentControlSet\Control\Class"
    r"\{4d36e968-e325-11ce-bfc1-08002be10318}"
)

# Length of the clip pushed through the model to prove it can actually run.
# Comfortably longer than MIN_AUDIO_SECONDS and than the encoder's subsampling
# window, so the pass exercises the real path rather than an edge case.
SMOKE_SECONDS = 1.0


def _dedicated_vram_bytes():
    """Largest dedicated VRAM across installed display adapters, or None.

    Read from the driver's own registry entry rather than WMI. The obvious call,
    ``Win32_VideoController.AdapterRAM``, is a uint32 and therefore saturates at
    4 GB — precisely the range this decision turns on, so it would answer the
    one question being asked of it with a wrong number.
    ``HardwareInformation.qwMemorySize`` is the 64-bit value the driver reports.

    Returns None for "could not tell", which is not the same as zero and which
    the caller deliberately treats as a reason to be conservative. Taking the
    max across adapters is a simplification: on a laptop with switchable
    graphics it reports the discrete GPU, which is the one DirectML will want.
    """
    try:
        import winreg
    except ImportError:
        return None  # not Windows — dev box or CI
    best = None
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, _GPU_CLASS_KEY) as cls:
            subkeys = winreg.QueryInfoKey(cls)[0]
            for i in range(subkeys):
                try:
                    name = winreg.EnumKey(cls, i)
                except OSError:
                    continue
                if not name.isdigit():
                    continue  # skip Configuration/Properties siblings
                try:
                    with winreg.OpenKey(cls, name) as adapter:
                        value, _ = winreg.QueryValueEx(
                            adapter, "HardwareInformation.qwMemorySize"
                        )
                except OSError:
                    continue  # this adapter doesn't publish it; try the next
                if isinstance(value, int) and value > 0:
                    best = value if best is None else max(best, value)
    except OSError as exc:
        print(f"Could not read GPU memory from the registry: {exc}")
        return None
    return best


class ParakeetOnnxAdapter(SttAdapter):
    """Parakeet TDT 0.6B v3 ONNX engine + ONNX-export download manager."""

    def __init__(self):
        self.model = None
        # The compute path the loaded model was actually verified on, so the
        # dashboard can stop asserting "GPU" on a box that quietly fell back.
        self._runtime = ""
        # Which variant is loaded, and how fast it proved to be. The smoke pass
        # in load() already runs a clip of known length, so timing it costs
        # nothing and turns a spec-sheet guess into a measurement of the machine
        # actually in front of us.
        self._variant = ""
        self._rtf = 0.0
        # The variant this hardware should download, probed once and cached —
        # see _ensure_choice. Distinct from _variant, which is what is loaded:
        # a box may have fp32 on disk from an earlier install and still probe
        # as int8.
        self._chosen_variant = ""
        self._chosen_reason = ""
        self._dl_lock = threading.Lock()
        self._dl_state = {
            "active": False,
            "phase": "idle",        # idle | downloading | loading | done | error
            "current_file": "",
            "downloaded": 0,        # bytes downloaded so far for the current file
            "file_total": 0,        # total bytes for the current file
            "overall_done": 0,      # number of files finished
            "overall_total": len(MODEL_FILES),
            "variant": "",          # locked in when a download starts
            "error": "",
        }

    # --- SttAdapter: model lifecycle -------------------------------------------

    def is_loaded(self) -> bool:
        """True only once a real forward pass has succeeded — see :meth:`load`."""
        return self.model is not None

    def is_present(self) -> bool:
        """True if some complete variant is on disk — either will transcribe."""
        return self._installed_variant() is not None

    def _variant_present(self, variant: str) -> bool:
        return all(
            os.path.exists(os.path.join(MODEL_DIR, f))
            for f in VARIANTS[variant]["files"]
        )

    def _installed_variant(self):
        """The variant that is completely on disk, or None.

        fp32 wins when both are complete. A box holding the 2.5 GB set either
        downloaded it deliberately or predates this choice existing, and either
        way starting what is already there beats demanding another 670 MB to say
        the same words. If that machine cannot in fact run it, the smoke pass in
        :meth:`load` is what says so — not a guess made here.
        """
        for variant in (VARIANT_FP32, VARIANT_INT8):
            if self._variant_present(variant):
                return variant
        return None

    def runtime_label(self) -> str:
        return self._runtime

    def load(self) -> None:
        """Load the Parakeet ONNX model from disk and prove it can run.

        Resolves the model offline against ``MODEL_DIR`` so there's no startup
        network call once the files are present. The variant already on disk
        decides both the quantization onnx-asr resolves and the providers it
        gets: fp32 takes DirectML where it exists, int8 is the CPU path.

        The model is only published to ``self.model`` after a real clip has been
        through it. Building the sessions proves the graphs parsed and nothing
        more: a DirectML device that is absent, reset or out of memory, and
        external weights truncated by a full disk, all construct cleanly and
        fail on the first ``Run``. Such a model used to report itself ready,
        answer every dictation with an empty transcript (the shared app
        soft-fails inference to empty) and say nothing about why. The pass
        doubles as a warmup, so the first real dictation no longer pays for
        kernel compilation.

        Leaves ``self.model`` None and ``self.load_error`` set on any failure,
        then re-raises — /transcribe returns empty rather than crashing the
        sidecar, and the dashboard has words for what went wrong.
        """
        variant = self._installed_variant()
        if variant is None:
            # Not an error: nothing has been downloaded yet. Saying so here
            # would put a failure on a dashboard whose real state is "missing".
            print(f"Model files missing in {MODEL_DIR}; cannot load.")
            return
        import onnx_asr
        import onnxruntime as rt

        spec = VARIANTS[variant]
        providers = self._select_providers(rt, variant)
        runtime = ("GPU (DirectML)" if providers[0] == "DmlExecutionProvider" else "CPU")
        print(f"Loading ONNX model from {MODEL_DIR} "
              f"(variant={variant}, providers={providers}) ...")
        try:
            model = onnx_asr.load_model(
                MODEL_ID,
                path=MODEL_DIR,
                quantization=spec["quantization"],
                providers=providers,
            )
            self._verify_runnable(model)
        except Exception as exc:
            self.model = None
            self._runtime = ""
            self._variant = ""
            self.load_error = re.sub(r"https?://\S+", "[model URL]", str(exc)).strip() \
                or exc.__class__.__name__
            print(f"Model failed to load: {exc}")
            raise
        self.model = model
        self._runtime = runtime
        self._variant = variant
        self.load_error = ""
        print(f"Model loaded and verified on {runtime} "
              f"({spec['label']}, {self._rtf:.1f}x realtime).")

    def _verify_runnable(self, model) -> None:
        """Push one short clip through ``model``, raising if it cannot run it.

        A quiet tone rather than digital silence: an all-zero mel can take a
        degenerate path through the decoder, which would prove less than a real
        utterance does. The transcript is discarded — what is being tested is
        that inference completes at all.

        The pass is timed into ``_rtf`` (seconds of audio per second of wall
        clock). The clip has to run regardless, so this is a free measurement of
        the machine actually in front of us — worth more than the VRAM heuristic
        that chose the variant, since an RTF near or below 1 means dictation
        comes back slower than it was spoken.
        """
        fd, path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        try:
            frames = int(16000 * SMOKE_SECONDS)
            samples = array.array(
                "h",
                (int(2000 * math.sin(2 * math.pi * 220 * i / 16000)) for i in range(frames)),
            )
            with wave.open(path, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(16000)
                w.writeframes(samples.tobytes())
            # perf_counter, not monotonic. On Windows monotonic() is
            # GetTickCount64() at ~15.6 ms resolution, which is coarse enough to
            # time this pass as exactly zero and report 0.0x realtime for a model
            # that ran fine. perf_counter() is QueryPerformanceCounter there and
            # sub-microsecond everywhere we run.
            started = time.perf_counter()
            model.recognize(path)
            elapsed = time.perf_counter() - started
            self._rtf = (SMOKE_SECONDS / elapsed) if elapsed > 0 else 0.0
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

    def transcribe_file(self, path: str) -> str:
        # onnx-asr's recognize() accepts a WAV file path directly and does its
        # own resampling to 16 kHz. Returns the transcript string.
        return self.model.recognize(path)

    # --- SttAdapter: download manager ------------------------------------------

    def start_download(self) -> dict:
        with self._dl_lock:
            if self._dl_state["active"]:
                return {"started": False, "reason": "already_running"}
        if self.is_present() and self.is_loaded():
            return {"started": False, "reason": "already_present"}
        threading.Thread(target=self._run_download, daemon=True).start()
        return {"started": True}

    # --- internals -------------------------------------------------------------

    def _select_providers(self, rt_module, variant: str = VARIANT_FP32) -> list:
        """Execution providers for ``variant``.

        int8 is pinned to the CPU deliberately. That export is built from
        DynamicQuantizeLinear/MatMulInteger — ops whose reason to exist is the
        CPU's VNNI/AVX integer kernels. Handing them to DirectML gives away
        accuracy for no speed and frequently for less. fp32 prefers DirectML and
        falls back to CPU so the sidecar still runs on a box with no DX12 GPU.
        """
        if variant == VARIANT_INT8:
            return ["CPUExecutionProvider"]
        available = list(rt_module.get_available_providers())
        if "DmlExecutionProvider" in available:
            return ["DmlExecutionProvider", "CPUExecutionProvider"]
        print("DirectML provider not available; falling back to CPU (dev only).")
        return ["CPUExecutionProvider"]

    def _choose_variant(self, rt_module):
        """Pick the variant this machine should download. Returns (variant, why).

        Errs toward int8 whenever the hardware cannot be read, because the two
        mistakes are not symmetric: an unnecessary int8 costs a little accuracy
        on a box that would have coped with fp32, while an unnecessary fp32
        costs the user a 2.5 GB download that then fails to load or crawls, plus
        another 670 MB to put right.
        """
        if "DmlExecutionProvider" not in list(rt_module.get_available_providers()):
            return VARIANT_INT8, "no DirectML GPU support on this machine"

        vram = _dedicated_vram_bytes()
        if vram is None:
            return VARIANT_INT8, "could not read the GPU's memory size"
        if vram < MIN_VRAM_BYTES_FP32:
            return (
                VARIANT_INT8,
                f"the GPU has {_gb(vram)} of memory, under the "
                f"{_gb(MIN_VRAM_BYTES_FP32)} full precision needs",
            )
        # Room on the GPU is not room on the disk. Better to notice here, where
        # the answer is a smaller model, than in the preflight, where it is a
        # refusal the user cannot act on without freeing 2.5 GB.
        if self._variant_shortfall(VARIANT_FP32) and not self._variant_shortfall(VARIANT_INT8):
            return VARIANT_INT8, "not enough disk space for the full precision model"
        return VARIANT_FP32, f"DirectML GPU with {_gb(vram)} of memory"

    def _ensure_choice(self):
        """This machine's variant, probed once and cached. Returns (variant, why).

        Cached because ``/model/status`` is polled continuously and the probe
        reads the registry. The env override is resolved before onnxruntime is
        imported, so support can pin a variant even on a box where that import
        is itself the problem.
        """
        if self._chosen_variant:
            return self._chosen_variant, self._chosen_reason
        forced = os.environ.get("SUNOFLOW_MODEL_VARIANT", "").strip().lower()
        if forced in VARIANTS:
            variant, reason = forced, "set by SUNOFLOW_MODEL_VARIANT"
        else:
            try:
                import onnxruntime as rt
                variant, reason = self._choose_variant(rt)
            except Exception as exc:
                # An onnxruntime that will not import is no reason to guess
                # high: the expensive mistake is committing a machine to 2.5 GB
                # it cannot use.
                variant = VARIANT_INT8
                reason = (f"could not probe the hardware "
                          f"({exc.__class__.__name__}); chose the safe variant")
        self._chosen_variant, self._chosen_reason = variant, reason
        print(f"Model variant for this machine: {variant} — {reason}")
        return variant, reason

    def _download_file(self, url: str, dest: str) -> None:
        """Stream a single file to disk, updating _dl_state progress as bytes arrive."""
        import requests as _requests

        os.makedirs(os.path.dirname(dest), exist_ok=True)
        tmp = dest + ".part"
        with _requests.get(url, stream=True, timeout=60) as r:
            r.raise_for_status()
            total = int(r.headers.get("Content-Length", 0))
            with self._dl_lock:
                self._dl_state["file_total"] = total
                self._dl_state["downloaded"] = 0
                self._dl_state["current_file"] = os.path.basename(dest)
            written = 0
            with open(tmp, "wb") as f:
                for chunk in r.iter_content(chunk_size=1 << 20):  # 1 MiB
                    if not chunk:
                        continue
                    f.write(chunk)
                    written += len(chunk)
                    with self._dl_lock:
                        self._dl_state["downloaded"] = written
        os.replace(tmp, dest)

    def _run_download(self) -> None:
        """Worker thread: fetch this machine's variant, then load it in-process.

        The variant is resolved once, here, and held in ``_dl_state`` for the
        duration. Re-probing per file would let a mid-download answer change and
        leave MODEL_DIR holding half of each.

        A complete variant already on disk is kept even when the probe would now
        pick the other one. Those files cost gigabytes, and whether they work is
        for :meth:`load` to answer with a forward pass — not something to
        pre-empt by quietly fetching a second model alongside the first. To move
        an existing install across variants, delete MODEL_DIR or pin
        ``SUNOFLOW_MODEL_VARIANT``.
        """
        installed = self._installed_variant()
        if installed:
            variant, reason = installed, "already on disk"
        else:
            variant, reason = self._ensure_choice()
        files = VARIANTS[variant]["files"]
        print(f"Downloading the {variant} model ({_gb(VARIANTS[variant]['bytes'])}) "
              f"— {reason}")
        try:
            os.makedirs(MODEL_DIR, exist_ok=True)
            shortfall = self._disk_shortfall()
            if shortfall:
                # Refused before the first byte. Filling the disk mid-download
                # does not just waste the transfer: it truncates the external
                # weights file, which then loads cleanly and fails on the first
                # inference — the exact failure this whole path exists to avoid.
                print(f"Refusing model download: {shortfall}")
                with self._dl_lock:
                    self._dl_state.update(phase="error", active=False, error=shortfall)
                return
            with self._dl_lock:
                self._dl_state.update(
                    active=True, phase="downloading", overall_done=0,
                    overall_total=len(files), variant=variant,
                    error="", current_file="",
                )
            for i, fname in enumerate(files):
                dest = os.path.join(MODEL_DIR, fname)
                if os.path.exists(dest):
                    # Already have this file (e.g. a resume). Skip but count it.
                    with self._dl_lock:
                        self._dl_state["overall_done"] = i + 1
                    continue
                self._download_file(f"{HF_BASE}/{fname}", dest)
                with self._dl_lock:
                    self._dl_state["overall_done"] = i + 1

        except Exception as exc:
            print(f"Model download failed: {exc}")
            # Strip any URL from the surfaced error so the upstream model
            # source isn't leaked to the client UI; the full exception is kept in the log.
            safe = re.sub(r"https?://\S+", "[download URL]", str(exc))
            with self._dl_lock:
                self._dl_state.update(phase="error", active=False, error=safe)
            return

        # Loading is a separate failure from downloading, and saying so matters:
        # by this point 2.5 GB is on disk, and reporting "download failed" would
        # invite the user to fetch all of it again to fix something the download
        # had nothing to do with.
        try:
            with self._dl_lock:
                self._dl_state.update(phase="loading", current_file="")
            self.load()
            with self._dl_lock:
                self._dl_state.update(phase="done", active=False)
        except Exception as exc:
            print(f"Model downloaded but failed to load: {exc}")
            safe = re.sub(r"https?://\S+", "[download URL]", str(exc))
            with self._dl_lock:
                self._dl_state.update(
                    phase="error", active=False,
                    error=f"The model downloaded, but the engine could not start it: {safe}",
                )

    def status_snapshot(self) -> dict:
        with self._dl_lock:
            snap = dict(self._dl_state)
        chosen, reason = self._ensure_choice()
        installed = self._variant or self._installed_variant()
        if snap.get("active") and snap.get("variant"):
            # A download in flight is the authority on what is being fetched.
            variant = snap["variant"]
        elif installed:
            # What is on disk beats what the probe wants. They agree after a
            # download, but a box carrying an older fp32 install should be
            # described by the model it will actually load.
            variant = installed
            if installed != chosen:
                reason = (f"already installed; this machine would otherwise "
                          f"use {chosen} ({reason})")
        else:
            variant = chosen
        snap["variant"] = variant
        snap["variant_label"] = VARIANTS[variant]["label"]
        snap["variant_reason"] = reason
        snap["download_bytes"] = VARIANTS[variant]["bytes"]
        snap["overall_total"] = len(VARIANTS[variant]["files"])
        snap["model_dir"] = MODEL_DIR
        snap["model_id"] = HF_REPO
        return snap

    def _disk_shortfall(self) -> str:
        """The reason there isn't room for this machine's variant, or ""."""
        variant, _ = self._ensure_choice()
        return self._variant_shortfall(variant)

    def _variant_shortfall(self, variant: str) -> str:
        """The reason ``variant`` will not fit on disk, or "" when it will.

        Only the files still missing are counted — a resumed download has most
        of its bytes on disk already and should not be refused for space it is
        not about to use.
        """
        try:
            spec = VARIANTS[variant]
            have = 0
            for fname in spec["files"]:
                path = os.path.join(MODEL_DIR, fname)
                if os.path.exists(path):
                    have += os.path.getsize(path)
            needed = max(spec["bytes"] - have, 0) + DISK_HEADROOM_BYTES
            free = shutil.disk_usage(MODEL_DIR).free
            if free >= needed:
                return ""
            drive = os.path.splitdrive(MODEL_DIR)[0] or MODEL_DIR
            return (f"Not enough disk space: the speech model needs about "
                    f"{_gb(needed)} free on {drive} and there is {_gb(free)}.")
        except OSError as exc:
            # An unreadable drive is not a reason to block a download that might
            # well succeed; let the transfer itself report the real problem.
            print(f"Could not check free disk space: {exc}")
            return ""


def _gb(n: int) -> str:
    """Bytes as a short GB string for a message a user will read."""
    return f"{n / 1_000_000_000:.1f} GB"


def build_app(corrections_path: str | None = None) -> "object":
    """Construct the FastAPI app for the Windows ONNX sidecar.

    ``corrections_path`` defaults to ``corrections.json`` next to this file.
    """
    if corrections_path is None:
        corrections_path = os.path.join(os.path.dirname(__file__), "corrections.json")
    return create_app(ParakeetOnnxAdapter(), corrections_path)