# Koe 声

Hold-to-talk dictation for macOS that runs entirely on your Mac. Hold **Right ⌘**, speak, let go — the text is pasted wherever your cursor is.

Koe is built for people who dictate technical text: it gets `OIDC`, `kubectl`, `gRPC` and your own project names right, and it never sends audio anywhere.

## How it works

- **Instant capture.** The mic stays warm for a few minutes after each dictation with a short rolling buffer, so the first word is never lost.
- **Two recognizers in parallel.** [Parakeet (Bark 3.0 Clean)](https://github.com/FluidInference/FluidAudio) runs on the Neural Engine and [Qwen3-ASR 0.6B](https://github.com/Blaizzy/mlx-audio-swift) on the GPU.
- **Fast path when they agree.** Most plain speech is pasted straight away (~200 ms after release).
- **A small LLM settles disagreements.** [Gemma 4 E4B](https://github.com/ml-explore/mlx-swift-lm) fuses only the sentences where the two recognizers differ, using your vocabulary for spelling. It never rewrites sentences they agree on.
- **Your vocabulary.** Add names and terms, one per line, to `~/Library/Application Support/Koe/vocabulary.txt`.

## Install

Download the latest `.dmg` from [Releases](../../releases), open it and drag **Koe** to Applications.

Koe isn't notarized yet, so the first time, **right-click Koe → Open** (or run `xattr -dr com.apple.quarantine /Applications/Koe.app`). Then grant **Accessibility** (to see the hotkey and paste) and **Microphone** access when asked.

On first launch Koe downloads its models (about 6 GB) from Hugging Face. Requires an Apple Silicon Mac with macOS 15 or later; 16 GB+ RAM recommended.

## Build from source

Requires Xcode with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```sh
./build.sh        # builds, installs to ~/Applications/Koe.app and launches it
./make-dmg.sh     # packages dist/Koe-<version>.dmg
```

`Koe --eval file.wav …` runs the full pipeline on 16 kHz recordings and prints JSON lines with timings.
