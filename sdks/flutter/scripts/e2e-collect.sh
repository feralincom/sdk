#!/usr/bin/env bash
# Gerçek services/collect + PostgreSQL ile Flutter SDK uçtan uca testi.
# Gereksinim: Go, Flutter ve erişilebilir bir test veritabanı.
#   DATABASE_URL='postgres://...' sdks/flutter/scripts/e2e-collect.sh
# Üretim veritabanına bağlamayın: COLLECT_AUTO_MIGRATE=true ile outbox tabloları oluşturulur ve deneme olayı yazılır.
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL zorunlu (yalnız test veritabanı)}"
here="$(cd "$(dirname "$0")" && pwd)"
flutter_root="$(cd "$here/.." && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
addr="${COLLECT_ADDR:-127.0.0.1:4692}"
key="${FERALIN_E2E_PROJECT_KEY:-pk_test_feralin_sample_local}"
work="$(mktemp -d)"
collect_pid=""

cleanup() {
  [ -n "$collect_pid" ] && kill "$collect_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

go build -C "$repo_root/services/collect" -o "$work/collect.exe" ./cmd/collect
COLLECT_ADDR="$addr" COLLECT_AUTO_MIGRATE=true COLLECT_PROJECT_KEYS="$key=tenant_sdk_e2e:proj_sdk_e2e" \
  "$work/collect.exe" >"$work/collect.log" 2>&1 &
collect_pid=$!

for _ in $(seq 1 40); do
  if curl -fsS "http://$addr/v1/health" >"$work/health.json" 2>/dev/null; then break; fi
  sleep 0.5
done
grep -q '"outbox":"postgres"' "$work/health.json" || { echo "collect PostgreSQL outbox ile açılmadı"; cat "$work/collect.log"; exit 1; }
echo "health: $(cat "$work/health.json")"

cd "$flutter_root"
rm -f build/e2e/flutter-outbox-checks.txt
# Etiketli dosya tek başına çalıştırılır; atlanan test olursa başarı sayılmaz.
output="$work/test.txt"
FERALIN_E2E_COLLECT_URL="http://$addr" FERALIN_E2E_PROJECT_KEY="$key" \
  flutter test test/collector_e2e_test.dart --reporter expanded 2>&1 | tee "$output"
grep -q "All tests passed!" "$output" || { echo "E2E testleri tam geçmedi"; exit 1; }
if grep -q "~" "$output" && grep -Eq "\+[0-9]+ ~[0-9]+" "$output"; then echo "Atlanan E2E testi var"; exit 1; fi

(cd "$repo_root/services/collect" && go run "$repo_root/sdks/android/scripts/outbox_check.go" "$flutter_root/build/e2e/flutter-outbox-checks.txt")
echo "collect 202 logu: $(grep -c '"status":202' "$work/collect.log")  401 logu: $(grep -c '"status":401' "$work/collect.log")"
