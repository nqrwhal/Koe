#!/bin/zsh
# Reproduces Koe's numbers in the README: downloads the Open ASR Leaderboard test shards used and
# FLEURS English (about 6.4 GB, plus 2 GB of sampled clips, all in bench/data), samples 500 clips
# per set, runs `Koe --eval` and scores it.
# Needs Koe built (./build.sh) and Python with: numpy pyarrow soundfile jiwer whisper-normalizer
set -euo pipefail
cd "$(dirname "$0")"
koe=${KOE:-$HOME/Applications/Koe.app/Contents/MacOS/Koe}  # or set KOE to another build
hub=https://huggingface.co/datasets

# The leaderboard's own data; GigaSpeech and SPGISpeech are large, so three shards spread across
# each (they're sorted by clip length) are enough to sample from.
files=(librispeech/test.clean-00000-of-00001 librispeech/test.other-00000-of-00001)
for i in 0 1 2 3; do files+=(voxpopuli/test-0000$i-of-00004); done
for i in 0 1 2 3 4; do files+=(earnings22/test-0000$i-of-00005); done
for i in $(seq -w 0 14); do files+=(ami/test-000$i-of-00015); done
for i in 0 1 2; do files+=(common_voice/test-0000$i-of-00003); done
files+=(gigaspeech/test-00000-of-00019 gigaspeech/test-00009-of-00019 gigaspeech/test-00018-of-00019)
files+=(spgispeech/test-00000-of-00038 spgispeech/test-00018-of-00038 spgispeech/test-00037-of-00038)
for file in $files; do
    mkdir -p data/raw/${file:h}
    [[ -s data/raw/$file.parquet ]] || curl -fsSL -o data/raw/$file.parquet "$hub/hf-audio/open-asr-leaderboard/resolve/main/$file.parquet"
done
mkdir -p data/raw/fleurs
[[ -s data/raw/fleurs/test.tsv ]] || curl -fsSL -o data/raw/fleurs/test.tsv "$hub/google/fleurs/resolve/main/data/en_us/test.tsv"
if [[ ! -d data/raw/fleurs/audio/test ]]; then
    curl -fsSL "$hub/google/fleurs/resolve/main/data/en_us/audio/test.tar.gz" | (mkdir -p data/raw/fleurs/audio && tar -xz -C data/raw/fleurs/audio)
fi

python3 prepare.py 500
mkdir -p results
for refs in data/*/refs.jsonl; do
    set_name=${refs:h:t}
    python3 -c "import json;[print(json.loads(l)['file']) for l in open('$refs')]" | sort -u | xargs $koe --eval 2>/dev/null | grep '^{' > results/koe_$set_name.jsonl
done
python3 score.py Koe=results/koe
