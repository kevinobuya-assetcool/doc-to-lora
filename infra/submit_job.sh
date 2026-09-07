#!/usr/bin/env bash
# Submits one doc-to-lora job as an EC2 Fleet (plain-EC2 path: no Batch/
# SageMaker). Renders infra/user-data.sh.tmpl for this specific job, publishes
# it as a new version of the (already-created, mostly-static) Launch
# Template, then requests a Fleet across the given subnets/AZs so a Spot
# capacity gap in one AZ doesn't block the whole job -- g7e is a newer
# instance family with thinner Spot capacity than mature ones.
#
# One-time setup (not done by this script):
#   1. Build+push the image:            docker/build_and_push.sh
#   2. Build the golden AMI:            infra/ami/bootstrap.sh (see infra/README.md)
#   3. Create the IAM role/profile:     infra/iam/*.json (see infra/README.md)
#   4. Create the Launch Template once: aws ec2 create-launch-template
#        --cli-input-json file://infra/launch-template.json
#      (with its __PLACEHOLDER__ values filled in first)
#
# Usage:
#   AWS_REGION=us-east-1 ECR_REPOSITORY=doc-to-lora S3_BUCKET=my-bucket \
#   infra/submit_job.sh --job-type train --instance-type g7e.48xlarge \
#     --subnets subnet-aaa,subnet-bbb --config-path configs/main_exp/gemma4/self_gen_lv1_closed_qa_1_l2l.yaml \
#     -- --model_name_or_path=google/gemma-4-E4B-it --max_steps=100
set -euo pipefail

AWS_REGION="${AWS_REGION:?set AWS_REGION}"
ECR_REPOSITORY="${ECR_REPOSITORY:?set ECR_REPOSITORY}"
S3_BUCKET="${S3_BUCKET:?set S3_BUCKET}"
S3_PREFIX="${S3_PREFIX:-doc-to-lora}"
LAUNCH_TEMPLATE_NAME="${LAUNCH_TEMPLATE_NAME:-doc-to-lora-job}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

JOB_TYPE=""
INSTANCE_TYPE=""
SUBNETS=""
CONFIG_PATH=""
RUN_NAME="$(date -u +%Y%m%dT%H%M%SZ)"
CAPACITY_TYPE="spot"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --job-type) JOB_TYPE="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --subnets) SUBNETS="$2"; shift 2 ;;
        --config-path) CONFIG_PATH="$2"; shift 2 ;;
        --run-name) RUN_NAME="$2"; shift 2 ;;
        --spot) CAPACITY_TYPE="spot"; shift ;;
        --on-demand) CAPACITY_TYPE="on-demand"; shift ;;
        --) shift; EXTRA_ARGS=("$@"); break ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$JOB_TYPE" ]] && { echo "--job-type qa_gen|train is required" >&2; exit 1; }
[[ -z "$INSTANCE_TYPE" ]] && { echo "--instance-type is required, e.g. g7e.2xlarge" >&2; exit 1; }
[[ -z "$SUBNETS" ]] && { echo "--subnets subnet-a,subnet-b is required (spread across AZs)" >&2; exit 1; }
if [[ "$JOB_TYPE" == "train" && -z "$CONFIG_PATH" ]]; then
    echo "--config-path is required for --job-type train" >&2; exit 1
fi

IFS=',' read -ra SUBNET_ARR <<< "$SUBNETS"
if ! SUBNET_ERR="$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "${SUBNET_ARR[@]}" 2>&1 >/dev/null)"; then
    echo "Invalid subnet(s) in --subnets ${SUBNETS}:" >&2
    echo "$SUBNET_ERR" >&2
    exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:${IMAGE_TAG}"

if ! ECR_ERR="$(aws ecr describe-images --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" \
        --image-ids imageTag="$IMAGE_TAG" 2>&1 >/dev/null)"; then
    echo "Image tag '${IMAGE_TAG}' not found in ECR repository '${ECR_REPOSITORY}' (region ${AWS_REGION})." >&2
    echo "Push it first: docker/build_and_push.sh   (also pushes 'latest')" >&2
    echo "Or list available tags: aws ecr list-images --repository-name ${ECR_REPOSITORY} --region ${AWS_REGION}" >&2
    exit 1
fi

# Render user-data from the template, then base64-encode for the API.
USER_DATA="$(sed \
    -e "s#__JOB_TYPE__#${JOB_TYPE}#g" \
    -e "s#__RUN_NAME__#${RUN_NAME}#g" \
    -e "s#__IMAGE_URI__#${IMAGE_URI}#g" \
    -e "s#__AWS_REGION__#${AWS_REGION}#g" \
    -e "s#__S3_BUCKET__#${S3_BUCKET}#g" \
    -e "s#__S3_PREFIX__#${S3_PREFIX}#g" \
    -e "s#__CONFIG_PATH__#${CONFIG_PATH}#g" \
    -e "s#__EXTRA_ARGS__#${EXTRA_ARGS[*]}#g" \
    "$REPO_ROOT/infra/user-data.sh.tmpl")"
USER_DATA_B64="$(printf '%s' "$USER_DATA" | base64 -w0)"

# New Launch Template version carrying just this job's user-data; everything
# else (AMI, instance profile, security group, root volume) is inherited
# from the template's existing default version.
TEMPLATE_DATA="$(jq -n --arg ud "$USER_DATA_B64" '{UserData: $ud}')"
NEW_VERSION="$(aws ec2 create-launch-template-version \
    --region "$AWS_REGION" \
    --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
    --version-description "${JOB_TYPE}-${RUN_NAME}" \
    --source-version '$Latest' \
    --launch-template-data "$TEMPLATE_DATA" \
    --query 'LaunchTemplateVersion.VersionNumber' --output text)"

OVERRIDES="$(jq -n --arg it "$INSTANCE_TYPE" --arg subnets "$SUBNETS" \
    '$subnets | split(",") | map({InstanceType: $it, SubnetId: .})')"

FLEET_RESULT="$(aws ec2 create-fleet \
    --region "$AWS_REGION" \
    --type instant \
    --target-capacity-specification "TotalTargetCapacity=1,DefaultTargetCapacityType=${CAPACITY_TYPE}" \
    --launch-template-configs "$(jq -n \
        --arg name "$LAUNCH_TEMPLATE_NAME" --arg ver "$NEW_VERSION" --argjson overrides "$OVERRIDES" \
        '[{LaunchTemplateSpecification: {LaunchTemplateName: $name, Version: $ver}, Overrides: $overrides}]')")"

INSTANCE_ID="$(echo "$FLEET_RESULT" | jq -r '.Instances[0].InstanceIds[0] // empty')"

if [[ -z "$INSTANCE_ID" ]]; then
    echo "Fleet request did not launch an instance. Full response:" >&2
    echo "$FLEET_RESULT" | jq . >&2
    exit 1
fi

echo "Launched ${INSTANCE_ID} (${INSTANCE_TYPE}, ${CAPACITY_TYPE}) for ${JOB_TYPE} run '${RUN_NAME}'"
echo "Output will land under s3://${S3_BUCKET}/${S3_PREFIX}/${JOB_TYPE}/${RUN_NAME}/"
echo "User-data log (post-shutdown): s3://${S3_BUCKET}/${S3_PREFIX}/${JOB_TYPE}/${RUN_NAME}/logs/user-data.log"
