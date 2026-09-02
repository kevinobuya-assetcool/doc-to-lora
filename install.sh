curl -LsSf https://astral.sh/uv/install.sh | sh
uv self update
uv venv --python 3.10 --seed
# torch is pinned transitively by vllm; installing it separately would be overridden by uv sync
uv sync
# flash-attn publishes no wheel for torch>=2.10, so models fall back to sdpa attention

# download squad dataset
HF_HUB_ENABLE_HF_TRANSFER=1 uv run huggingface-cli download --repo-type dataset rajpurkar/squad --local-dir data/raw_datasets/squad
uv run data/build_drop_compact.py
uv run data/build_pwc_compact.py
uv run data/build_ropes_compact.py
uv run data/build_squad_compact.py

# optional: needed for gated models
# uv run huggingface-cli login

# optional: needed for logging with wandb
# wandb login

# optional: dev
# uv run pre-commit install
