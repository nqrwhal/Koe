"""Samples clips from the Open ASR Leaderboard test sets (hf-audio/open-asr-leaderboard parquet)
into 16 kHz WAVs plus references, so every system is scored on exactly the same audio.

usage: python bench/prepare.py [clips per set]
Reads bench/data/raw/<config>/*.parquet (see bench/run.sh), writes bench/data/<set>/<id>.wav and refs.jsonl.
"""
import io, json, random, sys
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

ROOT = Path(__file__).resolve().parent / "data"
PER_SET = int(sys.argv[1]) if len(sys.argv) > 1 else 500
SETS = {  # name: (config folder, filename prefix)
    "librispeech_clean": ("librispeech", "test.clean"),
    "librispeech_other": ("librispeech", "test.other"),
    "voxpopuli": ("voxpopuli", "test"),
    "earnings22": ("earnings22", "test"),
    "ami": ("ami", "test"),
    "common_voice": ("common_voice", "test"),
    "gigaspeech": ("gigaspeech", "test"),
    "spgispeech": ("spgispeech", "test"),
}

def resample(audio, rate):
    if rate == 16_000:
        return audio
    positions = np.arange(0, len(audio), rate / 16_000)
    return np.interp(positions, np.arange(len(audio)), audio).astype(np.float32)

for name, (config, prefix) in SETS.items():
    shards = sorted((ROOT / "raw" / config).glob(f"{prefix}-*.parquet"))
    if not shards:
        print(f"{name}: no data, skipped")
        continue
    # Pick clips from the light columns first, then decode only their audio.
    rows = []
    for shard in shards:
        table = pq.read_table(shard, columns=["id", "text"])
        rows += [(shard, i, str(id_), text) for i, (id_, text) in
                 enumerate(zip(table["id"].to_pylist(), table["text"].to_pylist())) if text and text.strip()]
    random.Random(0).shuffle(rows)
    chosen = rows[:PER_SET]
    out = ROOT / name
    out.mkdir(parents=True, exist_ok=True)
    refs = []
    for shard in sorted({r[0] for r in chosen}):
        picks = [r for r in chosen if r[0] == shard]
        audio = pq.read_table(shard, columns=["audio"])["audio"].take([r[1] for r in picks]).to_pylist()
        for (_, _, id_, text), clip in zip(picks, audio):
            samples, rate = sf.read(io.BytesIO(clip["bytes"]), dtype="float32")
            if samples.ndim > 1:
                samples = samples.mean(axis=1)
            file = out / f"{id_.replace('/', '_')}.wav"
            sf.write(file, resample(samples, rate), 16_000, subtype="FLOAT")
            refs.append({"id": id_, "file": str(file), "text": text})
    with open(out / "refs.jsonl", "w") as f:
        for r in refs:
            f.write(json.dumps(r) + "\n")
    print(f"{name}: {len(refs)} clips from {len(rows)} ({len(shards)} shards)")

# FLEURS English test (one of the public sets Wispr Flow reports): all 647 clips, original transcripts.
fleurs = ROOT / "raw" / "fleurs"
if (fleurs / "test.tsv").exists():
    refs = []
    for line in open(fleurs / "test.tsv"):
        cols = line.rstrip("\n").split("\t")
        file = fleurs / "audio" / "test" / cols[1]
        if file.exists() and cols[2].strip():
            refs.append({"id": file.stem, "file": str(file), "text": cols[2]})
    (ROOT / "fleurs_en").mkdir(exist_ok=True)
    with open(ROOT / "fleurs_en" / "refs.jsonl", "w") as f:
        for r in refs:
            f.write(json.dumps(r) + "\n")
    print(f"fleurs_en: {len(refs)} clips")
