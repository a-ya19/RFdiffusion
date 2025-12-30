#!/bin/bash
# run_batch_job.sh - AWS Batch entrypoint for RFdiffusion

set -euo pipefail

echo "=== RFdiffusion AWS Batch Job Starting ==="
echo "Job ID: ${JOB_ID:-unknown}"
echo "Job Type: ${JOB_TYPE:-unknown}"
echo "AWS Batch Job ID: ${AWS_BATCH_JOB_ID:-unknown}"
echo "Container started at: $(date)"

# Function to update job status via API
update_status() {
    local status=$1
    local progress=$2
    local message=${3:-""}
    
    echo "Status Update: ${status} (${progress}%) - ${message}"
    
    if [[ -n "${API_ENDPOINT:-}" && -n "${JOB_ID:-}" ]]; then
        curl -s -X POST "${API_ENDPOINT}/internal/jobs/${JOB_ID}/status" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${API_TOKEN:-}" \
            -d "{\"status\": \"${status}\", \"progress\": ${progress}, \"message\": \"${message}\"}" || true
    fi
}

# Function to handle errors
handle_error() {
    echo "ERROR: $1" >&2
    update_status "FAILED" 0 "$1"
    exit 1
}

# Function to extract protein length from contigs
extract_protein_length() {
    local contigs=$1
    # Extract numbers from patterns like [100-200] or [A1-150/0 70-100]
    echo "$contigs" | grep -oE '[0-9]+' | head -1 || echo "100"
}

# Trap to handle cleanup on exit
cleanup() {
    echo "Cleaning up temporary files..."
    rm -f /tmp/inputs/* /tmp/outputs/*.tmp 2>/dev/null || true
}
trap cleanup EXIT

# Update initial status
update_status "RUNNING" 5 "Job started, initializing environment"

# Validate required environment variables
if [[ -z "${JOB_ID:-}" ]]; then
    handle_error "JOB_ID environment variable is required"
fi

if [[ -z "${RFDIFFUSION_COMMAND:-}" ]]; then
    handle_error "RFDIFFUSION_COMMAND environment variable is required"
fi

# Create directories
mkdir -p /tmp/inputs /tmp/outputs

# Download models if not present
if [[ ! -d "/app/models" || -z "$(ls -A /app/models 2>/dev/null)" ]]; then
    echo "Downloading RFdiffusion models..."
    update_status "RUNNING" 10 "Downloading model weights"
    
    mkdir -p /app/models
    
    if [[ -n "${MODEL_S3_BUCKET:-}" ]]; then
        echo "Attempting to download models from S3: s3://${MODEL_S3_BUCKET}/models/"
        if aws s3 sync "s3://${MODEL_S3_BUCKET}/models/" /app/models/ --quiet; then
            echo "Models downloaded from S3 cache"
        else
            echo "S3 download failed, downloading from original source..."
            bash /app/RFdiffusion/scripts/download_models.sh /app/models || \
                handle_error "Failed to download model weights"
        fi
    else
        echo "Downloading models from original source..."
        bash /app/RFdiffusion/scripts/download_models.sh /app/models || \
            handle_error "Failed to download model weights"
    fi
    
    update_status "RUNNING" 20 "Model weights ready"
else
    echo "Models already present, skipping download"
    update_status "RUNNING" 15 "Using cached model weights"
fi

# Download input files if present
if [[ -n "${INPUT_PDB_KEY:-}" && -n "${INPUT_S3_BUCKET:-}" ]]; then
    echo "Downloading input PDB: s3://${INPUT_S3_BUCKET}/${INPUT_PDB_KEY}"
    aws s3 cp "s3://${INPUT_S3_BUCKET}/${INPUT_PDB_KEY}" /tmp/inputs/input.pdb || \
        handle_error "Failed to download input PDB from s3://${INPUT_S3_BUCKET}/${INPUT_PDB_KEY}"
    echo "Input PDB downloaded successfully"
    update_status "RUNNING" 25 "Input PDB downloaded"
fi

# Download target PDB if present (for binder design)
if [[ -n "${TARGET_PDB_KEY:-}" && -n "${INPUT_S3_BUCKET:-}" ]]; then
    echo "Downloading target PDB: s3://${INPUT_S3_BUCKET}/${TARGET_PDB_KEY}"
    aws s3 cp "s3://${INPUT_S3_BUCKET}/${TARGET_PDB_KEY}" /tmp/inputs/target.pdb || \
        handle_error "Failed to download target PDB"
    update_status "RUNNING" 27 "Target PDB downloaded"
fi

# Download scaffold files if present (for scaffold-guided design)
if [[ -n "${SCAFFOLD_S3_PREFIX:-}" && -n "${INPUT_S3_BUCKET:-}" ]]; then
    echo "Downloading scaffold files: s3://${INPUT_S3_BUCKET}/${SCAFFOLD_S3_PREFIX}"
    mkdir -p /tmp/inputs/scaffolds
    aws s3 sync "s3://${INPUT_S3_BUCKET}/${SCAFFOLD_S3_PREFIX}" /tmp/inputs/scaffolds/ || \
        handle_error "Failed to download scaffold files"
    update_status "RUNNING" 30 "Scaffold files downloaded"
fi

update_status "RUNNING" 35 "Starting RFdiffusion execution"

# Change to RFdiffusion directory
cd /app/RFdiffusion

# Validate GPU availability
echo "Checking GPU availability..."
nvidia-smi || handle_error "NVIDIA GPU not available or nvidia-smi not found"

echo "GPU check passed, executing RFdiffusion..."
echo "Command: ${RFDIFFUSION_COMMAND}"

# Execute the RFdiffusion command with progress monitoring
{
    eval "${RFDIFFUSION_COMMAND}" 2>&1 | while IFS= read -r line; do
        echo "$line"
        
        # Simple progress estimation based on log patterns
        if [[ "$line" == *"Calculating IGSO3"* ]]; then
            update_status "RUNNING" 40 "Initializing diffusion process"
        elif [[ "$line" == *"diffusion step"* ]] || [[ "$line" == *"step"* ]]; then
            # Try to extract step numbers for progress
            if [[ "$line" =~ step[[:space:]]*([0-9]+) ]]; then
                local step=${BASH_REMATCH[1]}
                local progress=$((40 + (step * 45 / 50)))  # Assume 50 steps max
                update_status "RUNNING" $progress "Diffusion step $step"
            fi
        elif [[ "$line" == *"Saving"* ]] || [[ "$line" == *"Writing"* ]]; then
            update_status "RUNNING" 85 "Saving results"
        fi
    done
    echo ${PIPESTATUS[0]} > /tmp/exit_code
} | tee /tmp/outputs/execution.log

# Check exit code
EXIT_CODE=$(cat /tmp/exit_code 2>/dev/null || echo "1")
if [[ $EXIT_CODE -ne 0 ]]; then
    echo "RFdiffusion execution failed with exit code: $EXIT_CODE"
    # Extract error from logs
    ERROR_MSG=$(tail -20 /tmp/outputs/execution.log | grep -i error | tail -1 || echo "Unknown error occurred")
    handle_error "RFdiffusion execution failed: $ERROR_MSG"
fi

echo "RFdiffusion execution completed successfully"
update_status "RUNNING" 90 "RFdiffusion completed, preparing results"

# Verify output files were created
OUTPUT_COUNT=$(find /tmp/outputs -name "*.pdb" | wc -l)
if [[ $OUTPUT_COUNT -eq 0 ]]; then
    handle_error "No output PDB files were generated"
fi

echo "Generated $OUTPUT_COUNT PDB files"

# Upload results to S3
if [[ -n "${OUTPUT_S3_PREFIX:-}" && -n "${INPUT_S3_BUCKET:-}" ]]; then
    echo "Uploading results to: s3://${INPUT_S3_BUCKET}/${OUTPUT_S3_PREFIX}"
    
    # Upload output files (excluding logs for now)
    aws s3 sync /tmp/outputs/ "s3://${INPUT_S3_BUCKET}/${OUTPUT_S3_PREFIX}" \
        --exclude "*.log" \
        --exclude "*.tmp" || handle_error "Failed to upload results to S3"
    
    # Upload logs separately with error handling
    if [[ -f /tmp/outputs/execution.log ]]; then
        aws s3 cp /tmp/outputs/execution.log "s3://${INPUT_S3_BUCKET}/${OUTPUT_S3_PREFIX}logs/execution.log" || \
            echo "Warning: Failed to upload logs (non-fatal)"
    fi
    
    echo "Results uploaded successfully"
    update_status "RUNNING" 95 "Results uploaded to S3"
else
    echo "No S3 configuration provided, results remain local"
fi

# Final status update
update_status "SUCCEEDED" 100 "Job completed successfully - generated $OUTPUT_COUNT designs"

echo "=== RFdiffusion AWS Batch Job Completed Successfully ==="
echo "Job completed at: $(date)"
echo "Generated files:"
ls -la /tmp/outputs/*.pdb 2>/dev/null || echo "No PDB files in outputs"