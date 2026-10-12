# XPAM ai: official JumpServer v5.0.0 kael image + XPAM-built binary (public path /ai/).
# Build the binary from /opt/xpam-ai first (see README in this folder), then:
#   docker build -f ai.Dockerfile -t xpam/ai:<tag> <dir containing the kael binary>
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/kael@sha256:683a00265ad23cbc9ebf38a0a8e3e53717489f62f41644ba65e9da2750c5c420
COPY kael /opt/kael/kael
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:8083/ai/health/ready
