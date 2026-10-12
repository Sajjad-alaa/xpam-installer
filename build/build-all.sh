#!/usr/bin/env bash
# Build all XPAM images from the source repos.
#   ./build-all.sh                 build everything
#   ./build-all.sh core web        build only the named images
# Environment: SRC (repos folder, default /opt), NS (default xpam), TAG (default v5.0.0-ce).
# Needs: docker with BuildKit, and for the web image node 24 with the repos' node_modules installed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=${SRC:-/opt}; NS=${NS:-xpam}; TAG=${TAG:-v5.0.0-ce}
CACHE="$HERE/.cache"; mkdir -p "$CACHE"
GO_IMAGE=golang:1.26-trixie
GHOSTTY=ghcr.io/jumpserver-dev/libghostty-vt@sha256:dffb0a53f73862da96df4fadd134dd60ac440a82eb8b9a852d9159b989c86c0c
say() { printf '\n==> %s\n' "$*"; }

build_core() {
  say "core"
  docker build -q -f "$HERE/core.Dockerfile" -t "$NS/core:$TAG" "$SRC/xpam-core"
}

build_web() {
  say "web: admin UI"
  (cd "$SRC/xpam-web" && node_modules/.bin/vite build --mode production >/dev/null)
  say "web: workspace"
  (cd "$SRC/xpam-workspace" && HUSKY=0 ./node_modules/.bin/nuxt generate >/dev/null 2>&1)
  say "web: image"
  docker build -q -f "$HERE/web.Dockerfile" \
    --build-context workspace="$SRC/xpam-workspace/.output/public" \
    --build-context nginxconf="$HERE/nginx" -t "$NS/web:$TAG" "$SRC/xpam-web"
}

build_secureconnection() {
  say "secureconnection: binary"
  if [[ ! -d "$CACHE/libghostty-vt" ]]; then
    id=$(docker create "$GHOSTTY"); docker cp "$id:/opt/libghostty-vt" "$CACHE/libghostty-vt"; docker rm "$id" >/dev/null
  fi
  mkdir -p "$CACHE/sc-out" "$CACHE/gocache" "$CACHE/gomod"
  docker run --rm -v "$SRC/xpam-secureconnection:/ro:ro" -v "$CACHE/libghostty-vt:/opt/libghostty-vt:ro" \
    -v "$CACHE/sc-out:/out" -v "$CACHE/gocache:/root/.cache/go-build" -v "$CACHE/gomod:/go/pkg/mod" \
    -e CGO_ENABLED=1 -e GOFLAGS=-buildvcs=false -e PKG_CONFIG_PATH=/opt/libghostty-vt/share/pkgconfig "$GO_IMAGE" sh -ec '
      cp -r /ro /src && cd /src
      go test ./pkg/httpd/ ./pkg/lion/... ./pkg/common/ ./pkg/config/ >/dev/null
      KEY=$(head -c 100 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 32)
      go build -trimpath -ldflags "-X main.Version=v5.0.0-xpam -X github.com/jumpserver/koko/pkg/config.CipherKey=$KEY -w -s" -o /out/koko ./cmd/koko/'
  say "secureconnection: image"
  docker build -q -f "$HERE/secureconnection.Dockerfile" -t "$NS/secureconnection:$TAG" "$CACHE/sc-out"
}

build_webconnector() {
  say "webconnector"
  docker build -q -f "$HERE/webconnector.Dockerfile" -t "$NS/webconnector:$TAG" "$SRC/xpam-webconnector/config"
}

build_ai() {
  say "ai: binary"
  mkdir -p "$CACHE/ai-out" "$CACHE/gocache" "$CACHE/gomod"
  docker run --rm -v "$SRC/xpam-ai:/ro:ro" -v "$CACHE/ai-out:/out" -v "$CACHE/gocache:/root/.cache/go-build" \
    -v "$CACHE/gomod:/go/pkg/mod" -e CGO_ENABLED=0 -e GOFLAGS=-buildvcs=false "$GO_IMAGE" sh -ec '
      cp -r /ro /src && cd /src
      go test ./... >/dev/null
      go build -trimpath -ldflags "-s -w -X main.Version=v5.0.0-xpam" -o /out/kael ./cmd/kael'
  say "ai: image"
  docker build -q -f "$HERE/ai.Dockerfile" -t "$NS/ai:$TAG" "$CACHE/ai-out"
}

targets=("$@"); [[ ${#targets[@]} -gt 0 ]] || targets=(core web secureconnection webconnector ai)
for t in "${targets[@]}"; do "build_$t"; done
say "done"
docker images --format '{{.Repository}}:{{.Tag}}  {{.ID}}  {{.CreatedSince}}' | grep -E "^$NS/(core|web|secureconnection|webconnector|ai):$TAG " | sort
