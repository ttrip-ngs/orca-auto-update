# orca serve の初回構築(展開済みツリー方式)

orca-auto-update が前提とする構成を新しいホストに作る手順。Ubuntu 24.04 で確認。

## 1. 展開

libfuse2 が無くても展開できるよう、AppImage を実行せずに `unsquashfs` で取り出す。

```bash
sudo apt install squashfs-tools binutils
VER=$(curl -fsSL https://api.github.com/repos/stablyai/orca/releases/latest | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])')
mkdir -p ~/tmp/orca-setup && cd ~/tmp/orca-setup
curl -fLO "https://github.com/stablyai/orca/releases/download/$VER/orca-linux.AppImage"
curl -fLO "https://github.com/stablyai/orca/releases/download/$VER/latest-linux.yml"
# latest-linux.yml の orca-linux.AppImage の sha512 と比べる
openssl dgst -sha512 -binary orca-linux.AppImage | base64 -w0; echo

OFF=$(readelf -h orca-linux.AppImage | awk '/Start of section headers/{s=$5} /Size of section headers/{z=$5} /Number of section headers/{n=$5} END{print s+z*n}')
sudo mkdir -p /opt/orca
sudo unsquashfs -q -n -no-xattrs -o "$OFF" -d /opt/orca/squashfs-root orca-linux.AppImage
sudo chown -hR root:root /opt/orca/squashfs-root
sudo chmod -R a+rX,go-w /opt/orca/squashfs-root
/opt/orca/squashfs-root/AppRun --version
```

## 2. system unit

`/etc/systemd/system/orca-serve.service` の例。`User` は Orca に作業させるユーザ
(リポジトリ・SSH 鍵・gh トークンなどにアクセスできるユーザ)。

```ini
[Unit]
Description=Orca runtime server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=<ユーザ>
WorkingDirectory=/home/<ユーザ>
Environment=LIBGL_ALWAYS_SOFTWARE=1
ExecStart=/opt/orca/squashfs-root/AppRun serve --port 6768 --pairing-address <クライアントから到達できるアドレス>
KillMode=mixed
Restart=on-failure
RestartPreventExitStatus=3
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now orca-serve
journalctl -u orca-serve -o cat | grep -E 'Orca server ready|Terminal daemon'
```

ペアリング用の URL は `journalctl -u orca-serve -o cat | grep -E 'Web client URL|Pairing URL'` で取れる。
deviceToken を含むので、チャットやチケットに貼らないこと。

6768 番に届く範囲はファイアウォールで絞ること。Orca のエージェントはこのユーザの権限
(sudo / docker グループに入っていれば実質 root)で動く。

## 3. 自動更新

[README](../README.md) の「導入」へ。
