#!/bin/bash
# build-and-push.sh - Build and push RFdiffusion container to ECR

set -euo pipefail

# Configuration - Update these values for your AWS setup
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-123456789012}"  # Replace with your AWS account ID
AWS_REGION="${AWS_REGION:-us-east-1}"             # Replace with your preferred region
ECR_REPOSITORY="${ECR_REPOSITORY:-rfdiffusion}"

echo "=== Building and Pushing RFdiffusion Container ==="
echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "Region: $AWS_REGION"
echo "Repository: $ECR_REPOSITORY"

# Check if AWS CLI is configured
if ! aws sts get-caller-identity &>/dev/null; then
    echo "ERROR: AWS CLI is not configured or credentials are invalid"
    echo "Please run 'aws configure' or set AWS environment variables"
    exit 1
fi

# Check if Docker is running
if ! docker info &>/dev/null; then
    echo "ERROR: Docker is not running"
    echo "Please start Docker and try again"
    exit 1
fi

# Get the login token and login to ECR
echo "Logging into Amazon ECR..."
aws ecr get-login-password --region $AWS_REGION | \
    docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Create ECR repository if it doesn't exist
echo "Checking/Creating ECR repository..."
if aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $AWS_REGION &>/dev/null; then
    echo "Repository $ECR_REPOSITORY already exists"
else
    echo "Creating repository $ECR_REPOSITORY..."
    aws ecr create-repository --repository-name $ECR_REPOSITORY --region $AWS_REGION
fi

# Build the Docker image
echo "Building Docker image..."
echo "This may take 10-15 minutes as it downloads CUDA base image and Python packages..."

if docker build -f docker/Dockerfile.batch -t $ECR_REPOSITORY:latest .; then
    echo "✅ Docker image built successfully"
else
    echo "❌ Docker build failed"
    exit 1
fi

# Create tags
IMAGE_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY"
DATE_TAG=$(date +%Y%m%d-%H%M%S)

echo "Tagging images..."
docker tag $ECR_REPOSITORY:latest $IMAGE_URI:latest
docker tag $ECR_REPOSITORY:latest $IMAGE_URI:$DATE_TAG

# Push to ECR
echo "Pushing images to ECR..."
echo "Pushing latest tag..."
if docker push $IMAGE_URI:latest; then
    echo "✅ Latest tag pushed successfully"
else
    echo "❌ Failed to push latest tag"
    exit 1
fi

echo "Pushing date tag..."
if docker push $IMAGE_URI:$DATE_TAG; then
    echo "✅ Date tag pushed successfully"
else
    echo "❌ Failed to push date tag"
    exit 1
fi

echo ""
echo "🎉 Container built and pushed successfully!"
echo ""
echo "Image URIs:"
echo "  Latest: $IMAGE_URI:latest"
echo "  Dated:  $IMAGE_URI:$DATE_TAG"
echo ""
echo "You can now use these URIs in your AWS Batch job definitions."
echo ""
echo "Next steps:"
echo "1. Test the container with: ./test-container-local.sh"
echo "2. Set up AWS Batch infrastructure"
echo "3. Submit a test job"