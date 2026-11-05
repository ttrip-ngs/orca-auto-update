#!/usr/bin/env bash
# orca-auto-update の入れ替え・失敗時の復旧を検証する。使い捨てコンテナ内で root として実行すること:
#   docker run --rm -v "$PWD":/src:ro ubuntu:24.04 bash /src/tests/failure-paths.sh
# systemctl / ss / journalctl / curl はスタブ。orca-ide は sleep のコピーで、ツリー内の目印ファイルで挙動を変える:
#   BROKEN             起動に失敗する
#   MIGRATES           起動時にプロファイルへ MIGRATED を作る(新版のプロファイル移行を模擬)
#   NEEDS_OLD_PROFILE  プロファイルに MIGRATED があると起動に失敗する
set -u
[ "$(id -u)" -eq 0 ] && [ -f /.dockerenv ] || { echo "使い捨てコンテナ内で root として実行すること"; exit 1; }
SRC=$(cd "$(dirname "$0")/.." && pwd)
FAKE=/run/fake
FAILS=0

command -v python3 >/dev/null || { apt-get update -qq && apt-get install -y -qq python3 >/dev/null; } || exit 1
useradd -m orca 2>/dev/null || true
PROFILE=/home/orca/.config/orca
echo "ORCA_SVC_USER=orca" > /etc/default/orca-auto-update
mkdir -p $FAKE /usr/local/stub

cat > /usr/local/stub/systemctl <<'EOF'
#!/bin/bash
pidf=/run/fake/pid
running() { [ -f $pidf ] && kill -0 "$(cat $pidf)" 2>/dev/null; }
tree=/opt/orca/squashfs-root
broken() { [ -e $tree/BROKEN ] || { [ -e $tree/NEEDS_OLD_PROFILE ] && [ -e /home/orca/.config/orca/MIGRATED ]; }; }
case "$1" in
  stop) [ -n "${STUB_SLOW_STOP:-}" ] && sleep 5; running && kill "$(cat $pidf)"; rm -f $pidf ;;
  start)
    [ -x $tree/orca-ide ] || exit 1
    [ -e $tree/MIGRATES ] && touch /home/orca/.config/orca/MIGRATED
    broken && exit 1
    # fd 9(ロック)を引き継がない: 本物の systemd はサービスに fd を渡さない
    setsid $tree/orca-ide 9999 >/dev/null 2>&1 9>&- & echo $! > $pidf ;;
  is-active) running && echo active || echo failed ;;
  show) case "$*" in *MainPID*) if running; then cat $pidf; else echo 0; fi ;; *NRestarts*) echo 0 ;; esac ;;
esac
exit 0
EOF
cat > /usr/local/stub/ss <<'EOF'
#!/bin/bash
[ -f /run/fake/pid ] && kill -0 "$(cat /run/fake/pid)" 2>/dev/null && echo "LISTEN 0 511 0.0.0.0:6768 0.0.0.0:*"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > /usr/local/stub/journalctl
printf '#!/bin/bash\nexit 1\n' > /usr/local/stub/pgrep
# リリース一覧は $FAKE/releases.json を返す。ダウンロードは失敗させ、版の選択までを確かめる
cat > /usr/local/stub/curl <<'EOF'
#!/bin/bash
case "$*" in
  *'releases?per_page='*) exec cat /run/fake/releases.json ;;
