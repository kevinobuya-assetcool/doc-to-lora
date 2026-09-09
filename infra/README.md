# doc-to-lora on EC2 G7e

Plain-EC2 deployment (Launch Template + Fleet, no Batch/SageMaker) for the two
job types in this repo -- QA generation (`data/self_generate_qa.py`) and
hypernetwork training (`train.py`) -- on **G7e** instances (NVIDIA RTX PRO
6000 Blackwell Server Edition, 1-8 GPUs depending on size). See
`docker/` for the job image itself.

## One-time setup

### 1. Build and push the image

```
AWS_REGION=us-east-1 ECR_REPOSITORY=doc-to-lora docker/build_and_push.sh
```

Do this once per code/dependency change. Job launches only ever `docker pull`
-- never `uv sync` cold -- since installing torch/vllm/deepspeed/bitsandbytes
(CUDA 13 wheels) takes several minutes, real money at ~$33/hr for a
`g7e.48xlarge`.

### 2. Build the golden AMI

Launch a plain Ubuntu 24.04 instance (any type -- doesn't need a GPU for this
step... except the final validation, so easiest on a `g7e.2xlarge`), copy
`infra/ami/bootstrap.sh` to it, run it, reboot, then validate **before**
snapshotting:

```
nvidia-smi
docker run --rm --gpus all nvidia/cuda:13.0.3-base-ubuntu24.04 nvidia-smi
```

Both must succeed. Then snapshot the instance as an AMI and note its ID.

Why a custom AMI instead of installing the driver/toolkit in user-data on
every launch: at ~$33/hr, a driver+toolkit install (several minutes) burns
real money on every single job start. Baking it once means every launch is
just `docker pull && docker run`.

Why the plain NVIDIA driver and not AWS's "gaming" or "GRID" driver docs for
G7e: those are for cloud-gaming-streaming and virtual-desktop (vGPU)
licensing respectively. A dedicated training instance gets the whole GPU via
plain passthrough (no display, no multi-tenant partitioning), and the
standard NVIDIA driver handles CUDA compute workloads with no license
server involved. `bootstrap.sh` was validated against this exact recipe
(`nvidia-driver-open`, `nvidia-container-toolkit`) on a local RTX 5090 --
same Blackwell (sm_120) compute capability as the G7e's RTX PRO 6000.

