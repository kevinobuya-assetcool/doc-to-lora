# Same pipeline as gen_data.sh with gemma-4-E4B-it as the self-gen responder.
# The question generator (gemma-3-12b-it) and its outputs are shared across base models,
# so re-run only the self_generate_qa.py steps if gen_data.sh has already been run.

# Recover the shared fw_qa_v2 questions from the published gemma-2 self-gen data instead
# of re-running both gemma-3-12b-it passes (and the 286GB fineweb-edu download).
# To regenerate from scratch instead, run the two commented-out blocks below.
uv run data/reconstruct_fw_qa_from_hub.py

# uv run data/download_fineweb_edu.py

# Number of GPUs for self_generate_qa.py to use. NUM_GPUS=1 (default) preserves
# the original single-GPU behavior. Set e.g.
# `NUM_GPUS=4 uv run bash scripts/main_exp/gen_data_gemma4.sh` to have each
# self_generate_qa.py invocation below shard its work across 4 GPUs internally
# (see the --num_gpus flag in data/self_generate_qa.py).
NUM_GPUS="${NUM_GPUS:-1}"

# generate qa data
# run from 000 to 013
for shard_id in $(seq -f "%03g" 0 13); do
  # uv run data/generate_fw_edu_qa_v2.py --shard_pattern "${shard_id}_00000" --n_qa_pairs=5 --vllm_model=google/gemma-3-12b-it --max_length=2000 --max_model_length=2048
  # uv run data/generate_fw_edu_qa_v2_repeat.py --shard_pattern "min_0_to_2000/${shard_id}*level_0" --n_qa_pairs=5 --vllm_model=google/gemma-3-12b-it

  # self-generated response QA data
  uv run data/self_generate_qa.py --vllm_model google/gemma-4-E4B-it --glob_pattern "data/raw_datasets/fw_qa_v2/min_0_to_2000/${shard_id}*_level_1*" --closed_qa_prob 1.0 --num_gpus "$NUM_GPUS"
done


# val split
uv run data/self_generate_qa.py --vllm_model google/gemma-4-E4B-it --glob_pattern 'data/raw_datasets/fw_qa_v2/min_0_to_2000/*_level_0_val.parquet' --num_gpus "$NUM_GPUS"

# self-gen data for other ds
uv run data/self_generate_qa.py --vllm_model google/gemma-4-E4B-it --ds_names squad_compact ropes_compact drop_compact --split train --closed_qa_prob 1.0 --num_gpus "$NUM_GPUS"
uv run data/self_generate_qa.py --vllm_model google/gemma-4-E4B-it --ds_names pwc_compact --split train --closed_qa_prob 0.0 --num_gpus "$NUM_GPUS"
