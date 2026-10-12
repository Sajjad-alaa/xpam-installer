# XPAM secureconnection: official JumpServer v5.0.0 koko image + XPAM-built binary
# (native RDP RemoteApp, public path /secureconnection/, remote desktop under /secureconnection/desktop/).
# Build the binary from /opt/xpam-secureconnection first (see README in this folder), then:
#   docker build -f secureconnection.Dockerfile -t xpam/secureconnection:<tag> <dir containing the koko binary>
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/koko@sha256:6884e2b8bc6b9da9d991ebf045691277bb9bceec4ef10699aa12492adde3aa16
COPY koko /opt/koko/koko
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:5000/secureconnection/health/
