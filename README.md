<img src="Resources/AppIcon-preview.png" width="128" align="right" alt="Koe icon">

# Koe 声

Hold-to-talk dictation for macOS that runs entirely on your Mac. Hold **Right ⌘**, speak, let go — the text is pasted wherever your cursor is.

Koe is built for people who dictate technical text: it gets `OIDC`, `kubectl`, `gRPC` and your own project names right, and it never sends audio anywhere.

## How it works

- **Instant capture.** The mic stays warm for a few minutes after each dictation with a short rolling buffer, so the first word is never lost.
- **Two recognizers in parallel.** [Parakeet (Bark 3.0 Clean)](https://github.com/FluidInference/FluidAudio) runs on the Neural Engine and [Qwen3-ASR 0.6B](https://github.com/Blaizzy/mlx-audio-swift) on the GPU.
- **Transcribes while you talk.** Pauses split long dictations into pieces that are transcribed in the background, so letting go only leaves the last few seconds to process.
- **Fast path when they agree.** Most plain speech is pasted straight away (~150 ms after release). Spelled-out letters and exact jargon spellings are fixed for free first ("J W T" → JWT, "github" → GitHub), so jargon often agrees too.
- **A small LLM settles disagreements.** [Gemma 4 E4B](https://github.com/ml-explore/mlx-swift-lm) looks only at the sentences where the two recognizers differ, and its answer can only change the words they disagreed on. Words both of them heard are never dropped or rewritten.
- **Developer and AI vocabulary built in.** Codex, kubectl, nginx, OAuth, Supabase and a couple hundred more, used only where the recognizers disagree, so ordinary sentences are never "corrected" into product names.
- **Your own words.** Add names and terms, one per line, to `~/Library/Application Support/Koe/vocabulary.txt`. Koe spells these your way even when both recognizers agree on something close ("whisper flow" → "Wispr Flow").

## Accuracy

Word error rate (WER, lower is better): the share of words a transcript gets wrong.

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

This installs the latest release into `/Applications` (or `~/Applications`), downloads its speech and language models (about 6 GB, from Hugging Face) and opens it; run it again to update. Then grant **Accessibility** (to see the hotkey and paste) and **Microphone** access when asked.

Requires an Apple Silicon Mac with macOS 15 or later; 16 GB+ RAM recommended.

<details>
<summary>Or install from the DMG</summary>

Download `Koe-<version>.dmg` from [Releases](../../releases), open it and drag **Koe** to Applications. Koe isn't notarized, so the first time **right-click Koe → Open** (or run `xattr -dr com.apple.quarantine /Applications/Koe.app`). The install script avoids this because `curl` doesn't quarantine downloads.
</details>

## Build from source

Requires Xcode with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```sh
./build.sh        # builds, installs to ~/Applications/Koe.app and launches it
./package.sh      # packages dist/Koe.zip (for install.sh) and dist/Koe-<version>.dmg
```

`Koe --eval file.wav …` runs the full pipeline on 16 kHz recordings and prints JSON lines with timings.
