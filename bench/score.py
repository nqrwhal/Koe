"""Scores benchmark runs the way the Open ASR Leaderboard does: Whisper's English text normalizer
on references and hypotheses, corpus WER per test set, and the unweighted mean across sets.

usage: python bench/score.py Koe=bench/results/koe ...
Each prefix is completed with _<set>.jsonl; rows need "file" (or "id") and "text" (or "transcript").
"""
import json, statistics, sys
from pathlib import Path

import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

ROOT = Path(__file__).resolve().parent
SETS = ["librispeech_clean", "librispeech_other", "voxpopuli", "earnings22", "ami", "gigaspeech", "spgispeech",
        "common_voice", "fleurs_en"]
normalize = EnglishTextNormalizer()

def references(name):
    path = ROOT / "data" / name / "refs.jsonl"
    if not path.exists():
        return {}
    return {Path(r["file"]).stem: r["text"] for r in map(json.loads, open(path))}

def hypotheses(prefix, name):
    path = Path(f"{prefix}_{name}.jsonl")
    if not path.exists():
        return {}
    out = {}
    for line in open(path):
        if not line.startswith("{"):
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue  # a run still writing this file
        if r.get("type") not in (None, "clip"):
            continue
        file = r.get("file") or r.get("audio")
        key = Path(file).stem if file else r["id"]  # ids are already stems (some end in ".wav")
        out[key] = r.get("text", r.get("transcript", ""))
    return out

runs = [arg.split("=", 1) for arg in sys.argv[1:]]
header = f"{'':22}" + "".join(f"{label:>14}" for label, _ in runs)
print(header)
means = {label: [] for label, _ in runs}
for name in SETS:
    refs = references(name)
    if not refs:
        continue
    line = f"{name + f' ({len(refs)})':22}"
    for label, prefix in runs:
        hyps = hypotheses(prefix, name)
        scored = [k for k in refs if normalize(refs[k]).strip()]  # the leaderboard skips empty references
        keys = [k for k in scored if k in hyps]
        if len(keys) < len(scored) * 0.95:
            line += f"{'missing':>14}"
            continue
        wer = jiwer.wer([normalize(refs[k]) for k in keys], [normalize(hyps[k]) or "<empty>" for k in keys])
        means[label].append(wer)
        line += f"{100 * wer:13.2f}%"
    print(line)
print(f"{'mean':22}" + "".join(f"{100 * statistics.mean(v):13.2f}%" if v else f"{'—':>14}" for v in means.values()))
