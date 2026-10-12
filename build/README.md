# XPAM image builds

Overlay images on top of the **pristine** upstream JumpServer v5.0.0 images. Never build from an
image made with `docker commit`: it carries the running container's environment (secrets).

Base images are the official `jumpserver/*:v5.0.0-ce` images, pinned by digest in each Dockerfile, so
every build host starts from the same bytes.

## Build everything
```bash
./build-all.sh                      # all five images, tagged xpam/<name>:v5.0.0
./build-all.sh core web             # only some
TAG=v5.0.1 NS=xpam SRC=/opt ./build-all.sh
```
The script expects the source repos side by side in `$SRC` (`xpam-core`, `xpam-web`, `xpam-workspace`,
`xpam-secureconnection`, `xpam-webconnector`, `xpam-ai`), with `apps/xpack` present in `xpam-core`
(it is not on GitHub) and `node_modules` installed in `xpam-web` and `xpam-workspace`. It runs the Go
tests before compiling. The sections below describe what it does per image.

## Publish to GitHub Container Registry
```bash
docker login ghcr.io -u <github-user>          # token with write:packages; done by a person
./push-ghcr.sh <github-user>                   # pushes ghcr.io/<github-user>/xpam/<name>:<tag>
```
On an install host set `XPAM_IMAGE_REGISTRY=ghcr.io/<github-user>/xpam` in `config.txt` (and
`docker login ghcr.io` there if the packages are private). Keep `xpam/core` private: it contains
the license code.

| Component | Image | Public path | Legacy path |
|---|---|---|---|
| core | `xpam/core` | `/core/`, `/api/` | — |
| web | `xpam/web` | `/web/` | `/ui/` (301) |
| workspace | inside `xpam/web` | `/workspace/` (`terminal/`, `desktop/` pages) | `/luna/` (301), `/workspace/koko/`, `/workspace/lion/` (301) |
| secureconnection (koko) | `xpam/secureconnection` | `/secureconnection/`, `/secureconnection/desktop/` | `/koko/`, `/koko/lion/` (hidden proxy alias) |
| webconnector (chen) | `xpam/webconnector` | `/webconnector/` | `/chen/` (hidden proxy alias) |
| ai (kael) | `xpam/ai` | `/ai/` | `/kael/` (hidden proxy alias) |

Tag every image with the installer's XPAM version (`XPAM_DEFAULT_VERSION=v5.0.0` in `static.env`) so compose picks it up.

The Dockerfile-specific `*.dockerignore` files need BuildKit (default in current Docker).

## core (Django) — `xpam/core`
```bash
docker build -f /opt/xpam-build/core.Dockerfile -t xpam/core:<tag> /opt/xpam-core
```
Copies `apps/` (including `apps/xpack`) and upgrades the Python packages listed in the Dockerfile.

## web (admin UI + workspace + nginx) — `xpam/web`
Public paths: `/web/` (admin UI, served from `/opt/web`) and `/workspace/` (web terminal, served
from `/opt/workspace`). The old `/ui/` and `/luna/` paths return 301 redirects to the new ones.
All nginx files baked into the image live in `nginx/` (`default.conf`, `common.conf`,
`interface_security.conf`, `secureconnection.conf`, `webconnector.conf`, `ai.conf`). The image's
init script toggles the last three with `KOKO_ENABLED`, `CHEN_ENABLED` and `KAEL_ENABLED`.
Build the frontends first:
```bash
cd /opt/xpam-web && node_modules/.bin/vite build --mode production
cd /opt/xpam-workspace && HUSKY=0 ./node_modules/.bin/nuxt generate
```
Then:
```bash
docker build -f /opt/xpam-build/web.Dockerfile \
  --build-context workspace=/opt/xpam-workspace/.output/public \
  --build-context nginxconf=/opt/xpam-build/nginx \
  -t xpam/web:<tag> /opt/xpam-web
```

## secureconnection (koko: SSH/RDP gateway with native RemoteApp) — `xpam/secureconnection`
koko links the native library libghostty-vt (pinned image
`ghcr.io/jumpserver-dev/libghostty-vt@sha256:dffb0a53…`, extracted to a local directory) and uses
the vendored SDK in `third_party/sdk-go` (see its `XPAM-PATCHES.md`). The httpd tests write a
`data/` folder, so test on a writable copy.

```bash
# extract libghostty once
docker create --name ghostty ghcr.io/jumpserver-dev/libghostty-vt@sha256:dffb0a53f73862da96df4fadd134dd60ac440a82eb8b9a852d9159b989c86c0c
docker cp ghostty:/opt/libghostty-vt ./libghostty-vt && docker rm ghostty

# test and build the binary (Go 1.26, CGO, random CipherKey like upstream's Makefile)
docker run --rm -v /opt/xpam-secureconnection:/ro:ro -v $PWD/libghostty-vt:/opt/libghostty-vt:ro \
  -v $PWD/out:/out -e CGO_ENABLED=1 -e GOFLAGS=-buildvcs=false \
  -e PKG_CONFIG_PATH=/opt/libghostty-vt/share/pkgconfig golang:1.26-trixie sh -c 'cp -r /ro /src && cd /src && \
  go test ./pkg/httpd/ ./pkg/lion/... ./pkg/common/ ./pkg/config/ && \
  KEY=$(head -c 100 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 32) && \
  go build -trimpath -ldflags "-X main.Version=v5.0.0-xpam -X github.com/jumpserver/koko/pkg/config.CipherKey=$KEY -w -s" \
  -o /out/koko ./cmd/koko/'

docker build -f /opt/xpam-build/secureconnection.Dockerfile -t xpam/secureconnection:<tag> ./out
```
The repo's own `Dockerfile`/`Dockerfile-base` also work (they copy `third_party/sdk-go`).

## webconnector (chen) — `xpam/webconnector`
Overlay that switches the Spring context path to `/webconnector`:
```bash
docker build -f /opt/xpam-build/webconnector.Dockerfile -t xpam/webconnector:<tag> /opt/xpam-webconnector/config
```

## ai (kael) — `xpam/ai`
```bash
docker run --rm -v /opt/xpam-ai:/ro:ro -v $PWD/ai-out:/out -e CGO_ENABLED=0 -e GOFLAGS=-buildvcs=false \
  golang:1.26-trixie sh -c 'cp -r /ro /src && cd /src && go test ./... && \
  go build -trimpath -ldflags "-s -w -X main.Version=v5.0.0-xpam" -o /out/kael ./cmd/kael'
docker build -f /opt/xpam-build/ai.Dockerfile -t xpam/ai:<tag> ./ai-out
```

## Deploy
The installer compose files use `${NAMESPACE:-xpam}` for core, celery, koko, web and init-db
(`web.yml` no longer bind-mounts the host's `/opt/luna`). Tag the images with your `VERSION`, then
recreate the services. nginx resolves upstreams such as `chen` at start, so test the web image on
the compose network rather than with `nginx -t` during the build.

nginx resolves the service names once at start, so **after recreating koko, chen or kael on their
own, reload the web container** (`docker exec xpam_web nginx -s reload`) or nginx keeps the old
container IP and returns 502. `xpamctl restart` restarts everything and is not affected.
Keep about 5 GB free disk before building: a full koko compile needs ~3 GB of cache.
