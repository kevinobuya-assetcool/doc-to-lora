"""Quick smoke test for D2L using a checkpoint downloaded from the Hugging Face Hub.

Downloads `gemma_demo/checkpoint-80000/pytorch_model.bin` from SakanaAI/doc-to-lora,
internalizes a custom test document, and compares the answer with/without the
internalized LoRA adapters applied.

Usage:
    # --no-sync avoids uv reverting torch to the pyproject-pinned (pre-Blackwell) version
    uv run --no-sync examples/test_remote_checkpoint.py
"""

import torch
from huggingface_hub import hf_hub_download

from ctx_to_lora.model_loading import get_tokenizer
from ctx_to_lora.modeling.hypernet import ModulatedPretrainedModel

REPO_ID = "SakanaAI/doc-to-lora"
CHECKPOINT_SUBPATH = "gemma_demo/checkpoint-80000/pytorch_model.bin"
DOC_PATH = "test-context-data.txt"
QUESTION = "What is the Emergency Override Code for System Aether-X?"

# download checkpoint from the hub (cached after first run)
checkpoint_path = hf_hub_download(repo_id=REPO_ID, filename=CHECKPOINT_SUBPATH)

# model loading
state_dict = torch.load(checkpoint_path, weights_only=False)
model = ModulatedPretrainedModel.from_state_dict(
    state_dict, train=False, use_sequence_packing=False
)
model.reset()
tokenizer = get_tokenizer(model.base_model.name_or_path)

# prepare data
doc = open(DOC_PATH, "r").read()
chat = [{"role": "user", "content": QUESTION}]
chat_ids = tokenizer.apply_chat_template(
    chat,
    add_special_tokens=False,
    return_attention_mask=False,
    add_generation_prompt=True,
    return_tensors="pt",
).to(model.device)

# baseline: without internalized info, the model has no knowledge of the doc
model.reset()
baseline_outputs = model.generate(input_ids=chat_ids, max_new_tokens=512)
baseline_answer = tokenizer.decode(baseline_outputs[0])

# calls after internalization will be influenced by internalized info
model.internalize(doc)
internalized_outputs = model.generate(input_ids=chat_ids, max_new_tokens=512)
internalized_answer = tokenizer.decode(internalized_outputs[0])

print("=== Without LoRA adapters (no internalized context) ===")
print(baseline_answer)
print()
print("=== With LoRA adapters (internalized context) ===")
print(internalized_answer)
