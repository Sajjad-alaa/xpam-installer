# XPAM image builds

Overlay images on top of the **pristine** upstream JumpServer v5.0.0 images. Never build from an
image made with `docker commit`: it carries the running container's environment (secrets).

Base images are the official `jumpserver/*:v5.0.0-ce` images, pinned by digest in each Dockerfile, so
every build host starts from the same bytes.

## Build everything
```bash
./build-all.sh                      # all seven images, tagged xpam/<name>:v5.1.12
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
| gateway | `xpam/gateway` | front door for every path below | — |
| core | `xpam/core` | `/core/`, `/api/` | — |
| web | `xpam/web` | `/web/` | `/ui/` (301) |
| workspace | `xpam/workspace` | `/workspace/` (`terminal/`, `desktop/` pages) | `/luna/` (301), `/workspace/koko/`, `/workspace/lion/` (301) |
| secureconnection (koko) | `xpam/secureconnection` | `/secureconnection/`, `/secureconnection/desktop/` | `/koko/`, `/koko/lion/` (hidden proxy alias) |
| webconnector (chen) | `xpam/webconnector` | `/webconnector/` | `/chen/` (hidden proxy alias) |
| ai (kael) | `xpam/ai` | `/ai/` | `/kael/` (hidden proxy alias) |

Tag every image with the installer's XPAM version (`XPAM_DEFAULT_VERSION=v5.1.12` in `static.env`) so compose picks it up.

The Dockerfile-specific `*.dockerignore` files need BuildKit (default in current Docker).

Every image installs the current Debian security updates on top of the pinned upstream image
(`apt-get upgrade`). The upstream images point apt at a mirror that only answers inside Alibaba
Cloud, so the Dockerfiles switch it to `deb.debian.org` first. Rebuild and republish the images
regularly to pick up new OS fixes; `build-all.sh` uses the current `golang:1.26-trixie` toolchain
for the Go services, so `docker pull golang:1.26-trixie` before a release build.

## core (Django) — `xpam/core`
```bash
docker build -f /opt/xpam-build/core.Dockerfile -t xpam/core:<tag> /opt/xpam-core
```
Copies `apps/` (including `apps/xpack`) and upgrades the Python packages listed in the Dockerfile.

## gateway (front door) — `xpam/gateway`
The official JumpServer web image (nginx, TLS and its startup script) without application files.
It publishes ports 80/443 and routes: `/web/` and `/workspace/` to their containers, the service
paths to the services, and it serves `/static/`, `/media/` and `/download/` itself. Its nginx files
are in `nginx/`: `default.conf`, `common.conf`, `interface_security.conf`, `secureconnection.conf`,
`webconnector.conf`, `ai.conf`. The startup script toggles the last three with `KOKO_ENABLED`,
`CHEN_ENABLED` and `KAEL_ENABLED`.
```bash
docker build -f /opt/xpam-build/gateway.Dockerfile -t xpam/gateway:<tag> /opt/xpam-build/nginx
```
The front server passes the address (`Host` with port) and scheme (`X-Forwarded-Proto`) the browser
really used to core, so sign-in works through any address without listing it in `DOMAINS`; with
`USE_LB=0` the scheme reported by the load balancer in front is used instead.

Routes to `core`, `web`, `workspace`, `koko`, `chen` and `kael` use a variable in `proxy_pass`, so nginx
looks the address up per request (resolver in the base `nginx.conf`, cached 10 s). That is what
lets the gateway start while a component is missing and find a recreated one without a reload.
In a location with `rewrite ... break`, the `set` must come first.
Every route must use this form. A fixed `proxy_pass http://name:port` is resolved once at start;
when that service is recreated, its old address can be handed to another container, and the
gateway would then send requests there. That happened once with core and the admin console.
The static containers also refuse every path outside their own prefix for the same reason.

## web (admin console) — `xpam/web` and workspace (web terminal) — `xpam/workspace`
Each is a plain nginx on port 8090 (used by no other XPAM service) that serves one folder (`/opt/web` under `/web/`,
`/opt/workspace` under `/workspace/`) with the single-page-app fallback, plus `/health`.
No ports are published. Config: `nginx/web-static.conf`, `nginx/workspace-static.conf`.
```bash
cd /opt/xpam-web && node_modules/.bin/vite build --mode production
docker build -f /opt/xpam-build/web.Dockerfile --build-context nginxconf=/opt/xpam-build/nginx \
  -t xpam/web:<tag> /opt/xpam-web

cd /opt/xpam-workspace && HUSKY=0 ./node_modules/.bin/nuxt generate
docker build -f /opt/xpam-build/workspace.Dockerfile --build-context nginxconf=/opt/xpam-build/nginx \
  -t xpam/workspace:<tag> /opt/xpam-workspace/.output/public
```
The desktop client does not use `xpam/workspace`: it carries its own copy of the workspace UI and
talks to the gateway for the API and sessions.

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
  go build -trimpath -ldflags "-X main.Version=v5.1.12-xpam -X github.com/jumpserver/koko/pkg/config.CipherKey=$KEY -w -s" \
  -o /out/koko ./cmd/koko/'

docker build -f /opt/xpam-build/secureconnection.Dockerfile -t xpam/secureconnection:<tag> ./out
```
The repo's own `Dockerfile`/`Dockerfile-base` also work (they copy `third_party/sdk-go`).

## webconnector (chen) — `xpam/webconnector`
The application jar is rebuilt from `/opt/xpam-webconnector` (Maven, JDK 21) so its Spring Boot,
Tomcat, Netty and Jackson versions can be patched in `pom.xml`; the overlay also replaces the
PostgreSQL driver and switches the context path to `/webconnector`.
```bash
docker run --rm -v /opt/xpam-webconnector:/ro:ro -v $PWD/wc-out:/out -v $PWD/m2:/root/.m2 -w /work \
  maven:3.9-eclipse-temurin-21 sh -ec 'cp -r /ro/. /work/ && \
  mvn -q -B -s settings.xml clean package -Dmaven.test.skip=true && cp backend/web/target/web-*.jar /out/chen.jar'
docker build -f /opt/xpam-build/webconnector.Dockerfile --build-context jar=$PWD/wc-out \
  -t xpam/webconnector:<tag> /opt/xpam-webconnector
```
The SQL Server driver is loaded by its exact file name, so updating it means changing
`SQLServerConnectionManager.java` as well.

## ai (kael) — `xpam/ai`
```bash
docker run --rm -v /opt/xpam-ai:/ro:ro -v $PWD/ai-out:/out -e CGO_ENABLED=0 -e GOFLAGS=-buildvcs=false \
  golang:1.26-trixie sh -c 'cp -r /ro /src && cd /src && go test ./... && \
  go build -trimpath -ldflags "-s -w -X main.Version=v5.1.12-xpam" -o /out/kael ./cmd/kael'
docker build -f /opt/xpam-build/ai.Dockerfile -t xpam/ai:<tag> ./ai-out
```

## Deploy
The installer compose files (`compose/gateway.yml`, `web.yml`, `workspace.yml`, `core.yml`, ...) use
`${XPAM_NAMESPACE:-xpam}/<name>:<XPAM version>`. Build or pull the images, then `xpamctl start`.
To roll out a new admin console or workspace build, rebuild that image and
`xpamctl raw up -d web` (or `workspace`); the gateway and running sessions are not touched.
Test gateway changes on the compose network: `nginx -t` during the build cannot resolve `core`.
Keep about 5 GB free disk before building: a full secureconnection compile needs ~3 GB of cache.
