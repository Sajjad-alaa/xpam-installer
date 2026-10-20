#!/usr/bin/env bash
# Build all XPAM images from the source repos.
#   ./build-all.sh                 build everything
#   ./build-all.sh core web        build only the named images
# Images: core gateway web workspace secureconnection webconnector ai browser
# Environment: SRC (repos folder, default /opt), NS (default xpam), TAG (default v5.1.15).
# Needs: docker with BuildKit, and for the web and workspace images node 24 with the repos' node_modules installed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=${SRC:-/opt}; NS=${NS:-xpam}; TAG=${TAG:-v5.1.15}
# system packages are refreshed once a day (security updates such as libexpat)
APT_REFRESH=${APT_REFRESH:-$(date +%Y%m%d)}
CACHE="$HERE/.cache"; mkdir -p "$CACHE"
GO_IMAGE=golang:1.26-trixie
MAVEN_IMAGE=maven:3.9-eclipse-temurin-21
GHOSTTY=ghcr.io/jumpserver-dev/libghostty-vt@sha256:dffb0a53f73862da96df4fadd134dd60ac440a82eb8b9a852d9159b989c86c0c
# Database command-line client shipped in the secureconnection image: same source release as upstream
# (jumpserver-dev/usql v0.1.13), rebuilt with the current Go toolchain and current golang.org/x libraries.
USQL_REPO=https://github.com/jumpserver-dev/usql
USQL_COMMIT=543902712680a21bc5ce939e94454f8736b399e6
USQL_VERSION=0.1.13
say() { printf '\n==> %s\n' "$*"; }

build_core() {
  say "core"
  docker build -q --build-arg APT_REFRESH="$APT_REFRESH" -f "$HERE/core.Dockerfile" -t "$NS/core:$TAG" "$SRC/xpam-core"
}

build_gateway() {
  say "gateway"
  docker build -q --build-arg APT_REFRESH="$APT_REFRESH" -f "$HERE/gateway.Dockerfile" -t "$NS/gateway:$TAG" "$HERE/nginx"
}

build_web() {
  say "web: admin console"
  (cd "$SRC/xpam-web" && node_modules/.bin/vite build --mode production >/dev/null)
  say "web: image"
  docker build -q --build-arg APT_REFRESH="$APT_REFRESH" -f "$HERE/web.Dockerfile" --build-context nginxconf="$HERE/nginx" \
    -t "$NS/web:$TAG" "$SRC/xpam-web"
}

build_workspace() {
  say "workspace: web terminal"
  (cd "$SRC/xpam-workspace" && HUSKY=0 ./node_modules/.bin/nuxt generate >/dev/null 2>&1)
  say "workspace: image"
  docker build -q --build-arg APT_REFRESH="$APT_REFRESH" -f "$HERE/workspace.Dockerfile" --build-context nginxconf="$HERE/nginx" \
    -t "$NS/workspace:$TAG" "$SRC/xpam-workspace/.output/public"
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
      go test ./pkg/httpd/ ./pkg/lion/... ./pkg/common/ ./pkg/config/ ./pkg/sshd/ >/dev/null
      KEY=$(head -c 100 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 32)
      go build -trimpath -ldflags "-X main.Version=v5.1.15-xpam -X github.com/jumpserver/koko/pkg/config.CipherKey=$KEY -w -s" -o /out/koko ./cmd/koko/'
  say "secureconnection: database client"
  [[ -d "$CACHE/usql-src/.git" ]] || git clone -q "$USQL_REPO" "$CACHE/usql-src"
  git -C "$CACHE/usql-src" checkout -q "$USQL_COMMIT"
  docker run --rm -v "$CACHE/usql-src:/ro:ro" -v "$CACHE/sc-out:/out" -v "$CACHE/gocache:/root/.cache/go-build" \
    -v "$CACHE/gomod:/go/pkg/mod" -e CGO_ENABLED=0 -e GOFLAGS=-buildvcs=false -e USQL_VERSION="$USQL_VERSION" "$GO_IMAGE" sh -ec '
      cp -r /ro /src && cd /src
      go get golang.org/x/crypto@v0.58.0 golang.org/x/net@v0.61.0 golang.org/x/text@v0.43.0 golang.org/x/sys@v0.49.0 2>/dev/null
      go mod tidy 2>/dev/null
      go build -trimpath -ldflags "-X github.com/xo/usql/text.CommandVersion=$USQL_VERSION -w -s" -o /out/usql main.go run.go'
  say "secureconnection: image"
  docker build -q --build-arg APT_REFRESH="$APT_REFRESH" -f "$HERE/secureconnection.Dockerfile" -t "$NS/secureconnection:$TAG" "$CACHE/sc-out"
}

build_webconnector() {
  say "webconnector: application jar"
  mkdir -p "$CACHE/wc-out" "$CACHE/m2"
  docker run --rm -v "$SRC/xpam-webconnector:/ro:ro" -v "$CACHE/wc-out:/out" -v "$CACHE/m2:/root/.m2" -w /work \
    "$MAVEN_IMAGE" sh -ec '
      cp -r /ro/. /work/
      mvn -q -B -s settings.xml clean package -Dmaven.test.skip=true
      cp backend/web/target/web-*.jar /out/chen.jar'
  say "webconnector: image"
  docker build -q --build-arg APT_REFRESH="$APT_REFRESH" -f "$HERE/webconnector.Dockerfile" --build-context jar="$CACHE/wc-out" \
    -t "$NS/webconnector:$TAG" "$SRC/xpam-webconnector"
}

build_browser() {
  say "browser"
  docker build -q --build-arg APT_REFRESH="$APT_REFRESH" -f "$HERE/browser.Dockerfile" -t "$NS/browser:$TAG" "$SRC/xpam-secureconnection/browser"
}

build_ai() {
  say "ai: binary"
  mkdir -p "$CACHE/ai-out" "$CACHE/gocache" "$CACHE/gomod"
  docker run --rm -v "$SRC/xpam-ai:/ro:ro" -v "$CACHE/ai-out:/out" -v "$CACHE/gocache:/root/.cache/go-build" \
    -v "$CACHE/gomod:/go/pkg/mod" -e CGO_ENABLED=0 -e GOFLAGS=-buildvcs=false "$GO_IMAGE" sh -ec '
      cp -r /ro /src && cd /src
      go test ./... >/dev/null
      go build -trimpath -ldflags "-s -w -X main.Version=v5.1.15-xpam" -o /out/kael ./cmd/kael'
  say "ai: image"
  docker build -q --build-arg APT_REFRESH="$APT_REFRESH" -f "$HERE/ai.Dockerfile" -t "$NS/ai:$TAG" "$CACHE/ai-out"
}

targets=("$@"); [[ ${#targets[@]} -gt 0 ]] || targets=(core gateway web workspace secureconnection webconnector ai browser)
for t in "${targets[@]}"; do "build_$t"; done
say "done"
docker images --format '{{.Repository}}:{{.Tag}}  {{.ID}}  {{.CreatedSince}}' | grep -E "^$NS/(core|gateway|web|workspace|secureconnection|webconnector|ai):$TAG " | sort
