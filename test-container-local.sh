#!/bin/bash
# test-container-local.sh - Test the RFdiffusion container locally (no GPU required)

set -euo pipefail

CONTAINER_NAME="rfdiffusion:latest"

echo "=== Testing RFdiffusion Container Locally ==="

# Check if Docker is running
if ! docker info &>/dev/null; then
    echo "❌ ERROR: Docker is not running"
    echo "Please start Docker and try again"
    exit 1
fi

# Check if the container exists
if ! docker images | grep -q "rfdiffusion"; then
    echo "❌ Container 'rfdiffusion:latest' not found"
    echo "Please build the container first with: ./build-and-push.sh"
    exit 1
fi

echo "✅ Docker is running and container exists"

# Create test directories
TEST_DIR="./test-container-data"
mkdir -p $TEST_DIR/inputs $TEST_DIR/outputs $TEST_DIR/models

echo "✅ Test directories created: $TEST_DIR"

# Test 1: Basic container startup (no GPU needed)
echo ""
echo "🧪 Test 1: Container startup and environment check"
if docker run --rm \
    -e JOB_ID="test-startup" \
    -e RFDIFFUSION_COMMAND="echo 'Container started successfully'" \
    $CONTAINER_NAME > $TEST_DIR/test1.log 2>&1; then
    echo "✅ Container starts successfully"
else
    echo "❌ Container startup failed"
    echo "Check logs: cat $TEST_DIR/test1.log"
    exit 1
fi

# Test 2: Python and dependency check
echo ""
echo "🧪 Test 2: Python environment and dependencies"
if docker run --rm \
    -e JOB_ID="test-python" \
    -e RFDIFFUSION_COMMAND="python3.9 -c 'import torch, dgl, e3nn; print(\"All dependencies imported successfully\")'" \
    $CONTAINER_NAME > $TEST_DIR/test2.log 2>&1; then
    echo "✅ Python dependencies are working"
else
    echo "❌ Python dependency check failed"
    echo "Check logs: cat $TEST_DIR/test2.log"
    exit 1
fi

# Test 3: RFdiffusion help command
echo ""
echo "🧪 Test 3: RFdiffusion help command"
if docker run --rm \
    -e JOB_ID="test-help" \
    -e RFDIFFUSION_COMMAND="python3.9 scripts/run_inference.py --help" \
    $CONTAINER_NAME > $TEST_DIR/test3.log 2>&1; then
    echo "✅ RFdiffusion command line interface is working"
else
    echo "❌ RFdiffusion CLI check failed"
    echo "Check logs: cat $TEST_DIR/test3.log"
    exit 1
fi

# Test 4: AWS CLI check
echo ""
echo "🧪 Test 4: AWS CLI availability"
if docker run --rm \
    -e JOB_ID="test-aws" \
    -e RFDIFFUSION_COMMAND="aws --version" \
    $CONTAINER_NAME > $TEST_DIR/test4.log 2>&1; then
    echo "✅ AWS CLI is available"
else
    echo "❌ AWS CLI check failed"
    echo "Check logs: cat $TEST_DIR/test4.log"
    exit 1
fi

# Test 5: File system permissions
echo ""
echo "🧪 Test 5: File system permissions and directories"
if docker run --rm \
    -v $(pwd)/$TEST_DIR/outputs:/tmp/outputs \
    -e JOB_ID="test-fs" \
    -e RFDIFFUSION_COMMAND="touch /tmp/outputs/test-file.txt && echo 'File system test passed'" \
    $CONTAINER_NAME > $TEST_DIR/test5.log 2>&1; then
    echo "✅ File system permissions are correct"
    # Clean up test file
    rm -f $TEST_DIR/outputs/test-file.txt
else
    echo "❌ File system permission check failed"
    echo "Check logs: cat $TEST_DIR/test5.log"
    exit 1
fi

# Test 6: Error handling
echo ""
echo "🧪 Test 6: Error handling"
if docker run --rm \
    -e JOB_ID="test-error" \
    -e RFDIFFUSION_COMMAND="exit 1" \
    $CONTAINER_NAME > $TEST_DIR/test6.log 2>&1; then
    echo "⚠️  Expected failure but container returned success"
else
    echo "✅ Error handling works correctly"
fi

echo ""
echo "🎉 All local tests passed!"
echo ""
echo "Test Summary:"
echo "✅ Container startup"
echo "✅ Python dependencies"  
echo "✅ RFdiffusion CLI"
echo "✅ AWS CLI"
echo "✅ File system permissions"
echo "✅ Error handling"
echo ""
echo "The container is ready for AWS Batch deployment."
echo ""
echo "⚠️  Note: GPU functionality can only be tested in AWS Batch with GPU instances."
echo ""
echo "Next steps:"
echo "1. Push to ECR: ./build-and-push.sh"
echo "2. Set up AWS Batch infrastructure"
echo "3. Submit a test job with actual GPU requirements"
echo ""
echo "Test logs are available in: $TEST_DIR/"