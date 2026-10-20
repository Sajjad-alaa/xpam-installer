#!/usr/bin/env bash
# Push the XPAM images to GitHub Container Registry as ghcr.io/<owner>/xpam/<name>:<tag>.
# Log in first:  docker login ghcr.io -u <owner>   (token with write:packages)
set -euo pipefail
OWNER=${1:?usage: push-ghcr.sh <github-owner> [name...]}; shift || true
OWNER=$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')
NS=${NS:-xpam}; TAG=${TAG:-v5.1.7}
names=("$@"); [[ ${#names[@]} -gt 0 ]] || names=(core gateway web workspace secureconnection webconnector ai browser)
for name in "${names[@]}"; do
  target="ghcr.io/$OWNER/xpam/$name:$TAG"
  docker tag "$NS/$name:$TAG" "$target"
  docker push "$target"
done
