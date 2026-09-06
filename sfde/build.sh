#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
IMAGE_NAME="${IMAGE_NAME:-ghcr.io/kaiobarb/bazaar-ghost/sfde}"
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
case "${1:-}" in
  --test)
    docker build --target test -t sfde:test .
    docker run --rm --network none sfde:test
    ;;
  ""|--push)
    docker build -t "$IMAGE_NAME:$VERSION" -t "$IMAGE_NAME:latest" .
    if [[ "${1:-}" == --push ]]; then
      docker push "$IMAGE_NAME:$VERSION"
      docker push "$IMAGE_NAME:latest"
    fi
    ;;
  *) echo 'Usage: build.sh [--test|--push]' >&2; exit 2 ;;
esac
