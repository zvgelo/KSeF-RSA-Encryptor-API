#!/usr/bin/env bash
set -euo pipefail

# Run from anywhere: resolve the repository root from this script's location.
DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${DOCKER_DIR}")"

IMAGE_NAME="ksef-integration-api"
TAG="${1:-latest}"
OUTPUT_FILE="${REPO_ROOT}/${IMAGE_NAME}_${TAG}.tar"

echo "Building Docker image: ${IMAGE_NAME}:${TAG}"
docker build -t "${IMAGE_NAME}:${TAG}" -f "${DOCKER_DIR}/Dockerfile" "${REPO_ROOT}"

echo "Exporting image to: ${OUTPUT_FILE}"
docker save -o "${OUTPUT_FILE}" "${IMAGE_NAME}:${TAG}"

SIZE=$(du -sh "${OUTPUT_FILE}" | cut -f1)
echo "Done. File: ${OUTPUT_FILE} (${SIZE})"
echo ""
echo "Transfer the file to the target machine, then load it with:"
echo "  docker load -i ${OUTPUT_FILE}"
