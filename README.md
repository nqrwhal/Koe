<img src="https://raw.githubusercontent.com/nqrwhal/Koe/main/Resources/AppIcon-preview.png" width="128" align="right" alt="Koe icon">

# Koe 声

Hold-to-talk (or tap-to-toggle / double-tap lock) dictation for macOS that runs 100% on your Mac. Hold **Right ⌘**, speak, let go — the text is pasted wherever your cursor is.

Koe is built for technical dictation: it gets jargon (`OIDC`, `kubectl`, `gRPC`), numbers (`PR 2032`, `port 8080`), `.env` filenames, and your own vocabulary right with zero cloud audio.

## How it works

### Two operating modes

- **Balanced Hybrid (default, ~2.4 GB peak footprint / ~1.8 GB RSS):** Runs [Parakeet Unified 0.6B](https://github.com/FluidInference/FluidAudio) (streaming `int8` RNNT on the Neural Engine) in parallel with [Qwen3-ASR 0.6B](https://github.com/Blaizzy/mlx-audio-swift) (4-bit on GPU). Everyday agreements paste straight away without invoking the LLM; spelled-out acronyms (`"J W T"` → `JWT`), exact jargon casings (`"github"` → `GitHub`, `"next js"` → `Next.js`), hyphenated compounds, and numbers spoken vs written as digits (`"twenty thirty-two"` / `2032`) reconcile deterministically first. Disagreements on technical terms, casing, or punctuation are settled sentence-by-sentence by [Qwen3 1.7B](https://github.com/ml-explore/mlx-swift-lm) (4-bit, non-thinking KV-prefilled prompting with lookup decoding), restricted strictly to the spans where the recognizers differ so agreed words are never dropped or rewritten. After configurable inactivity (default 10 min), GPU models unload automatically back down to ~60 MB and reload on the next key press.
  - Other selectable fusers in Settings: **Ultra-Light Hybrid** (**Qwen3 0.6B** / **Qwen3.5 0.8B**, ~2.2 GB peak footprint) and **Gemma 4 E2B** / **Gemma 4 E4B**.
- **ANE Solo (~60 MB RAM, ~30–150 ms latency):** Continuous Neural Engine streaming on **Parakeet Unified 0.6B** with zero GPU memory. Optional **Parakeet CTC 110M** personal-vocabulary boosting (+106 MB on disk, still 0.06 GB peak footprint) biases recognition toward your custom terms. (Also supports **Parakeet Unified 0.6B 15s Batch** and legacy **Bark 3.0 Clean**.)

### Natural punctuation & cleanup

- **No mid-thought truncation:** ANE Solo streams continuously into Parakeet Unified's stateful encoder with zero pause cuts. Hybrid mode uses conservative Silero VAD segmentation (`>= 1.5 s` silence after `>= 10 s` of speech by default, or **Whole Dictation** to disable pause cuts under 30 s) and heals pause seams using syntactic rules plus boundary continuation checks.
- **Deterministic cleanup:** Repairs intra-word ASR glitches (`"tuning,s"` → `"tunings,"`), drops rogue mid-sentence periods and hesitation commas (`"to. Be"`, `"on device, dictation"`), fixes lowercase after sentence breaks (`". if"` → `". If"`) without mangling dotfiles (`.env`), paths, or dotted tech names (`Next.js`), strips fillers (`um`, `uh`, `erm`) and immediate stutters (`"the the"`), and applies customizable spoken → written **Word Replacements** (`~/Library/Application Support/Koe/replacements.json`, e.g. `"dot env"` → `".env"`).
- **Built-in & personal vocabulary:** Developer and AI terms are built in and used only where recognizers disagree, so ordinary words aren't rewritten into product names. Add your own terms in `~/Library/Application Support/Koe/vocabulary.txt` (`"whisper flow"` → `"Wispr Flow"`), applied even when both recognizers agree.

## Settings, shortcuts & inspector (`⌘,`)

- **Shortcuts & capture:** Custom shortcut recorder supporting Hold to Talk, Tap to Toggle, or Double-Tap Lock for hands-free dictation, `Esc` to cancel, and **Paste Last Dictation** (`⌥⇧V` by default). Includes a microphone selector and warm-mic pre-roll timer (`Off`, `1`, `3`, or `5` min; 3 min default with 0.3 s rolling pre-roll).
- **Models & memory:** Live process footprint and MLX GPU memory monitor, manual **Unload GPU** button, 1-click presets, and background model switching with download progress.
- **Tuning & vocabulary:** Sliders for **Key-Release Tail** (`220 ms` default with adaptive trailing-speech extension so final syllables aren't clipped) and segment/pause thresholds, cleanup toggles, **Smart Context Spacing** (reads the character before the cursor via Accessibility), a live cleanup preview sandbox, and live-reloading **Personal Vocabulary** and **Word Replacements** editors.
- **History & Pipeline Diff Inspector:** Searchable local history (`~/Library/Application Support/Koe/history.json`) with route badges (`ane-solo`, `agree`, `fuse`), per-stage latencies, `Base ANE → Final` and `Qwen3-ASR → Final` word diffs, WAV playback (when recording saving is enabled), and 1-click add to vocabulary.

## Benchmarks (v0.5)

Measured across 35 real saved recordings (`bench/eval_recordings.py`, running `Koe --eval` under `/usr/bin/time -l`), counting punctuation/casing anomalies (`intra_word`, `lower_after_period`, `dangling_period`, and `rogue_comma`):

| Stack | Peak footprint | Max RSS | Median wait | p95 wait | Segments | Anomalies |
|---|---:|---:|---:|---:|---:|---:|
| v0.4.1 (`Bark ∥ Qwen → Gemma 4 E4B`) | 8.18 GB | — | — | — | — | 15 |
| **ANE Solo** (Parakeet Unified, no CTC) ¹ | 0.06 GB | 0.10 GB | 29 ms | 47 ms | 35 | 1 |
| **ANE Solo** (Parakeet Unified + CTC) | 0.06 GB | 0.11 GB | 151 ms | 175 ms | 35 | 1 |
| **Ultra-Light Hybrid** (`Qwen3 0.6B`) | 2.19 GB | 1.22 GB | 536 ms | 1,069 ms | 41 | 1 |
| **Qwen3.5 0.8B Hybrid** | 2.24 GB | 1.49 GB | 561 ms | 1,353 ms | 41 | 1 |
| **Balanced Hybrid** (`Qwen3 1.7B`, default) | 2.39 GB | 1.81 GB | 483 ms | 999 ms | 41 | 1 |
| **Gemma 4 E2B Hybrid** ¹ | 4.25 GB | 4.28 GB | 2,461 ms | 4,863 ms | 41 | 5 |

Source: `bench/results/eval_final.json` (with ¹ from `bench/results/eval_cached.json`, captured prior to the final dangling-period rule which accounts for 4 of Gemma 4 E2B's 5 anomalies). Across all four stacks in `eval_final.json`, intra-word, lowercase-after-period, and dangling-period anomalies drop to `0` (`1` rogue comma remaining).

## Accuracy

Word error rate (WER, lower is better): the share of words a transcript gets wrong. The developer dictation and multi-dataset Open ASR Leaderboard benchmarks below were measured on the v0.4 `Bark ∥ Qwen → Gemma 4 E4B` pipeline (`bench/run.sh` reproduces the leaderboard rows).

### Dictation

Sentences full of developer and AI terms (kubectl, Supabase, Ghostty, MCP…): 40 recorded by one person on external mics, half of them with music playing, and 45 in synthetic voices. *Terms* is the share of expected terms spelled exactly, casing included.

| | Recordings: WER | Terms | Synthetic: WER | Terms | Wait after release |
|---|---|---|---|---|---|
| **Koe** | **7.0%** | **72%** | **10.8%** | **77%** | 0.32 s |
| [Hex](https://github.com/anomalyco/hex) (Parakeet Unified 0.6B) | 7.6% | 58% | 14.2% | 53% | 0.06 s |
| Qwen3-ASR 0.6B alone | 9.8% | 50% | 16.0% | 58% | |
| Bark 3.0 Clean alone | 12.4% | 36% | 35.6% | 19% | |

- The recordings were made after Koe's vocabulary was last changed. The synthetic clips were used while building Koe, so they flatter it.
- Koe ran with its built-in vocabulary plus a three-term personal list (Koe, Qwen, Wispr Flow). Hex ran with its default settings.
- The recordings aren't published; only these totals are.
- Koe's wait is the median time from releasing the key to the text, with earlier pieces transcribed while you talk. Plain sentences that both recognizers agree on take about 0.11 s. Hex's figure is its own benchmark tool's per-clip time.

### Standard test sets

These are the [Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard) sets that speech-model releases report, scored the leaderboard's way: Whisper's English normalizer, WER per set, plain average. Wispr Flow's Canto announcement quotes LibriSpeech, FLEURS and Common Voice, and Aqua Voice quotes its leaderboard average.

The live leaderboard (November 2026) averages 11 sets, two of them private. This table covers the 9 public ones, with the leaderboard's own rows (¹) for reference. Koe would rank about 51st of the leaderboard's 63 models on these sets: about as accurate as Bark alone, and behind Whisper large-v3.

| Model | Avg | AMI | Earnings-22 | GigaSpeech | LS clean | LS other | SPGISpeech | URGENT24 | Monsoon | VoxPopuli |
|---|---|---|---|---|---|---|---|---|---|---|
| **Koe** (Bark ∥ Qwen → Gemma) | 7.58 | 13.59 | 9.60 | 11.17 | 2.11 | 4.43 | 2.77 | 14.81 | 6.93 | 2.81 |
| Bark 3.0 Clean alone | 7.63 | 12.19 | 9.92 | 11.16 | 2.17 | 4.52 | 2.97 | 15.72 | 7.60 | 2.47 |
| Hex (Parakeet Unified 0.6B) | 5.82 | 7.66 | 7.13 | 10.12 | 1.83 | 3.17 | 1.96 | 11.94 | 4.21 | 4.38 |
| Zoom Scribe v2.1 Pro, #1 of 63 ¹ | 3.61 | 5.96 | 3.80 | 7.19 | 1.08 | 2.09 | 1.39 | 6.63 | 2.78 | 1.58 |
| Nemotron 3.5 Transcribe 30B ¹ | 4.70 | 7.78 | 5.25 | 7.18 | 1.09 | 2.62 | 1.91 | 10.94 | 3.63 | 1.89 |
| Qwen3-ASR 1.7B ¹ | 4.94 | 8.31 | 5.84 | 7.22 | 1.26 | 2.94 | 2.57 | 9.93 | 3.50 | 2.85 |
| Parakeet TDT 0.6B v2 ¹ | 5.45 | 9.09 | 6.76 | 8.15 | 1.28 | 2.73 | 1.94 | 11.42 | 3.89 | 3.78 |
| Qwen3-ASR 0.6B ¹ | 5.77 | 9.33 | 7.83 | 7.62 | 1.70 | 4.01 | 2.74 | 11.57 | 4.23 | 2.90 |
| Whisper large-v3 ¹ | 6.66 | 13.63 | 7.99 | 8.35 | 1.56 | 3.52 | 2.71 | 13.73 | 3.95 | 4.53 |

| | Common Voice | FLEURS (en) |
|---|---|---|
| **Koe** | 10.98 | 6.01 |
| Bark 3.0 Clean alone | 11.18 | 7.51 |
| Qwen3-ASR 0.6B alone | 11.64 | 6.52 |
| Hex (Parakeet Unified 0.6B) | 8.48 | 5.66 |

- AMI, Earnings-22, GigaSpeech and VoxPopuli are the leaderboard's re-transcribed ("cleaned") versions. URGENT24 is read and spoken audio with added noise and room reverberation; Monsoon is Indian-English conversation.
- These sets favor models trained on their own corpora. Parakeet, the base of Bark, lists the training splits of LibriSpeech, Common Voice and AMI (v2 also VoxPopuli) among its human-transcribed data. Speech that sounds like those corpora is easy for it; new jargon isn't, which is why the dictation results above matter more for Koe.
- Koe writes clean text, so it drops stutters and filler phrases ("I think I think", "you know"). These transcripts keep them, and the leaderboard's normalizer only removes sounds like "uh", "um" and "mm", so the rest counts as errors. That explains much of Koe's gap on AMI and Monsoon.
- Koe runs Qwen3-ASR 0.6B in 4 bits, which costs it about half a point to a point on LibriSpeech against the leaderboard's full-precision row. Run alone, it looped on 3 of URGENT24's 1,000 noisy clips (one came back 7,021 words long), so its own row isn't shown; Koe caps Qwen's output for exactly this reason.
- Koe's, Bark's and Hex's rows were run here on the same audio: 500 random clips per set, and every clip of VoxPopuli, URGENT24, Earnings-22 and FLEURS. That leaves up to ±1 point of sampling noise on the harder sets. Earnings-22 comes in chunks, which are joined per call and scored against the call's transcript, as the leaderboard does.
- `bench/run.sh` reproduces Koe's rows. It downloads the test audio (about 8.5 GB) into `bench/data`.

<details>
<summary>On the original transcripts, as most model cards quote them</summary>

Before 2026 the leaderboard used the original transcripts of AMI, Earnings-22, GigaSpeech and VoxPopuli, and every model scores higher on those. Rows marked ¹ are published full-set results.

| Model | Avg | AMI | Earnings-22 | GigaSpeech | LS clean | LS other | SPGISpeech | VoxPopuli |
|---|---|---|---|---|---|---|---|---|
| **Koe** | 8.02 | 15.52 | 12.23 | 11.76 | 2.11 | 4.43 | 2.77 | 7.32 |
| Bark 3.0 Clean alone | 7.82 | 13.62 | 12.37 | 11.76 | 2.17 | 4.52 | 2.97 | 7.30 |
| Qwen3-ASR 0.6B (4-bit) alone | 7.55 | 12.31 | 12.46 | 9.44 | 2.23 | 5.04 | 3.10 | 8.23 |
| Hex (Parakeet Unified 0.6B) | 6.17 | 9.80 | 10.58 | 10.22 | 1.83 | 3.17 | 1.96 | 5.60 |
| Parakeet TDT 0.6B v2 ¹ | 6.44 | 11.16 | 11.15 | 9.74 | 1.69 | 3.19 | 2.17 | 5.95 |
| Qwen3-ASR 0.6B ¹ | 7.24 | 13.77 | 11.03 | 9.16 | 2.12 | 4.47 | 3.04 | 7.09 |
| Whisper large-v3 turbo ¹ | 8.44 | 16.13 | 11.63 | 10.14 | 2.10 | 4.24 | 2.97 | 11.87 |

</details>

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/nqrwhal/Koe/main/install.sh | sh
```

This installs the latest release into `/Applications` (or `~/Applications`), downloads about **2.4 GB** of default models (from Hugging Face and FluidAudio), removes quarantine, and opens Koe. Run the same command again to update Koe in place (keeping `/Applications` or `~/Applications` and preserving your settings, vocabulary, and history). Then grant **Accessibility** (to watch the hotkey and paste) and **Microphone** access when asked. (If a shortcut stops responding after updating, toggle Koe off and on in **System Settings → Privacy & Security → Accessibility**.)

Installer environment variables:

- `KOE_VERSION` — install a specific release tag (e.g. `0.5` or `v0.5`); defaults to latest
- `KOE_INSTALL_DIR` — install somewhere other than `/Applications` or `~/Applications` (does not launch)
- `KOE_ANE_ONLY=1` — download only Neural Engine models (~715 MB) and start in **ANE Solo** mode
- `KOE_SKIP_MODELS=1` — skip model downloads during install (Koe downloads active models on first launch)
- `KOE_FUSER` — pre-download a different fuser model (`qwen3-0.6b`, `qwen3.5-0.8b`, `qwen3-1.7b`, `gemma4-e2b`, `gemma4-e4b`)

Requires an Apple Silicon Mac with macOS 15 or later: **8 GB+ RAM** for ANE Solo or Ultra-Light Hybrid, **16 GB+ RAM** recommended for Balanced Hybrid.

<details>
<summary>Or install from the DMG</summary>

Download `Koe-<version>.dmg` from [Releases](https://github.com/nqrwhal/Koe/releases), open it and drag **Koe** to Applications. Koe isn't notarized, so the first time **right-click Koe → Open** (or run `xattr -dr com.apple.quarantine /Applications/Koe.app`). The install script avoids this because `curl` doesn't quarantine downloads.
</details>

## Build from source

Requires Xcode with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```sh
./build.sh        # builds, installs to ~/Applications/Koe.app and launches it (--no-launch to skip open)
./package.sh      # packages dist/Koe.zip (for install.sh) and dist/Koe-<version>.dmg
```

CLI tools on the built binary (`~/Applications/Koe.app/Contents/MacOS/Koe`):

```sh
Koe --self-test   # deterministic checks for TextCleaner, Disagreements, Vocabulary, KeyBinding, Paster, HistoryStore
Koe --eval [--mode ane-solo|hybrid] [--base unified-stream|unified-batch|bark] \
    [--fuser qwen3-0.6b|qwen3.5-0.8b|qwen3-1.7b|gemma4-e2b|gemma4-e4b] \
    [--no-ctc] [--whole] [--no-clean] file.wav …
```

`Koe --eval` runs the pipeline on 16 kHz recordings and prints JSON lines with transcripts, routes, timings, and memory footprint (`bench/eval_recordings.py` reproduces the v0.5 stack evaluation; `bench/run.sh` reproduces the v0.4 Open ASR Leaderboard rows).
