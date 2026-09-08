#!/usr/bin/env bash
# Job entrypoint for both doc-to-lora EC2 job types. Selects behavior via
# JOB_TYPE and wraps the real command with:
#   - GPU-count auto-detection, so the same image runs unmodified from
#     g7e.2xlarge (1 GPU) through g7e.48xlarge (8 GPU)
#   - S3 sync for inputs/outputs/checkpoints (nothing in the repo does this;
#     kept here rather than in ctx_to_lora so it stays an infra concern)
#   - Spot two-minute-warning handling: checkpoint + sync + clean exit
#
# Required env vars:
#   JOB_TYPE          "qa_gen" or "train"
#   CONFIG_PATH       (train only) path to the YAML config, e.g.
#                      configs/main_exp/gemma4/self_gen_lv1_closed_qa_1_l2l.yaml
# Optional env vars:
#   S3_BUCKET, S3_PREFIX   if unset, S3 sync is skipped entirely (local-only run)
#   RUN_NAME               defaults to timestamp_hostname; used only as the S3
#                           key for this job -- NOT the same as train.py's own
#                           internal run_name (see README for why)
#   CHECKPOINT_SYNC_INTERVAL_SEC   default 900 (15 min)
#   SPOT_POLL_INTERVAL_SEC         default 5
set -euo pipefail

: "${JOB_TYPE:?set JOB_TYPE=qa_gen or JOB_TYPE=train}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-doc-to-lora}"
RUN_NAME="${RUN_NAME:-$(date -u +%Y%m%dT%H%M%SZ)_$(hostname)}"
CHECKPOINT_SYNC_INTERVAL_SEC="${CHECKPOINT_SYNC_INTERVAL_SEC:-900}"
SPOT_POLL_INTERVAL_SEC="${SPOT_POLL_INTERVAL_SEC:-5}"
VENV_BIN=/app/.venv/bin

# Use the venv's binaries directly rather than `uv run` -- the image is
# already fully synced at build time, and this avoids `uv run`'s environment
# check adding a network round-trip to every job start.
PY="$VENV_BIN/python"
ACCELERATE="$VENV_BIN/accelerate"

NUM_GPUS="$(nvidia-smi -L | wc -l)"
echo "[entrypoint] JOB_TYPE=${JOB_TYPE} NUM_GPUS=${NUM_GPUS} RUN_NAME=${RUN_NAME} S3_BUCKET=${S3_BUCKET:-<none>}"

# These RTX PRO 6000 Blackwell (g7e) / RTX 5090 (dev) cards use PCIe P2P, not
# NVLink -- deliberately not setting NCCL_P2P_LEVEL=NVL. IB/EFA is irrelevant
# for the single-machine topology accelerate_config.yaml uses today.
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
export NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-1}"

s3_uri() { # $1 = subpath, e.g. "output"
    echo "s3://${S3_BUCKET}/${S3_PREFIX%/}/${JOB_TYPE}/${RUN_NAME}/${1}"
}

shared_s3_uri() { # $1 = subpath, e.g. "fw_qa_v2" -- job-run-independent, unlike s3_uri()
    echo "s3://${S3_BUCKET}/${S3_PREFIX%/}/inputs/${1}"
}

sync_up() { # $1 = local dir, $2 = subpath
    [[ -z "$S3_BUCKET" || ! -d "$1" ]] && return 0
    aws s3 sync "$1" "$(s3_uri "$2")" --only-show-errors
}

sync_down() { # $1 = subpath, $2 = local dir
    [[ -z "$S3_BUCKET" ]] && return 0
    mkdir -p "$2"
    aws s3 sync "$(s3_uri "$1")" "$2" --only-show-errors || true
}

CHILD_PID=""
WATCHER_PID=""
SYNCER_PID=""

final_sync() {
    case "$JOB_TYPE" in
        qa_gen) sync_up "data/raw_datasets/self_gen" "output" ;;
        train)  sync_up "train_outputs/runs" "output" ;;
    esac
}

