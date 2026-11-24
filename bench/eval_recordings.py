#!/usr/bin/env python3
"""Evaluate candidate Koe model stacks across real saved recordings."""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

KOE = os.environ.get("KOE", os.path.expanduser("~/Applications/Koe.app/Contents/MacOS/Koe"))
RECORDINGS_DIR = Path(os.path.expanduser("~/Library/Application Support/Koe/Recordings"))

STACKS = [
    ("ane-solo-ctc", ["--mode", "ane-solo", "--base", "unified-stream"]),
    ("ane-solo-noctc", ["--mode", "ane-solo", "--base", "unified-stream", "--no-ctc"]),
    ("hybrid-qwen3-0.6b", ["--mode", "hybrid", "--base", "unified-stream", "--fuser", "qwen3-0.6b"]),
    ("hybrid-qwen3.5-0.8b", ["--mode", "hybrid", "--base", "unified-stream", "--fuser", "qwen3.5-0.8b"]),
    ("hybrid-qwen3-1.7b", ["--mode", "hybrid", "--base", "unified-stream", "--fuser", "qwen3-1.7b"]),
    ("hybrid-gemma4-e2b", ["--mode", "hybrid", "--base", "unified-stream", "--fuser", "gemma4-e2b"]),
]


def count_anomalies(texts):
    intra_word = 0
    lower_after_period = 0
    dangling_prep_period = 0
    rogue_comma = 0
    for t in texts:
        intra_word += len(re.findall(r"\b[a-zA-Z]+[,;:][a-zA-Z]+\b", t))
        lower_after_period += len(re.findall(r"[.!?]\s+[a-z]+\b", t))
        dangling_prep_period += len(re.findall(
            r"\b(to|for|with|in|on|of|at|by|from|we|can|the|a|an|that|which)\.\s+[A-Z]",
            t, flags=re.IGNORECASE,
        ))
        rogue_comma += len(re.findall(
            r"\b(on|with|from|for|some|that|the|a|an|device),\s+",
            t, flags=re.IGNORECASE,
        ))
    return {
        "intra_word": intra_word,
        "lower_after_period": lower_after_period,
        "dangling_period": dangling_prep_period,
        "rogue_comma": rogue_comma,
        "total": intra_word + lower_after_period + dangling_prep_period + rogue_comma,
    }


def run_stack(name, flags, wavs):
    cmd = ["/usr/bin/time", "-l", KOE, "--eval", *flags, *wavs]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"ERROR running {name}: {proc.stderr}", file=sys.stderr)
        return None

    rows = []
    for line in proc.stdout.splitlines():
        if line.startswith("{"):
            rows.append(json.loads(line))

    peak_footprint_bytes = 0
    max_rss_bytes = 0
    for line in proc.stderr.splitlines():
        m1 = re.search(r"(\d+)\s+peak memory footprint", line)
        if m1:
            peak_footprint_bytes = int(m1.group(1))
        m2 = re.search(r"(\d+)\s+maximum resident set size", line)
        if m2:
            max_rss_bytes = int(m2.group(1))

    latencies = [r["ms"] for r in rows]
    fuses = [r["fuse_ms"] for r in rows if r["fuse_ms"] > 0]
    segs = sum(r["segments"] for r in rows)
    anoms = count_anomalies([r["text"] for r in rows])

    p95 = sorted(latencies)[min(len(latencies) - 1, int(len(latencies) * 0.95))] if latencies else 0
    return {
        "name": name,
        "rows": rows,
        "peak_footprint_gb": round(peak_footprint_bytes / (1024 ** 3), 2),
        "max_rss_gb": round(max_rss_bytes / (1024 ** 3), 2),
        "median_ms": round(statistics.median(latencies)) if latencies else 0,
        "p95_ms": p95,
        "mean_fuse_ms": round(statistics.mean(fuses)) if fuses else 0,
        "fuse_count": len(fuses),
        "total_segments": segs,
        "anomalies": anoms,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="*", help="Explicit .wav files to evaluate")
    parser.add_argument("--limit", type=int, default=35, help="Max recent recordings to evaluate when no files are passed")
    parser.add_argument("--stacks", nargs="*", help="Subset of stack names to run")
    parser.add_argument("--out", default="bench/results/recordings_eval.json")
    args = parser.parse_args()

    if args.files:
        wavs = [str(Path(f).expanduser()) for f in args.files if Path(f).expanduser().exists()]
    elif RECORDINGS_DIR.exists():
        all_wavs = sorted(RECORDINGS_DIR.glob("*.wav"), key=lambda p: p.name, reverse=True)
        wavs = [str(p) for p in (all_wavs[: args.limit] if args.limit > 0 else all_wavs)]
    else:
        wavs = []

    if not wavs:
        print("No recordings found!", file=sys.stderr)
        sys.exit(1)

    print(f"Evaluating on {len(wavs)} saved recordings...")

    # Original saved .txt baseline
    orig_texts = []
    for w in wavs:
        txt = Path(w).with_suffix(".txt")
        orig_texts.append(txt.read_text().strip() if txt.exists() else "")
    orig_anoms = count_anomalies(orig_texts)
    print(f"Original saved .txt anomalies ({len(orig_texts)} clips): {orig_anoms}")

    selected = [s for s in STACKS if not args.stacks or s[0] in args.stacks]
    results = {}
    for name, flags in selected:
        print(f"\n>>> Running {name}...")
        res = run_stack(name, flags, wavs)
        if res:
            results[name] = res
            print(
                f"    Peak Footprint: {res['peak_footprint_gb']} GB | Max RSS: {res['max_rss_gb']} GB | "
                f"Median: {res['median_ms']} ms | p95: {res['p95_ms']} ms | Segs: {res['total_segments']} | "
                f"Anomalies: {res['anomalies']}"
            )

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps({"original_anomalies": orig_anoms, "stacks": results}, indent=2))
    print(f"\nSaved full results to {out_path}")


if __name__ == "__main__":
    main()
