#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/packages/app/Yappatron"
FIXTURE_NAME="${YAPPATRON_BENCH_FIXTURE:-deepgram-cutoff-bait}"
EXPECTED="$ROOT_DIR/bench/fixtures/$FIXTURE_NAME.expected.txt"
AUDIO="$ROOT_DIR/bench/generated/$FIXTURE_NAME.aiff"
RESULTS_DIR="$ROOT_DIR/bench/results"
CHUNKS="${YAPPATRON_BENCH_CHUNKS:-1365,512,256}"
POST_ROLL_MS="${YAPPATRON_BENCH_POST_ROLL_MS:-3200}"

if [[ $# -gt 0 ]]; then
  cd "$PACKAGE_DIR"
  swift run -c release Yappatron --deepgram-benchmark "$@"
  exit 0
fi

if [[ ! -f "$EXPECTED" ]]; then
  echo "Missing expected transcript: $EXPECTED" >&2
  exit 2
fi

mkdir -p "$(dirname "$AUDIO")" "$RESULTS_DIR"

if [[ ! -f "$AUDIO" ]]; then
  SPEECH_TEXT="$(cat "$EXPECTED")"
  SPEECH_TEXT="${SPEECH_TEXT/. I am going to pause here/. [[slnc 1100]] I am going to pause here}"
  say -v "${YAPPATRON_BENCH_VOICE:-Samantha}" -r "${YAPPATRON_BENCH_RATE:-175}" -o "$AUDIO" "$SPEECH_TEXT"
fi

if [[ -z "${DEEPGRAM_API_KEY:-}" ]]; then
  export DEEPGRAM_API_KEY="$(defaults read com.yappatron.app 'apiKey_Deepgram' 2>/dev/null || true)"
fi

if [[ -z "${DEEPGRAM_API_KEY:-}" ]]; then
  echo "Missing Deepgram key. Set DEEPGRAM_API_KEY or save the key in the Mac app first." >&2
  exit 2
fi

cd "$PACKAGE_DIR"
swift build -c release

STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="$RESULTS_DIR/deepgram-latency-$STAMP.csv"
printf 'run_id,fixture,audio_path,chunk_frames,chunk_ms,audio_duration_ms,provider_start_ms,first_partial_ms,first_partial_after_audio_start_ms,first_locked_final_ms,first_final_ms,audio_end_ms,final_after_audio_end_ms,partial_count,avg_partial_interval_ms,max_partial_gap_ms,churn_score,wer,cer,final_text\n' > "$CSV"

IFS=',' read -ra CHUNK_VALUES <<< "$CHUNKS"
for chunk in "${CHUNK_VALUES[@]}"; do
  chunk="$(echo "$chunk" | tr -d '[:space:]')"
  [[ -n "$chunk" ]] || continue
  JSON="$RESULTS_DIR/deepgram-latency-$STAMP-chunk-$chunk.json"
  echo "Running Deepgram latency bench: chunk_frames=$chunk"
  "$PACKAGE_DIR/.build/release/Yappatron" \
    --deepgram-benchmark \
    --audio "$AUDIO" \
    --expected "$EXPECTED" \
    --chunk-frames "$chunk" \
    --post-roll-ms "$POST_ROLL_MS" \
    --json "$JSON" \
    --csv "$CSV"
done

echo "CSV: $CSV"
