#!/usr/bin/env bash
set -euo pipefail

# === USER CONFIG ===
MODEL="deepseek-ai/DeepSeek-R1-0528"
#MODEL="facebook/opt-125m"
VLLM_PORT=8000
TEST_SCRIPT="SUT_DeepSeek_Offline.py"   # your evaluation script

# Example parameter combinations
PARAM_COMBINATIONS=(
  "--gpu-memory-utilization 0.9 --max-model-len 24576 -tp 8 -dcp 8 --enable-expert-parallel --enable-eplb"
  "--gpu-memory-utilization 0.9 --max-model-len 24576 -tp 4 -dp 2 -dcp 4"
  "--gpu-memory-utilization 0.9 --max-model-len 24576 -tp 4 -dp 2 -dcp 4 --enable-expert-parallel"
  "--gpu-memory-utilization 0.9 --max-model-len 24576 -tp 2 -dp 4 -dcp 2"
  "--gpu-memory-utilization 0.9 --max-model-len 24576 -tp 2 -dp 4 -dcp 2 --enable-expert-parallel"
  "--gpu-memory-utilization 0.9 --max-model-len 24576 -dp 8 "
  "--gpu-memory-utilization 0.9 --max-model-len 24576 -tp 2 -dp 4 "
  "--gpu-memory-utilization 0.9 --max-model-len 24576 -tp 4 -dp 2 "
)

# Max wait time for vLLM server startup (15 minutes)
MAX_WAIT_SEC=1200
SUMMARY_CSV="summary.csv"

# Write CSV header
echo "index,params,status,runtime_sec,vllm_log,test_log,cleanup_ok" >"$SUMMARY_CSV"

wait_for_vllm() {
  echo "⏳ Waiting (max ${MAX_WAIT_SEC}s) for vLLM server on port $VLLM_PORT..."
  local start_ts
  start_ts=$(date +%s)

  while true; do
    if curl -s "http://localhost:$VLLM_PORT/v1/models" >/dev/null 2>&1; then
      echo "✅ vLLM server is ready."
      return 0
    fi

    sleep 5
    local now_ts
    now_ts=$(date +%s)
    if (( now_ts - start_ts > MAX_WAIT_SEC )); then
      echo "❌ Timed out after ${MAX_WAIT_SEC}s waiting for vLLM server."
      return 1
    fi
  done
}

force_cleanup() {
  local cleanup="ok"
  echo "🔍 Checking for leftover vLLM/Python processes..."

  # Kill leftover vllm serve processes if any
  if pgrep -f "vllm serve" >/dev/null; then
    echo "⚠️ Found leftover vLLM serve processes, killing..."
    pkill -9 -f "vllm serve" || true
    cleanup="fixed"
  fi

  # Kill any Python processes still holding GPU memory
  for pid in $(nvidia-smi --query-compute-apps=pid --format=csv,noheader | xargs || true); do
    pname=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    if [[ "$pname" == "python"* ]]; then
      echo "⚠️ Killing Python process $pid still using GPU memory..."
      kill -9 "$pid" || true
      cleanup="fixed"
    fi
  done

  # Wait until GPU memory is clear
  echo "⏳ Waiting for GPU memory to be fully released..."
  for i in {1..60}; do
    if ! nvidia-smi | grep -q "python"; then
      echo "✅ GPU memory is clear."
      return 0
    fi
    sleep 5
  done

  echo "⚠️ GPU memory still allocated after cleanup attempts."
  return 1
}

# === MAIN LOOP ===
for i in "${!PARAM_COMBINATIONS[@]}"; do
  PARAMS="${PARAM_COMBINATIONS[$i]}"
  echo "========================================"
  echo "🚀 Launching vLLM serve with params (index $i): $PARAMS"
  echo "========================================"

  VLLM_LOG="vllm_run_${i}.log"
  TEST_LOG="test_run_${i}.log"
  START_TS=$(date +%s)
  STATUS="success"
  CLEANUP_STATUS="ok"

  # Launch vLLM in background with vllm serve
  vllm serve "$MODEL" \
    --port "$VLLM_PORT" \
    $PARAMS >"$VLLM_LOG" 2>&1 &
  VLLM_PID=$!

  # Wait for vLLM to come online
  if ! wait_for_vllm; then
    echo "Killing vLLM (PID $VLLM_PID) due to startup failure."
    kill -9 $VLLM_PID || true
    STATUS="timeout"
    END_TS=$(date +%s)
    RUNTIME=$((END_TS - START_TS))
    if force_cleanup; then CLEANUP_STATUS="ok"; else CLEANUP_STATUS="fail"; fi
    echo "$i,\"$PARAMS\",$STATUS,$RUNTIME,$VLLM_LOG,$TEST_LOG,$CLEANUP_STATUS" >>"$SUMMARY_CSV"
    continue
  fi

  # Run your test script with logging
  echo "▶️ Running test script: $TEST_SCRIPT"
  if ! python3 ${TEST_SCRIPT} --model ${MODEL} --dataset-path datasets/mlperf_deepseek_r1_dataset_4388_fp8_eval.pkl --api-server-url http://localhost:8000 >"$TEST_LOG" 2>&1; then
    STATUS="test_failed"
  fi

  # Kill vLLM server once script is done
  echo "🛑 Killing vLLM server (PID $VLLM_PID)..."
  kill $VLLM_PID
  wait $VLLM_PID || true

  END_TS=$(date +%s)
  RUNTIME=$((END_TS - START_TS))
  if force_cleanup; then CLEANUP_STATUS="ok"; else CLEANUP_STATUS="fail"; fi

  echo "$i,\"$PARAMS\",$STATUS,$RUNTIME,$VLLM_LOG,$TEST_LOG,$CLEANUP_STATUS" >>"$SUMMARY_CSV"

  echo "✅ Done with params index $i (status=$STATUS, runtime=${RUNTIME}s, cleanup=$CLEANUP_STATUS)"
  echo
done

echo "🎉 All parameter sweeps completed."
echo "📊 Summary written to $SUMMARY_CSV"
