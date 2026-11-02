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

AMI, Earnings-22, GigaSpeech and VoxPopuli use their original transcripts, the version most model cards quote. Since 2026 the live leaderboard has defaulted to re-transcribed ("cleaned") versions of these four. Every model scores lower on those, so its current numbers can't be compared with this table.

| Model | Avg | AMI | Earnings-22 | GigaSpeech | LS clean | LS other | SPGISpeech | VoxPopuli |
|---|---|---|---|---|---|---|---|---|
| **Koe** (Bark ∥ Qwen → Gemma) | 8.02 | 15.52 | 12.23 | 11.76 | 2.11 | 4.43 | 2.77 | 7.32 |
| Bark 3.0 Clean alone | 7.82 | 13.62 | 12.37 | 11.76 | 2.17 | 4.52 | 2.97 | 7.30 |
| Qwen3-ASR 0.6B alone | 7.55 | 12.31 | 12.46 | 9.44 | 2.23 | 5.04 | 3.10 | 8.23 |
| Hex (Parakeet Unified 0.6B) | 6.17 | 9.80 | 10.58 | 10.22 | 1.83 | 3.17 | 1.96 | 5.60 |
| Granite Speech 4.1 2B ¹ | 5.65 | 8.09 | 8.37 | 9.80 | 1.33 | 2.50 | 3.78 | 5.70 |
| Cohere Transcribe 2B ¹ | 5.84 | 8.13 | 10.86 | 9.34 | 1.25 | 2.37 | 3.08 | 5.87 |
| Parakeet TDT 0.6B v2 ¹ | 6.44 | 11.16 | 11.15 | 9.74 | 1.69 | 3.19 | 2.17 | 5.95 |
| Qwen3-ASR 0.6B ¹ | 7.24 | 13.77 | 11.03 | 9.16 | 2.12 | 4.47 | 3.04 | 7.09 |
| Whisper large-v3 turbo ¹ | 8.44 | 16.13 | 11.63 | 10.14 | 2.10 | 4.24 | 2.97 | 11.87 |

| | Common Voice | FLEURS (en) |
|---|---|---|
| **Koe** | 10.98 | 6.01 |
| Bark 3.0 Clean alone | 11.18 | 7.51 |
| Qwen3-ASR 0.6B alone | 11.64 | 6.52 |
| Hex (Parakeet Unified 0.6B) | 8.48 | 5.66 |

- These sets favor models trained on their own corpora. Parakeet, the base of Bark, lists the training splits of LibriSpeech, Common Voice and AMI (v2 also VoxPopuli) among its human-transcribed data. Speech that sounds like those corpora is easy for it; new jargon isn't, which is why the dictation results above matter more for Koe.
- Koe beats both of its own recognizers on 6 of these 9 sets. Newer models such as Hex's Parakeet Unified, and larger ones such as Granite Speech, are more accurate on read and broadcast speech. Koe's edge is the jargon above.
- Koe writes clean text, so it drops stutters and filler phrases ("I think I think", "you know"). The leaderboard's normalizer only removes sounds like "uh", "um" and "mm", so the rest counts as errors on conversational sets. That explains most of Koe's gap on AMI's meeting recordings.
- The top four rows were run here on the same audio: 500 random clips per set, and all 647 for FLEURS. That leaves up to ±1 point of sampling noise on the harder sets. Rows marked ¹ are published full-set results, for reference. Our 4-bit Qwen3-ASR sample scored 7.55 against its published 7.24.
- The leaderboard's eighth set, TED-LIUM, isn't in its public data, so averages cover these seven.
- `bench/run.sh` reproduces Koe's rows. It downloads the test audio (about 6.4 GB) into `bench/data`.

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