Re-run this whenever the driver/CUDA requirement changes; it doesn't need
rebuilding when the app code changes (that's a new image tag, not a new AMI).

### 3. IAM role for the instances

```
aws iam create-role --role-name doc-to-lora-job \
  --assume-role-policy-document file://infra/iam/ec2-trust-policy.json

aws iam put-role-policy --role-name doc-to-lora-job \
  --policy-name doc-to-lora-job-access \
  --policy-document file://infra/iam/instance-policy.json

aws iam create-instance-profile --instance-profile-name doc-to-lora-job
aws iam add-role-to-instance-profile \
  --instance-profile-name doc-to-lora-job --role-name doc-to-lora-job
```

Scoped to just the job bucket/prefix and ECR image pulls -- no static
credentials anywhere in the image or AMI. `infra/iam/instance-policy.json`
already has this project's real bucket/prefix baked in
(`doc-to-lora-jobs`, `dev/*`) rather than template placeholders -- **every
job must be submitted with `S3_PREFIX=dev`** (see below); `submit_job.sh`
otherwise defaults `S3_PREFIX` to `doc-to-lora`, which this role has no
access to and which fails the job with `AccessDenied` on every S3 write,
after several minutes of GPU-instance boot/model-load time already spent.

### 4. Create the Launch Template

Fill in `__GOLDEN_AMI_ID__`, `__INSTANCE_PROFILE_NAME__` (`doc-to-lora-job`
from step 3), and `__SECURITY_GROUP_ID__` (needs outbound internet access --
ECR pull, S3 sync, HF Hub) in `infra/launch-template.json`, then:

```
aws ec2 create-launch-template --cli-input-json file://infra/launch-template.json
```

This is a one-time step. Individual jobs don't touch this template directly
-- `submit_job.sh` creates a new *version* of it per job (carrying that job's
rendered user-data) and leaves the rest (AMI, IAM profile, security group,
root volume) inherited from this default version.

## Submitting a job

```
export AWS_REGION=us-east-2 ECR_REPOSITORY=doc-to-lora S3_BUCKET=doc-to-lora-jobs S3_PREFIX=dev

# Subnets for this project (different AZs, so the Fleet request can fall
# back if one AZ is out of G7e Spot capacity):
SUBNETS=subnet-02cd0f69de4c45f27,subnet-0ffc1d7ffc780a921,subnet-0063232b3d9188b5f

# Training -- matches accelerate_config.yaml's num_processes=8 default 1:1
# with g7e.48xlarge's 8 GPUs, no code changes needed for the top-end case.
infra/submit_job.sh --job-type train --instance-type g7e.48xlarge \
  --subnets "$SUBNETS" \
  --config-path configs/main_exp/gemma4/self_gen_lv1_closed_qa_1_l2l.yaml \
  -- --model_name_or_path=google/gemma-4-E4B-it --target_modules=down_proj \
     --lora_r=8 --max_steps=100 --gradient_accumulation_steps=8

# QA generation -- right-sized smaller since it's memory-bound by one model +
# KV cache, not compute-bound; scale throughput with more concurrent
# instances/shards rather than a bigger box.
infra/submit_job.sh --job-type qa_gen --instance-type g7e.8xlarge \
  --subnets "$SUBNETS" \
  -- --vllm_model=google/gemma-4-E4B-it --glob_pattern="data/raw_datasets/fw_qa_v2/*" \
     --closed_qa_prob=1.0
```

`S3_PREFIX` **must** be set to `dev` -- `submit_job.sh` defaults it to
`doc-to-lora` if unset, which the instance's IAM role (see step 3 above)
has no access to. Getting this wrong doesn't fail fast: the instance boots,
pulls the image, loads the model, and only then fails every S3 write with
`AccessDenied`, burning several minutes of (often on-demand, GPU-hour-billed)
time before self-terminating with exit code 1.

Listing multiple `--subnets` (different AZs) lets the Fleet request fall
back if one AZ is out of G7e Spot capacity -- this is a newer instance
family with thinner Spot pools than mature ones. Add `--on-demand` to skip
Spot (short validation/final runs only; Spot is ~81-83% cheaper on this
family and is the default).

Output (parquet shards for `qa_gen`, `train_outputs/runs/` for `train`) syncs
to `s3://$S3_BUCKET/$S3_PREFIX/<job_type>/<run_name>/output/`. The instance
self-terminates after the job exits (`InstanceInitiatedShutdownBehavior:
terminate` in the launch template + `shutdown -h now` at the end of
user-data) so it never idles on your bill; its boot-time log is pushed to
`.../logs/user-data.log` before shutdown for post-mortem debugging.

## Resuming after a Spot interruption

Re-run the exact same `submit_job.sh` command with the **same `--run-name`**.
`docker/entrypoint.sh` checks S3 for that run's existing output before
starting: for `train` it finds the latest `checkpoint-*` dir and passes
`--resume_from_checkpoint` automatically; for `qa_gen`, resume granularity is
the whole invocation (rerunning redoes that shard's generation from scratch --
bounded cost, since `gen_data_gemma4.sh`'s per-shard loop already keeps
shards small; there's no partial-shard resume, since `self_generate_qa.py`
doesn't skip already-written parquet files -- out of scope here since it'd
mean changing that script, not just infra).

## Known gaps / things to verify before relying on this in production

- **`kernels-community/flash-attn2` has no build for torch==2.13.0/cu130
  yet** (checked all tags/branches on the Hub repo -- newest is `v0.0.2`,
  nothing past torch212/cu132). `idefics2.py`'s attention fallback resolves
  to that string; any code path that actually loads the perceiver with it
  may fail at runtime the same way `kernels.get_kernel()` does when called
  directly. Not a container/infra issue -- worth tracking upstream or
  confirming your training configs don't hit that path.
- The exact minimum NVIDIA driver version for RTX PRO 6000 Blackwell +
  CUDA 13 is a fast-moving target for a GPU family that only GA'd this year;
  `bootstrap.sh` intentionally installs unpinned ("latest from NVIDIA's
  repo") rather than a hardcoded version -- re-verify with `nvidia-smi`
  after any AMI rebuild.
- `google/gemma-4-E4B-it` is not gated (confirmed via an unauthenticated
  `HEAD` request during local testing), but setting `HF_TOKEN` is still
  recommended for rate limits on repeated job launches.
