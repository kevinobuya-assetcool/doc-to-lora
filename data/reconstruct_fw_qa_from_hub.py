"""Rebuild `data/raw_datasets/fw_qa_v2/` from a published self-gen subset on the Hub.

The fw_qa_v2 questions are produced by `gemma-3-12b-it` and are independent of the
base model, so they can be recovered from any published subset of
`SakanaAI/self_gen_qa_d2l` instead of re-running both generation passes. Only the
`ctx_ids` / `input_ids` / `response_start_end` columns are fetched; the logprob
columns (~88% of each file) are skipped via parquet column projection.
"""

import argparse
import os
import re
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

import pyarrow as pa
import pyarrow.parquet as pq
from huggingface_hub import HfApi, HfFileSystem

from ctx_to_lora.data.definitions import CLOSED_QA_INTX_TEMPLATES
from ctx_to_lora.model_loading import get_tokenizer

COLUMNS = ["ctx_ids", "input_ids", "response_start_end"]

# `ds_{shard}_{part}_level_{n}[_val]_{chunk}.parquet`
FNAME_RE = re.compile(
    r"^ds_(?P<shard>\d{3}_\d{5})_level_(?P<level>\d+)(?P<val>_val)?_(?P<chunk>\d{4})\.parquet$"
)


def build_closed_qa_patterns() -> list[re.Pattern]:
    patterns = []
    for tpl in CLOSED_QA_INTX_TEMPLATES:
        pre, post = tpl.split("{input}")
        patterns.append(
            re.compile(rf"^{re.escape(pre)}(?P<q>.*?){re.escape(post)}$", flags=re.S)
        )
    return patterns


def strip_closed_qa(question: str, patterns: list[re.Pattern]) -> str:
    for pat in patterns:
        m = pat.match(question)
        if m:
            return m.group("q").strip()
    return question.strip()


def unwrap(text: str, prefix: str, suffix: str) -> str | None:
    if not (text.startswith(prefix) and text.endswith(suffix)):
        return None
    return text[len(prefix) : len(text) - len(suffix)].strip()


def render_wrappers(tk) -> tuple[str, str, str]:
    """Recover the chat-template prefixes/suffix by rendering sentinel messages."""
    ctx_render = tk.decode(
        tk.apply_chat_template(
            [{"role": "system", "content": ""}, {"role": "user", "content": "\x00"}],
            tokenize=True,
            add_generation_prompt=True,
            add_special_tokens=False,
        )
    )
    qa_render = tk.decode(
        tk.apply_chat_template(
            [{"role": "user", "content": "\x00"}],
            tokenize=True,
            add_generation_prompt=True,
            add_special_tokens=False,
        )
    )
    ctx_prefix, turn_suffix = ctx_render.split("\x00")
    qa_prefix, qa_suffix = qa_render.split("\x00")
    if qa_suffix != turn_suffix:
        raise RuntimeError(f"Inconsistent chat template suffixes: {qa_suffix!r} vs {turn_suffix!r}")
    return ctx_prefix, qa_prefix, turn_suffix


def list_source_files(repo_id: str, subset: str, ds_dir: str) -> dict[tuple, list[str]]:
    api = HfApi()
    info = api.repo_info(repo_id, repo_type="dataset")
    prefix = f"{subset}/{ds_dir}/"

    groups = defaultdict(list)
    for sibling in info.siblings:
        name = sibling.rfilename
        if not name.startswith(prefix):
            continue
        m = FNAME_RE.match(os.path.basename(name))
        if not m:
            continue
        key = (m.group("shard"), int(m.group("level")), bool(m.group("val")))
        groups[key].append((int(m.group("chunk")), name))

    return {k: [n for _, n in sorted(v)] for k, v in sorted(groups.items())}


def read_projected(repo_id: str, path: str, retries: int = 3) -> pa.Table:
    last_err = None
    for _ in range(retries):
        try:
            fs = HfFileSystem()
            with fs.open(f"datasets/{repo_id}/{path}", "rb") as f:
                return pq.ParquetFile(f).read(columns=COLUMNS)
        except Exception as err:  # network flakiness on large listings
            last_err = err
    raise RuntimeError(f"Failed to read {path}: {last_err}")


