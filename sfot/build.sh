#!/bin/bash
set -e

# Build and push SFOT container

# Configuration
IMAGE_NAME="ghcr.io/bazaar-ghost/sfot"
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "dev")
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "Building SFOT container..."
echo "Version: $VERSION"
echo "Timestamp: $TIMESTAMP"

# Build image
docker build \
  --tag "$IMAGE_NAME:$VERSION" \
  --tag "$IMAGE_NAME:latest" \
  --label "version=$VERSION" \
  --label "build.timestamp=$TIMESTAMP" \
  --label "build.commit=$(git rev-parse HEAD 2>/dev/null || echo 'unknown')" \
  .

echo "Build complete!"

# Push to registry (requires authentication)
if [ "$1" == "--push" ]; then
  echo "Pushing to GitHub Container Registry..."
  docker push "$IMAGE_NAME:$VERSION"
  docker push "$IMAGE_NAME:latest"
  echo "Push complete!"
fi

# Run tests
if [ "$1" == "--test" ]; then
  echo "Running container tests..."
  docker run --rm \
    -e VOD_ID="test123" \
    -e START_TIME="0" \
    -e END_TIME="60" \
    "$IMAGE_NAME:latest" || true
fi

echo "Done!"