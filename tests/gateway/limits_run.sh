#!/usr/bin/env bash
# The gateway's rate limits, standalone (nothing of the live system is used); a stand-in "core" answers at once
# (any status but 429 = passed the limit).   tests/gateway/limits_run.sh
docker network create xgwnet >/dev/null 2>&1
docker rm -f -v xgwcore >/dev/null 2>&1
docker run -d --rm --name xgwcore --network xgwnet --network-alias core --entrypoint python3 xpam/browser:rn -m http.server 8080 >/dev/null
run() { docker rm -f -v xgw >/dev/null 2>&1; docker run -d --name xgw --network xgwnet "$@" xpam/gateway:rn >/dev/null; for _ in $(seq 30); do docker exec xgw nginx -t >/dev/null 2>&1 && break; sleep 1; done; sleep 2; }
# n requests sent together (20 at a time)
codes() { docker run --rm --network xgwnet --entrypoint sh curlimages/curl:8.11.1 -c "seq $1 | xargs -P 20 -I{} curl -s -m 10 -o /dev/null -w '%{http_code}\n' $2 http://xgw/$3" | sort | uniq -c | tr -s ' \n' ' '; }
run -e USE_LB=1
echo "60 sign-in POSTs at once:         $(codes 60 '-X POST' core/auth/login/)"
echo "120 sign-in page GETs:            $(codes 120 '' core/auth/login/)"
echo "60 connection-token POSTs:        $(codes 60 '-X POST' api/v1/authentication/connection-token/)"
echo "1000 requests at once (flood):    $(codes 1000 '' api/health/)"
run -e USE_LB=0
echo "LB: 60 POSTs from one client:     $(codes 60 "-X POST -H 'X-Forwarded-For: 6.6.6.6, 203.0.113.9'" core/auth/login/)"
echo "LB: 25 POSTs from 3 clients each: $(for c in 203.0.113.1 203.0.113.2 203.0.113.3; do codes 25 "-X POST -H 'X-Forwarded-For: $c'" core/auth/login/; done)"
run -e RATE_LIMIT_ENABLED=0
echo "limits off: 60 POSTs:             $(codes 60 '-X POST' core/auth/login/)"
docker rm -f -v xgw xgwcore >/dev/null; docker network rm xgwnet >/dev/null
