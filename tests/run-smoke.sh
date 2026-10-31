#!/usr/bin/env bash
# Полный прогон apply -> verify -> идемпотентный apply в systemd-контейнере.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
BASE="${BASE:-ubuntu:24.04}"
OUT="tests/out"; mkdir -p "$OUT"
TAG="bootstrap-smoke:$(date +%s)"

cleanup() { docker rm -f bootstrap-smoke >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== собираю образ ($BASE)"
docker build --build-arg BASE="$BASE" -t "$TAG" -f tests/smoke/Dockerfile tests/smoke >"$OUT/build.log" 2>&1

echo "== запускаю systemd-контейнер"
docker run -d --name bootstrap-smoke --privileged --cgroupns=private \
  --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$TAG" >/dev/null

for _ in $(seq 1 30); do
  docker exec bootstrap-smoke systemctl is-system-running >/dev/null 2>&1 && break
  sleep 1
done

KEY="$(mktemp)"; ssh-keygen -t ed25519 -N '' -f "$KEY" >/dev/null
docker cp bootstrap.sh bootstrap-smoke:/bootstrap.sh
docker cp "$KEY.pub" bootstrap-smoke:/tmp/key.pub

run() { docker exec -e SSH_CONNECTION="10.0.0.1 40000 10.0.0.2 22" bootstrap-smoke "$@"; }

echo "== --check"
run bash /bootstrap.sh check --key "$(cat "$KEY.pub")" | tee "$OUT/check.log"

echo "== apply"
run bash /bootstrap.sh apply --yes --force --swap 0 --key "$(cat "$KEY.pub")" 2>&1 | tee "$OUT/apply.log"

echo "== verify"
run bash /bootstrap.sh verify --json | tee "$OUT/verify.json"

grep -q '"ok":true' "$OUT/verify.json"

echo "== повторный apply (идемпотентность)"
run bash /bootstrap.sh apply --yes --force --swap 0 --key "$(cat "$KEY.pub")" 2>&1 | tee "$OUT/apply2.log"

echo "OK: smoke пройден"