esac
exit 22
EOF
chmod +x /usr/local/stub/*
export PATH=/usr/local/stub:$PATH
# 起動確認の固定待ち(10秒)だけ短くしたコピーを使う
U=/usr/local/sbin/orca-auto-update
sed 's/sleep 10   # 起動直後/sleep 1   # 起動直後/' "$SRC/orca-auto-update" > $U
chmod +x $U

mktree() { # $1=dir $2=version [目印...]
  local d=$1 v=$2; shift 2
  mkdir -p "$d"; cp /bin/sleep "$d/orca-ide"; echo "X-AppImage-Version=$v" > "$d/orca-ide.desktop"
  for m in "$@"; do touch "$d/$m"; done
}
reset() {
  [ -f $FAKE/pid ] && kill "$(cat $FAKE/pid)" 2>/dev/null
  rm -rf /opt/orca /var/lib/orca-auto-update /home/orca/.config $FAKE/pid
  mkdir -p /opt/orca $PROFILE
}
running_ver() { [ "$(systemctl is-active)" = active ] && grep -o '[0-9.]*$' /opt/orca/squashfs-root/orca-ide.desktop; }
check() { # $1=説明 $2=条件(eval)
  if eval "$2"; then echo "  ok: $1"; else echo "  NG: $1"; FAILS=$((FAILS + 1)); fi
}
run() { "$U" "$@" 2>&1 | sed 's/^/    /'; return "${PIPESTATUS[0]}"; }

echo "=== A. ロールバック成功 ==="
reset; mktree /opt/orca/squashfs-root 1.4.240; mktree /opt/orca/squashfs-root.1.4.230 1.4.230; systemctl start
run --rollback 1.4.230; rc=$?
check "rc=0" "[ $rc -eq 0 ]"
check "1.4.230 で稼働" '[ "$(running_ver)" = 1.4.230 ]'
check "hold と failed-1.4.240 ができる" '[ -e /var/lib/orca-auto-update/hold ] && [ -e /var/lib/orca-auto-update/failed-1.4.240 ]'
check "1.4.240 のツリーは残す" '[ -d /opt/orca/squashfs-root.1.4.240 ]'

echo "=== B. 新版が起動しない -> 旧版へ自動で戻る ==="
reset; mktree /opt/orca/squashfs-root 1.4.230; mktree /opt/orca/squashfs-root.1.4.240 1.4.240 BROKEN; systemctl start
run --rollback 1.4.240; rc=$?
check "rc=1" "[ $rc -eq 1 ]"
check "1.4.230 で稼働" '[ "$(running_ver)" = 1.4.230 ]'
check "hold は作らない" '[ ! -e /var/lib/orca-auto-update/hold ]'

echo "=== C. 新版がプロファイルを移行し、旧版が起動しない -> プロファイルを退避から戻す ==="
reset; mktree /opt/orca/squashfs-root 1.4.230 NEEDS_OLD_PROFILE; mktree /opt/orca/squashfs-root.1.4.240 1.4.240 BROKEN MIGRATES
echo v1 > $PROFILE/state; systemctl start
run --rollback 1.4.240; rc=$?
check "rc=1" "[ $rc -eq 1 ]"
check "1.4.230 で稼働" '[ "$(running_ver)" = 1.4.230 ]'
check "稼働中のプロファイルは移行前" '[ ! -e $PROFILE/MIGRATED ] && [ "$(cat $PROFILE/state)" = v1 ]'
check "移行されたプロファイルは failed として残す" '[ -e $PROFILE.failed-1.4.240/MIGRATED ]'

echo "=== D. 停止中に SIGTERM -> EXIT トラップで起動し直す ==="
reset; mktree /opt/orca/squashfs-root 1.4.240; mktree /opt/orca/squashfs-root.1.4.230 1.4.230; systemctl start
STUB_SLOW_STOP=1 "$U" --rollback 1.4.230 > $FAKE/d.out 2>&1 &
P=$!; sleep 2; kill -TERM $P; wait $P; rc=$?
sed 's/^/    /' $FAKE/d.out
check "rc=143" "[ $rc -eq 143 ]"
check "サービスが動いている" '[ -n "$(running_ver)" ]'

echo "=== E. 不正な引数を拒否する ==="
reset; mktree /opt/orca/squashfs-root 1.4.240; systemctl start
run --rollback '../../etc'; rc=$?
check "rc=2" "[ $rc -eq 2 ]"
check "稼働は変わらない" '[ "$(running_ver)" = 1.4.240 ]'

echo "=== F. ORCA_SVC_USER 未設定なら何もしない ==="
echo "ORCA_SVC_USER=" > /etc/default/orca-auto-update
run; rc=$?
check "rc=1" "[ $rc -eq 1 ]"
check "稼働は変わらない" '[ "$(running_ver)" = 1.4.240 ]'

releases() { # 引数は "タグ 経過時間 [prerelease] [noassets]" の並び
  local item tag hours pre noassets assets sep=""
  { echo '['; for item in "$@"; do
      read -r tag hours pre noassets <<<"$item"
      assets='{"name":"latest-linux.yml","url":"https://example.invalid/yml"},{"name":"orca-linux.AppImage","url":"https://example.invalid/img"}'
      [ -z "$noassets" ] || assets='{"name":"latest-linux.yml","url":"https://example.invalid/yml"}'
      printf '%s{"tag_name":"%s","draft":false,"prerelease":%s,"published_at":"%s","assets":[%s]}\n' \
        "$sep" "$tag" "${pre:-false}" "$(date -u -d "$hours hours ago" +%FT%TZ)" "$assets"
      sep=,
    done; echo ']'; } > $FAKE/releases.json
}
# $1=説明 $2=現行版 $3=期待する rc $4=期待するログ(grep -F)。追加の引数はスクリプトへ渡す
select_case() {
  local desc=$1 cur=$2 want_rc=$3 want_log=$4 out rc; shift 4
  out=$("$U" "$@" 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  check "$desc: rc=$want_rc かつ「$want_log」" '[ "$rc" -eq "$want_rc" ] && grep -qF -- "$want_log" <<<"$out"'
  check "$desc: 稼働は $cur のまま" '[ "$(running_ver)" = "$cur" ]'
}

echo "=== G. 更新する版の選択 ==="
echo "ORCA_SVC_USER=orca" > /etc/default/orca-auto-update
reset; mktree /opt/orca/squashfs-root 1.4.245; systemctl start
install -d -m 0700 /var/lib/orca-auto-update
DAILY=("v1.4.250 8" "mobile-android-v0.0.64 13 true" "v1.4.249 19" "v1.4.248 64" "v1.4.251-rc.1 70 true" "v1.4.300 70 true" "v1.4.247 87" "v1.4.246 111")
releases "${DAILY[@]}"
select_case "最新が 24 時間未満なら、たった版のうち最新" 1.4.245 1 "更新: 1.4.245 -> 1.4.248 (公開から 64時間)"
select_case "--no-wait は最新の安定版" 1.4.245 1 "更新: 1.4.245 -> 1.4.250" --no-wait
touch /var/lib/orca-auto-update/failed-1.4.248
select_case "見送り中の版は飛ばす" 1.4.245 1 "更新: 1.4.245 -> 1.4.247"
rm /var/lib/orca-auto-update/failed-1.4.248
releases "v1.4.248 30 false noassets" "v1.4.247 30"
select_case "Linux の資産が揃っていない版は飛ばす" 1.4.245 1 "更新: 1.4.245 -> 1.4.247"
select_case "取得できないファイルを示す" 1.4.245 1 "latest-linux.yml を取得できない: https://example.invalid/yml"
releases "v1.4.246 8"
select_case "24 時間たった版がなければ待つ" 1.4.245 0 "1.4.246 は公開から 8時間。24時間たつまで待つ"
touch /var/lib/orca-auto-update/failed-1.4.246
releases "v1.4.247 8" "v1.4.246 30"
select_case "見送り中の版より新しい版を待つ" 1.4.245 0 "1.4.247 は公開から 8時間"
releases "v1.4.246 30"
select_case "新しい版がすべて見送り中ならエラー" 1.4.245 1 "すべて見送り中"
rm /var/lib/orca-auto-update/failed-1.4.246
releases "v1.4.245 30" "v1.4.244 50"
select_case "現行が最新" 1.4.245 0 "最新 (1.4.245)"
releases "v1.4.244 50"
select_case "取り下げで現行より古い" 1.4.245 0 "最新リリース 1.4.244 が現行 1.4.245 より古い"
reset; mktree /opt/orca/squashfs-root 1.4.9; systemctl start
releases "v1.4.9 90" "v1.4.10 30"
select_case "版番号は数値で比べる" 1.4.9 1 "更新: 1.4.9 -> 1.4.10"
releases "mobile-android-v0.0.64 30 true"
select_case "安定版がなければエラー" 1.4.9 1 "解析できない"
echo 'rate limited' > $FAKE/releases.json
select_case "不正な応答ならエラー" 1.4.9 1 "解析できない"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASSED"; else echo "$FAILS 件失敗"; exit 1; fi
