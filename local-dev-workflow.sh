#!/bin/bash
# local-dev-workflow.sh - Complete development workflow for RFdiffusion container

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CONTAINER_NAME="rfdiffusion:latest"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"

print_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
    exit 1
}

check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install Docker first."
    fi
    
    if ! docker info &>/dev/null; then
        print_error "Docker is not running. Please start Docker."
    fi
    
    print_success "Docker is available and running"
    
    # Check AWS CLI (optional for local testing)
    if command -v aws &> /dev/null; then
        print_success "AWS CLI is available"
        
        if aws sts get-caller-identity &>/dev/null; then
            print_success "AWS credentials are configured"
        else
            print_warning "AWS credentials not configured (optional for local testing)"
        fi
    else
        print_warning "AWS CLI not found (install for ECR push functionality)"
    fi
    
    # Check if we're in the right directory
    if [[ ! -f "README.md" ]] || [[ ! -d "scripts" ]]; then
        print_error "Please run this script from the RFdiffusion root directory"
    fi
    
    print_success "Prerequisites check completed"
}

build_container() {
    print_header "Building Container"
    
    echo "Building RFdiffusion container (this may take 10-15 minutes)..."
    echo "Progress will be shown below:"
    
    if docker build -f docker/Dockerfile.batch -t $CONTAINER_NAME . 2>&1 | tee build.log; then
        print_success "Container built successfully"
        
        # Show container size
        SIZE=$(docker images $CONTAINER_NAME --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | tail -1)
        echo "Container size: $SIZE"
    else
        print_error "Container build failed. Check build.log for details."
    fi
}

test_container() {
    print_header "Testing Container Locally"
    
    if [[ ! -f "./test-container-local.sh" ]]; then
        print_error "test-container-local.sh not found. Please make sure all scripts are in place."
    fi
    
    chmod +x ./test-container-local.sh
    
    if ./test-container-local.sh; then
        print_success "All local tests passed"
    else
        print_error "Local tests failed. Check test logs for details."
    fi
}

push_to_ecr() {
    print_header "Pushing to ECR"
    
    if [[ -z "$AWS_ACCOUNT_ID" ]]; then
        print_warning "AWS_ACCOUNT_ID not set. Skipping ECR push."
        echo "To push to ECR, set AWS_ACCOUNT_ID environment variable and run:"
        echo "  export AWS_ACCOUNT_ID=your-account-id"
        echo "  ./build-and-push.sh"
        return
    fi
    
    if [[ ! -f "./build-and-push.sh" ]]; then
        print_error "build-and-push.sh not found."
    fi
    
    chmod +x ./build-and-push.sh
    
    if ./build-and-push.sh; then
        print_success "Container pushed to ECR successfully"
    else
        print_error "ECR push failed. Check your AWS credentials and permissions."
    fi
}

create_test_data() {
    print_header "Creating Test Data"
    
    TEST_DIR="./test-data"
    mkdir -p $TEST_DIR/inputs $TEST_DIR/outputs
    
    # Download a test PDB file if it doesn't exist
    if [[ ! -f "$TEST_DIR/inputs/5TPN.pdb" ]]; then
        echo "Downloading test PDB file..."
        if command -v wget &> /dev/null; then
            wget -q -P $TEST_DIR/inputs https://files.rcsb.org/view/5TPN.pdb || \
                print_warning "Failed to download test PDB file (non-critical)"
        elif command -v curl &> /dev/null; then
            curl -s -o $TEST_DIR/inputs/5TPN.pdb https://files.rcsb.org/view/5TPN.pdb || \
                print_warning "Failed to download test PDB file (non-critical)"
        else
            print_warning "Neither wget nor curl available. Skipping test PDB download."
        fi
    fi
    
    if [[ -f "$TEST_DIR/inputs/5TPN.pdb" ]]; then
        print_success "Test PDB file ready: $TEST_DIR/inputs/5TPN.pdb"
    fi
}

show_next_steps() {
    print_header "Next Steps"
    
    echo "Your RFdiffusion container is ready! Here's what you can do next:"
    echo ""
    echo "📋 AWS Batch Deployment:"
    echo "   1. Set up AWS Batch infrastructure (compute environment, job queue, job definition)"
    echo "   2. Submit test jobs to AWS Batch"
    echo "   3. Monitor job execution in AWS console"
    echo ""
    echo "🧪 Local Development:"
    echo "   - Run local tests: ./test-container-local.sh"
    echo "   - Rebuild after changes: docker build -f docker/Dockerfile.batch -t rfdiffusion:latest ."
    echo ""
    echo "☁️  Production Deployment:"
    echo "   - Push to ECR: ./build-and-push.sh"
    echo "   - Set up monitoring and logging"
    echo "   - Configure auto-scaling policies"
    echo ""
    echo "🔧 Container Commands:"
    echo "   - View logs: docker run --rm -e JOB_ID=test -e RFDIFFUSION_COMMAND='echo test' rfdiffusion:latest"
    echo "   - Debug shell: docker run -it --rm --entrypoint bash rfdiffusion:latest"
    echo ""
    
    if [[ -n "$AWS_ACCOUNT_ID" ]]; then
        IMAGE_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/rfdiffusion:latest"
        echo "🏷️  Your container URI for AWS Batch:"
        echo "   $IMAGE_URI"
    fi
}

main() {
    print_header "RFdiffusion Container Development Workflow"
    
    echo "This script will:"
    echo "1. Check prerequisites"
    echo "2. Build the container"
    echo "3. Test locally"
    echo "4. Create test data"
    echo "5. Optionally push to ECR"
    echo ""
    
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    
    check_prerequisites
    build_container
    test_container
    create_test_data
    
    if [[ -n "$AWS_ACCOUNT_ID" ]] && command -v aws &> /dev/null; then
        echo ""
        read -p "Push to ECR? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            push_to_ecr
        fi
    fi
    
    show_next_steps
    
    print_success "Workflow completed successfully!"
}

# Make sure all scripts are executable
chmod +x ./*.sh 2>/dev/null || true

# Run main function
main "$@"