shutdown() {
    echo "[entrypoint] shutting down (signal received)"
    [[ -n "$CHILD_PID" ]] && kill -TERM "$CHILD_PID" 2>/dev/null || true
    [[ -n "$CHILD_PID" ]] && wait "$CHILD_PID" 2>/dev/null || true
    [[ -n "$WATCHER_PID" ]] && kill "$WATCHER_PID" 2>/dev/null || true
    [[ -n "$SYNCER_PID" ]] && kill "$SYNCER_PID" 2>/dev/null || true
    final_sync
    exit 0
}
trap shutdown SIGTERM SIGINT

# Polls the instance metadata service for the Spot two-minute interruption
# warning (see https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html).
# Silently a no-op (curl fails fast) on On-Demand instances or off-EC2 runs.
spot_watcher() {
    while true; do
        sleep "$SPOT_POLL_INTERVAL_SEC"
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
            http://169.254.169.254/latest/meta-data/spot/instance-action || echo "000")
        if [[ "$code" == "200" ]]; then
            echo "[entrypoint] Spot interruption notice received"
            shutdown
        fi
    done
}
spot_watcher &
WATCHER_PID=$!

case "$JOB_TYPE" in
    qa_gen)
        if [[ -n "$S3_BUCKET" ]]; then
            aws s3 sync "$(shared_s3_uri "fw_qa_v2")" "data/raw_datasets/fw_qa_v2"
        fi
        if [[ -z "$(find data/raw_datasets/fw_qa_v2 -name '*.parquet' -print -quit 2>/dev/null)" ]]; then
            echo "[entrypoint] no fw_qa_v2 parquet files found after S3 sync -- aborting" >&2
            exit 1
        fi
        sync_down "output" "data/raw_datasets/self_gen"
        "$PY" data/self_generate_qa.py --num_gpus "$NUM_GPUS" "$@" &
        CHILD_PID=$!
        ;;

    train)
        : "${CONFIG_PATH:?set CONFIG_PATH=path/to/config.yaml for JOB_TYPE=train}"
        sync_down "output" "train_outputs/runs"

        # Resume granularity is "this RUN_NAME's whole train_outputs/runs tree",
        # not train.py's own internal run_name (which it derives fresh per launch
        # unless --resume_from_checkpoint is passed -- see train.py).
        RESUME_CKPT=$(find train_outputs/runs -mindepth 2 -maxdepth 2 -type d -name 'checkpoint-*' 2>/dev/null \
            | sort -t- -k2 -n | tail -1 || true)

        periodic_sync() {
            while true; do
                sleep "$CHECKPOINT_SYNC_INTERVAL_SEC"
                sync_up "train_outputs/runs" "output"
            done
        }
        periodic_sync &
        SYNCER_PID=$!

        if [[ -n "$RESUME_CKPT" ]]; then
            echo "[entrypoint] resuming from ${RESUME_CKPT}"
            "$ACCELERATE" launch --config_file accelerate_config.yaml \
                --num_processes "$NUM_GPUS" --gpu_ids all \
                train.py "$CONFIG_PATH" --resume_from_checkpoint="$RESUME_CKPT" "$@" &
        else
            "$ACCELERATE" launch --config_file accelerate_config.yaml \
                --num_processes "$NUM_GPUS" --gpu_ids all \
                train.py "$CONFIG_PATH" "$@" &
        fi
        CHILD_PID=$!
        ;;

    *)
        echo "[entrypoint] unknown JOB_TYPE '${JOB_TYPE}' (expected qa_gen or train)" >&2
        exit 1
        ;;
esac

set +e
wait "$CHILD_PID"
EXIT_CODE=$?
set -e

kill "$WATCHER_PID" 2>/dev/null || true
[[ -n "$SYNCER_PID" ]] && kill "$SYNCER_PID" 2>/dev/null || true
final_sync
exit "$EXIT_CODE"
