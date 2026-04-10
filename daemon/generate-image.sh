#!/usr/bin/env bash
set -euo pipefail

# ComfyUI API wrapper for image generation (SDXL)
# Usage: generate-image.sh "prompt text" /path/to/output/dir [checkpoint_model]

COMFYUI_API="http://127.0.0.1:8188"
COMFYUI_OUTPUT="${COMFYUI_OUTPUT_DIR:-$HOME/ComfyUI/output}"
DEFAULT_CHECKPOINT="sd_xl_base_1.0.safetensors"
POLL_INTERVAL=2
TIMEOUT=300

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 \"prompt text\" /path/to/output/dir [checkpoint_model]" >&2
    exit 1
fi

PROMPT_TEXT="$1"
OUTPUT_DIR="$2"
CHECKPOINT="${3:-$DEFAULT_CHECKPOINT}"

# Prefix prompt with quality boosters
POSITIVE_PROMPT="high quality, detailed, professional, ${PROMPT_TEXT}"
NEGATIVE_PROMPT="low quality, blurry, distorted, deformed, ugly, bad anatomy"

# Generate random seed
SEED=$(shuf -i 0-4294967295 -n 1)

# Build workflow JSON
WORKFLOW=$(cat <<EOF
{
    "3": {
        "class_type": "KSampler",
        "inputs": {
            "cfg": 7,
            "denoise": 1,
            "latent_image": ["5", 0],
            "model": ["4", 0],
            "negative": ["7", 0],
            "positive": ["6", 0],
            "sampler_name": "euler_ancestral",
            "scheduler": "normal",
            "seed": ${SEED},
            "steps": 30
        }
    },
    "4": {
        "class_type": "CheckpointLoaderSimple",
        "inputs": {
            "ckpt_name": "${CHECKPOINT}"
        }
    },
    "5": {
        "class_type": "EmptyLatentImage",
        "inputs": {
            "batch_size": 1,
            "height": 1024,
            "width": 1024
        }
    },
    "6": {
        "class_type": "CLIPTextEncode",
        "inputs": {
            "clip": ["4", 1],
            "text": $(jq -Rn --arg t "$POSITIVE_PROMPT" '$t')
        }
    },
    "7": {
        "class_type": "CLIPTextEncode",
        "inputs": {
            "clip": ["4", 1],
            "text": $(jq -Rn --arg t "$NEGATIVE_PROMPT" '$t')
        }
    },
    "8": {
        "class_type": "VAEDecode",
        "inputs": {
            "samples": ["3", 0],
            "vae": ["4", 2]
        }
    },
    "9": {
        "class_type": "SaveImage",
        "inputs": {
            "filename_prefix": "clawd-gen",
            "images": ["8", 0]
        }
    }
}
EOF
)

# Submit prompt to ComfyUI
PAYLOAD=$(jq -n --argjson prompt "$WORKFLOW" '{"prompt": $prompt}')
RESPONSE=$(curl -s -X POST "${COMFYUI_API}/prompt" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

PROMPT_ID=$(echo "$RESPONSE" | jq -r '.prompt_id')
if [[ -z "$PROMPT_ID" || "$PROMPT_ID" == "null" ]]; then
    echo "Error: failed to queue prompt. Response: $RESPONSE" >&2
    exit 1
fi

echo "Queued prompt: ${PROMPT_ID}" >&2

# Poll for completion
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    HISTORY=$(curl -s "${COMFYUI_API}/history/${PROMPT_ID}")
    STATUS=$(echo "$HISTORY" | jq -r ".[\"${PROMPT_ID}\"].outputs[\"9\"].images[0].filename // empty")

    if [[ -n "$STATUS" ]]; then
        FILENAME="$STATUS"
        break
    fi

    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Error: timed out after ${TIMEOUT}s waiting for image generation" >&2
    exit 1
fi

# Copy output image to destination
DEST_DIR="${OUTPUT_DIR}/generated-images"
mkdir -p "$DEST_DIR"
cp "${COMFYUI_OUTPUT}/${FILENAME}" "${DEST_DIR}/${FILENAME}"

echo "${DEST_DIR}/${FILENAME}"
exit 0
