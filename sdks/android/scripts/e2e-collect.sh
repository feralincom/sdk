#!/usr/bin/env bash
# Gerçek services/collect + PostgreSQL ile Android SDK uçtan uca testi.
# Gereksinim: Go, JDK 17, ANDROID_HOME ve erişilebilir bir test veritabanı.
#   DATABASE_URL='postgres://...' sdks/android/scripts/e2e-collect.sh
# Üretim veritabanına bağlamayın: COLLECT_AUTO_MIGRATE=true ile outbox tabloları oluşturulur ve deneme olayı yazılır.
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL zorunlu (yalnız test veritabanı)}"
here="$(cd "$(dirname "$0")" && pwd)"
android_root="$(cd "$here/.." && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
addr="${COLLECT_ADDR:-127.0.0.1:4691}"
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

cd "$android_root"
rm -f feralin/build/e2e/android-outbox-checks.txt
FERALIN_E2E_COLLECT_URL="http://$addr" FERALIN_E2E_PROJECT_KEY="$key" \
  ./gradlew :feralin:testDebugUnitTest --tests '*CollectorE2ETest' --rerun-tasks --console=plain -q

python - "$android_root/feralin/build/test-results/testDebugUnitTest/TEST-com.feralin.android.internal.CollectorE2ETest.xml" <<'EOF'
import sys, xml.etree.ElementTree as E
root = E.parse(sys.argv[1]).getroot()
print(f"CollectorE2ETest: tests={root.get('tests')} failures={root.get('failures')} errors={root.get('errors')} skipped={root.get('skipped')}")
for case in root.findall('testcase'):
    print("  OK" if len(case) == 0 else "  KALDI", case.get('name'))
if int(root.get('skipped')) or int(root.get('failures')) or int(root.get('errors')):
    sys.exit(1)
EOF

(cd "$repo_root/services/collect" && go run "$android_root/scripts/outbox_check.go" "$android_root/feralin/build/e2e/android-outbox-checks.txt")
echo "collect 202 logu: $(grep -c '"status":202' "$work/collect.log")  401 logu: $(grep -c '"status":401' "$work/collect.log")"