def decode_table(table: pa.Table, tk, wrappers, patterns) -> list[dict]:
    ctx_prefix, qa_prefix, turn_suffix = wrappers
    rows = table.to_pylist()

    contexts = tk.batch_decode(
        [r["ctx_ids"] for r in rows], skip_special_tokens=False
    )

    flat_prompt_ids, flat_response_ids, owners = [], [], []
    for i, r in enumerate(rows):
        for ids, (start, end) in zip(r["input_ids"], r["response_start_end"]):
            flat_prompt_ids.append(ids[:start])
            flat_response_ids.append(ids[start:end])
            owners.append(i)

    prompts = tk.batch_decode(flat_prompt_ids, skip_special_tokens=False)
    responses = tk.batch_decode(flat_response_ids, skip_special_tokens=True)

    per_row = defaultdict(lambda: ([], []))
    for owner, prompt, response in zip(owners, prompts, responses):
        question = unwrap(prompt, qa_prefix, turn_suffix)
        if question is None:
            continue
        qs, rs = per_row[owner]
        qs.append(strip_closed_qa(question, patterns))
        rs.append(response.strip())

    out = []
    for i, raw_ctx in enumerate(contexts):
        context = unwrap(raw_ctx, ctx_prefix, turn_suffix)
        if context is None:
            continue
        qs, rs = per_row.get(i, ([], []))
        if not qs:
            continue
        out.append({"context": context, "questions": qs, "responses": rs})
    return out


def reconstruct_group(key, files, args, tk, wrappers, patterns) -> None:
    shard, level, is_val = key
    suffix = "_val" if is_val else ""
    out_path = os.path.join(args.out_dir, f"{shard}_level_{level}{suffix}.parquet")

    if os.path.exists(out_path) and not args.overwrite:
        print(f"skip (exists): {out_path}")
        return

    q_col = f"prompts_level_{level}"
    r_col = f"responses_level_{level}"
    schema = pa.schema(
        [
            pa.field("context", pa.string()),
            pa.field(q_col, pa.list_(pa.string())),
            pa.field(r_col, pa.list_(pa.string())),
        ]
    )

    os.makedirs(args.out_dir, exist_ok=True)
    tmp_path = out_path + ".tmp"
    n_rows = 0

    with pq.ParquetWriter(tmp_path, schema) as writer:
        with ThreadPoolExecutor(max_workers=args.num_workers) as pool:
            # fetch in bounded batches so decoded tables don't accumulate in memory
            for start in range(0, len(files), args.num_workers):
                batch = files[start : start + args.num_workers]
                for table in pool.map(
                    lambda p: read_projected(args.repo_id, p), batch
                ):
                    decoded = decode_table(table, tk, wrappers, patterns)
                    if not decoded:
                        continue
                    writer.write_table(
                        pa.Table.from_pydict(
                            {
                                "context": [d["context"] for d in decoded],
                                q_col: [d["questions"] for d in decoded],
                                r_col: [d["responses"] for d in decoded],
                            },
                            schema=schema,
                        )
                    )
                    n_rows += len(decoded)

    os.replace(tmp_path, out_path)
    print(f"wrote {n_rows} rows from {len(files)} files -> {out_path}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Rebuild fw_qa_v2 from a published self-gen dataset"
    )
    parser.add_argument("--repo_id", type=str, default="SakanaAI/self_gen_qa_d2l")
    parser.add_argument(
        "--subset",
        type=str,
        default="google/gemma-2-2b-it_temp_0.0_closed_qa_prob_1.0",
        help="Model subset to source the questions from (any subset works)",
    )
    parser.add_argument(
        "--tokenizer",
        type=str,
        default="google/gemma-2-2b-it",
        help="Tokenizer used to encode the chosen subset",
    )
    parser.add_argument("--ds_dir", type=str, default="fw_qa_v2/min_0_to_2000/train")
    parser.add_argument(
        "--out_dir", type=str, default="data/raw_datasets/fw_qa_v2/min_0_to_2000"
    )
    parser.add_argument(
        "--shards",
        type=str,
        nargs="+",
        default=None,
        help="Shard ids to rebuild, e.g. 000_00000 (default: all found)",
    )
    parser.add_argument(
        "--levels",
        type=int,
        nargs="+",
        default=[0, 1],
        help="QA levels to rebuild (default: 0 1)",
    )
    parser.add_argument("--num_workers", type=int, default=8)
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()

    tk = get_tokenizer(args.tokenizer, train=True)
    wrappers = render_wrappers(tk)
    patterns = build_closed_qa_patterns()

    groups = list_source_files(args.repo_id, args.subset, args.ds_dir)
    if not groups:
        raise SystemExit(f"No source files under {args.subset}/{args.ds_dir}")

    selected = {
        k: v
        for k, v in groups.items()
        if (args.shards is None or k[0] in args.shards) and k[1] in args.levels
    }
    if not selected:
        raise SystemExit("No groups matched the requested shards/levels")

    print(f"Rebuilding {len(selected)} group(s) from {args.repo_id}/{args.subset}")
    os.environ["TOKENIZERS_PARALLELISM"] = "true"
    for key, files in selected.items():
        print(f"-- shard={key[0]} level={key[1]} val={key[2]} files={len(files)}")
        reconstruct_group(key, files, args, tk, wrappers, patterns)
