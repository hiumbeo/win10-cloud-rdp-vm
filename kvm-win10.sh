#!/usr/bin/env bash
set -e
RDP_PASS="${RDP_PASS:-WinCloud!2026Pass}"
echo "[WinCloud] Checking /dev/kvm availability..."
ls -la /dev/kvm || (echo "KVM not available on this runner" && exit 1)
sudo chmod 666 /dev/kvm

mkdir -p ~/win10-storage
docker rm -f win10-ltsc >/dev/null 2>&1 || true
docker run -d --name win10-ltsc \
  --device=/dev/kvm \
  --device=/dev/net/tun \
  --cap-add NET_ADMIN \
  -e VERSION="ltsc10" \
  -e RAM_SIZE="5G" \
  -e CPU_CORES="3" \
  -e DISK_SIZE="40G" \
  -e USERNAME="runneradmin" \
  -e PASSWORD="$RDP_PASS" \
  -p 8006:8006 \
  -p 3389:3389/tcp \
  -p 3389:3389/udp \
  -v ~/win10-storage:/storage \
  dockurr/windows:latest

# Download Linux bore binary
curl -sL https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-unknown-linux-musl.tar.gz | tar xz
chmod +x ./bore
RUST_LOG=info nohup ./bore local 3389 --to bore.pub > bore.log 2>&1 &

# Start Pinggy SSH TCP tunnels for RDP (3389) and Web VNC (8006)
mkdir -p ~/.ssh
[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N "" >/dev/null 2>&1
nohup ssh -p 443 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -T -R0:127.0.0.1:3389 tcp@free.pinggy.io < /dev/null > pinggy_rdp.log 2>&1 &
nohup ssh -p 443 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -T -R0:127.0.0.1:8006 free.pinggy.io < /dev/null > pinggy_vnc.log 2>&1 &

sleep 6

LOOP_COUNT=0
while true; do
  LOOP_COUNT=$((LOOP_COUNT + 1))

  BORE_URL=$(sed 's/\x1b\[[0-9;]*m//g' bore.log 2>/dev/null | tr -d '\r' | grep -oE 'bore\.pub:[0-9]+' | head -n1 || true)
  PINGGY_RDP=$(sed 's/\x1b\[[0-9;]*m//g' pinggy_rdp.log 2>/dev/null | tr -d '\r' | grep -oE 'tcp://[a-zA-Z0-9.-]+:[0-9]+' | head -n1 | sed 's|tcp://||' || true)
  PINGGY_VNC=$(sed 's/\x1b\[[0-9;]*m//g' pinggy_vnc.log 2>/dev/null | tr -d '\r' | grep -oE 'https://[a-zA-Z0-9.-]+\.pinggy\.[a-z]+' | head -n1 || true)

  # Probe real RDP X.224 handshake on 127.0.0.1:3389 (since docker-proxy opens TCP before Windows finishes booting)
  X224_OK=$(python3 -c '
import socket
s = socket.socket()
s.settimeout(2)
try:
  s.connect(("127.0.0.1", 3389))
  s.sendall(bytes.fromhex("030000130ee000000000000100080003000000"))
  d = s.recv(16)
  print("1" if len(d) >= 6 and d[0] == 3 else "0")
except Exception:
  print("0")
finally:
  s.close()
' 2>/dev/null || echo "0")

  KVM_LINE=$(docker logs --tail 2 win10-ltsc 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-180 || true)
  if [ "$X224_OK" = "1" ]; then
    RDP_READY="Windows 10 Enterprise LTSC 22H2 READY! Ket noi Windows App ngay!"
  else
    RDP_READY="Dang tai/cai Windows 10 LTSC ISO (Mo Web VNC :8006 de xem truc tiep)..."
  fi

  PRIMARY="${BORE_URL:-$PINGGY_RDP}"
  BACKUP="${PINGGY_RDP:-$BORE_URL}"

  echo "[WinCloud KVM #$LOOP_COUNT] Bore=$BORE_URL | PinggyRDP=$PINGGY_RDP | WebVNC=$PINGGY_VNC | X224=$X224_OK"

  PAYLOAD=$(PRIMARY="$PRIMARY" BACKUP="$BACKUP" PINGGY_VNC="$PINGGY_VNC" RDP_PASS="$RDP_PASS" RDP_READY="$RDP_READY" KVM_LINE="$KVM_LINE" python3 -c '
import json, os, datetime
obj = {
  "updatedAt": datetime.datetime.utcnow().isoformat() + "Z",
  "hostname": "WIN10-LTSC-KVM",
  "osCaption": "Microsoft Windows 10 Enterprise LTSC 22H2 (Real KVM)",
  "publicRdpUrl": os.environ.get("PRIMARY", ""),
  "backupRdpUrl": os.environ.get("BACKUP", ""),
  "webVncUrl": os.environ.get("PINGGY_VNC", ""),
  "username": "runneradmin",
  "password": os.environ.get("RDP_PASS", ""),
  "freeRamMb": 4096,
  "totalRamMb": 5120,
  "logs": [
    os.environ.get("RDP_READY", ""),
    "KVM: " + os.environ.get("KVM_LINE", ""),
    "Bore RDP: " + os.environ.get("PRIMARY", ""),
    "Pinggy RDP: " + os.environ.get("BACKUP", ""),
    "Web Browser VNC (:8006): " + os.environ.get("PINGGY_VNC", "")
  ]
}
print(json.dumps(obj))
')

  B64=$(echo -n "$PAYLOAD" | base64 -w 0)
  SHA=$(curl -s -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$GH_REPO/contents/state/status.json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("sha",""))' 2>/dev/null || true)

  if [ -n "$SHA" ]; then
    BODY="{\"message\":\"KVM Win10 Heartbeat\",\"content\":\"$B64\",\"sha\":\"$SHA\"}"
  else
    BODY="{\"message\":\"KVM Win10 Heartbeat\",\"content\":\"$B64\"}"
  fi
  curl -s -X PUT -H "Authorization: Bearer $GH_TOKEN" -H "Content-Type: application/json" -d "$BODY" "https://api.github.com/repos/$GH_REPO/contents/state/status.json" >/dev/null || true

  if [ "$LOOP_COUNT" -le 3 ]; then
    sleep 6
  else
    sleep 18
  fi
done
