#!/usr/bin/env bash
# まっさらな Ubuntu に install.sh 一発で導入できることを、systemd 入りコンテナで本物の Orca を使って検証する。
# ホスト(Docker が使える環境)で実行する: bash tests/fresh-install.sh
set -u
SRC=$(cd "$(dirname "$0")/.." && pwd)
NAME=orca-fresh-install-$$
IMAGE=orca-fresh-install-test
FAILS=0
LOG=$(mktemp)

docker build -q -t "$IMAGE" - <<'EOF' >/dev/null || exit 1
FROM ubuntu:24.04
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv dbus libpam-systemd >/dev/null && useradd -m orca
CMD ["/sbin/init"]
EOF
trap 'docker rm -f "$NAME" >/dev/null 2>&1; rm -f "$LOG"' EXIT
# systemd を PID 1 で動かすため --privileged が要る(cgroup はコンテナ専用の名前空間)
docker run -d --name "$NAME" --privileged --cgroupns=private -e container=docker \
  --tmpfs /run --tmpfs /run/lock -v "$SRC":/src:ro "$IMAGE" >/dev/null || exit 1

cx() { docker exec "$NAME" bash -c "$1"; }
check() { # $1=説明 $2=コンテナ内で評価する条件
  if cx "$2" >/dev/null 2>&1; then echo "  ok: $1"; else echo "  NG: $1"; FAILS=$((FAILS + 1)); fi
}
# 使い捨てコンテナの資格情報でも、CI のログには出さない
install_sh() {
  cx "bash /src/install.sh $1" 2>&1 | sed -u -E 's/(#pairing=|code=).*/\1<REDACTED>/' | tee "$LOG"
  return "${PIPESTATUS[0]}"
}
shown() { # $1=説明 $2=出力に含まれるべき文字列
  if grep -qF -- "$2" "$LOG"; then echo "  ok: $1"; else echo "  NG: $1"; FAILS=$((FAILS + 1)); fi
}
for _ in $(seq 1 30); do
  cx 'systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"' && break
  sleep 1
done

echo "=== 1. まっさらな環境に install.sh ==="
for c in curl unsquashfs ss; do
  cx "command -v $c" && { echo "  NG: $c が既に入っている"; FAILS=$((FAILS + 1)); }
done
# ufw が有効な環境の案内を確かめるためのスタブ
cx "printf '#!/bin/sh\necho Status: active\n' > /usr/local/bin/ufw; chmod +x /usr/local/bin/ufw"
install_sh '--user orca'; rc=$?
check "install.sh が成功 (rc=$rc)" "[ $rc -eq 0 ]"
check "orca-serve が active" 'systemctl is-active orca-serve'
check ":6768 が LISTEN" 'ss -Hltn "sport = :6768" | grep -q LISTEN'
check "展開済みツリーから起動している" '[ "$(stat -L -c %i /proc/$(systemctl show -p MainPID --value orca-serve)/exe)" = "$(stat -c %i /opt/orca/squashfs-root/orca-ide)" ]'
check "timer が有効" 'systemctl is-enabled orca-auto-update.timer'
check "linger が有効" '[ "$(loginctl show-user orca -p Linger --value)" = yes ]'
check "NRestarts=0" '[ "$(systemctl show -p NRestarts --value orca-serve)" = 0 ]'
addr=$(cx 'ip route get 1.1.1.1' | sed -n 's/.* src \([^ ]*\).*/\1/p')
check "既定経路のアドレス ($addr) を unit に入れる" "[ -n '$addr' ] && grep -q -- '--pairing-address $addr\$' /etc/systemd/system/orca-serve.service"
shown "Web client URL を表示する" "Web client URL: http://"
# コンテナの外(別マシンの代わり)から、表示したアドレスの Web クライアントへ届くこと
if curl -fsS --max-time 10 -o /dev/null "http://$addr:6768/web-index.html"; then echo "  ok: コンテナの外から接続できる"; else echo "  NG: コンテナの外から接続できない"; FAILS=$((FAILS + 1)); fi
shown "Pairing URL を表示する" "Pairing URL: orca://pair?code="
shown "ufw が閉じていれば案内する" "sudo ufw allow from"

echo "=== 2. もう一度実行しても何も変わらない ==="
before=$(cx 'systemctl show -p MainPID --value orca-serve; sha256sum /etc/systemd/system/orca-serve.service')
install_sh '--user orca --pairing-address 192.0.2.1'; rc=$?
after=$(cx 'systemctl show -p MainPID --value orca-serve; sha256sum /etc/systemd/system/orca-serve.service')
check "再実行が成功 (rc=$rc)" "[ $rc -eq 0 ]"
check "サービスと unit はそのまま" "[ '$before' = '$after' ]"
shown "URL は確認コマンドだけを表示する" "接続用 URL の確認:"
if grep -qF 'Web client URL: http' "$LOG"; then echo "  NG: URL を再表示している"; FAILS=$((FAILS + 1)); fi

echo "=== 3. 導入したホストで自動更新が動く ==="
cx 'grep -o "X-AppImage-Version=.*" /opt/orca/squashfs-root/orca-ide.desktop'
cx 'systemd-run --wait --collect -u orca-auto-update-now /usr/local/sbin/orca-auto-update --no-wait'; rc=$?
cx 'journalctl -u orca-auto-update-now -o cat --no-pager | grep orca-auto-update'
check "--no-wait が成功 (rc=$rc)" "[ $rc -eq 0 ]"
check "更新後も active" 'systemctl is-active orca-serve'
latest=$(curl -fsSL https://api.github.com/repos/stablyai/orca/releases/latest | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"][1:])')
check "最新版 $latest になっている" "grep -q 'X-AppImage-Version=$latest' /opt/orca/squashfs-root/orca-ide.desktop"
cx 'systemctl start orca-auto-update.service'; rc=$?
cx 'journalctl -u orca-auto-update -o cat --no-pager | grep orca-auto-update | tail -1'
check "通常の実行が成功 (rc=$rc)" "[ $rc -eq 0 ]"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASSED"; else echo "$FAILS 件失敗"; exit 1; fi
