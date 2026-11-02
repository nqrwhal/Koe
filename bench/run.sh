#!/bin/zsh
# Reproduces Koe's numbers in the README: downloads the public sets of the Open ASR Leaderboard's
# default average, Common Voice and FLEURS English (about 8.5 GB, plus 2 GB of sampled clips, all in
# bench/data), samples up to 500 clips per set, runs `Koe --eval` and scores it.
# Needs Koe built (./build.sh) and Python with: numpy pyarrow soundfile jiwer whisper-normalizer
set -euo pipefail
cd "$(dirname "$0")"
koe=${KOE:-$HOME/Applications/Koe.app/Contents/MacOS/Koe}  # or set KOE to another build
hub=https://huggingface.co/datasets

# The leaderboard's own data; GigaSpeech and SPGISpeech are large, so three shards spread across
# each (they're sorted by clip length) are enough to sample from.
files=(librispeech/test.clean-00000-of-00001 librispeech/test.other-00000-of-00001)
for i in 0 1 2; do files+=(ami_cleaned/test-0000$i-of-00003 common_voice/test-0000$i-of-00003); done
files+=(gigaspeech_cleaned/test-00000-of-00008 gigaspeech_cleaned/test-00003-of-00008 gigaspeech_cleaned/test-00007-of-00008)
files+=(spgispeech/test-00000-of-00038 spgispeech/test-00018-of-00038 spgispeech/test-00037-of-00038)
files+=(voxpopuli_cleaned_aa/test-00000-of-00001 urgent2024/test-00000-of-00001)
for file in $files; do
    mkdir -p data/raw/${file:h}
    [[ -s data/raw/$file.parquet ]] || curl -fsSL -o data/raw/$file.parquet "$hub/hf-audio/open-asr-leaderboard/resolve/main/$file.parquet"
done
mkdir -p data/raw/monsoon
for i in 0 1 2 3; do
    file=data/raw/monsoon/test-0000$i-of-00004.parquet
    [[ -s $file ]] || curl -fsSL -o $file "$hub/VoiceArena/MonsoonASR-Open-ASR-leaderboard-en-IN/resolve/main/data/${file:t}"
done
# Earnings-22 (cleaned) is Artificial Analysis' chunked version, scored against full call transcripts.
earnings=data/raw/earnings22_chunked
mkdir -p $earnings/audio
[[ -s $earnings/chunks.jsonl ]] || curl -fsSL -o $earnings/chunks.jsonl "$hub/ArtificialAnalysis/Earnings22-Cleaned-AA-chunked/resolve/main/earnings22_cleaned_aa_chunked_v1.jsonl"
[[ -s $earnings/transcripts.jsonl ]] || curl -fsSL -o $earnings/transcripts.jsonl "$hub/ArtificialAnalysis/Earnings22-Cleaned-AA/resolve/main/earnings22_cleaned_aa_v1.jsonl"
for name in $(python3 -c "import json;[print(json.loads(l)['file_name']) for l in open('$earnings/chunks.jsonl')]"); do
    [[ -s $earnings/audio/$name ]] || curl -fsSL -o $earnings/audio/$name "$hub/ArtificialAnalysis/Earnings22-Cleaned-AA-chunked/resolve/main/audio/$name"
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
