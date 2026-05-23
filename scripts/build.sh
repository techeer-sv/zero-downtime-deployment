#!/bin/bash
set -e

VERSION=$1

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  echo "  Example: $0 1.0.0"
  exit 1
fi

IMAGE_NAME="zero-downtime-app"

echo "Building $IMAGE_NAME:$VERSION ..."

docker build \
  --build-arg APP_VERSION="$VERSION" \
  -t "$IMAGE_NAME:$VERSION" \
  ./app

echo "Done. Image: $IMAGE_NAME:$VERSION"
