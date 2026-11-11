#!/usr/bin/env bash
# Assemble everything an offline Ubuntu host needs into ONE archive.
#
#   scripts/make-bundle.sh <amd64|arm64> <release> <images-dir> <out-dir> [docker-debs-dir]
#
# Result: <out-dir>/buzz-offline-<arch>-<release>.tar.gz containing
#
#   buzz-offline-<arch>-<release>/
#     QUICKSTART.md          step-by-step install (no internet needed)
#     offline/               compose, scripts, README, certs/install-ca.bat
#     offline/images/        the `docker save` tarballs (incl. caddy) + checksums
#     docker-debs/           optional: Docker Engine .debs + install.sh (amd64)
#
# offline/certs/ is NOT copied: it holds the server's private CA key. Only the
# .bat installers and certs/README.md ship; make-ca.sh re-creates the rest.
#
# The operator extracts it and runs `offline/scripts/install.sh` — the archive
# already puts the image tarballs where install.sh looks for them.
set -euo pipefail

ARCH="${1:?usage: make-bundle.sh <amd64|arm64> <release> <images-dir> <out-dir> [docker-debs-dir]}"
RELEASE="${2:?missing release}"
IMAGES_DIR="${3:?missing images dir}"
OUT_DIR="${4:?missing out dir}"
DEBS_DIR="${5:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$(cd "$HERE/.." && pwd)"

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$IMAGES_DIR/images-${ARCH}.txt" ] || die "no images-${ARCH}.txt in $IMAGES_DIR (run package-images.sh first)"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# The release name upstream already starts with "offline-"; do not double it.
NAME="buzz-offline-${ARCH}-${RELEASE#offline-}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/$NAME"
mkdir -p "$ROOT/offline/images"

say "copying the installing layer"
tar -cf - -C "$(dirname "$OFFLINE_DIR")" \
  --exclude='./offline/.env' --exclude='./offline/.env.*' \
  --exclude='./offline/images' --exclude='./offline/dist' \
  --exclude='./offline/backups' --exclude='./offline/certs' \
  --exclude='__pycache__' --exclude='*.pyc' \
  "$(basename "$OFFLINE_DIR")" | tar -xf - -C "$ROOT"

# Re-add only the public part of certs/ (the .bat installers + README); the CA
# key and leaf stay on the server and are generated there by make-ca.sh.
mkdir -p "$ROOT/offline/certs"
cp "$OFFLINE_DIR/certs/install-ca.bat" "$ROOT/offline/certs/" 2>/dev/null || true
cp "$OFFLINE_DIR/certs/uninstall-ca.bat" "$ROOT/offline/certs/" 2>/dev/null || true
cp "$OFFLINE_DIR/certs/README.md" "$ROOT/offline/certs/" 2>/dev/null || true

say "copying images"
cp "$IMAGES_DIR"/*-linux-"${ARCH}".tar.gz "$ROOT/offline/images/"
cp "$IMAGES_DIR/images-${ARCH}.txt" "$IMAGES_DIR/images-${ARCH}.json" "$ROOT/offline/images/"

# The sums file also covers the installing-layer tarball that package-images.sh
# writes next to the images. That file is not inside this archive (the archive
# IS the layer), and `sha256sum -c` fails on a missing file — which install.sh
# runs under `set -e` — so keep only the lines whose file is actually here.
while read -r sum file; do
  [ -n "${file:-}" ] || continue
  if [ -f "$ROOT/offline/images/${file#\*}" ]; then
    printf '%s  %s\n' "$sum" "${file#\*}"
  fi
done <"$IMAGES_DIR/SHA256SUMS-${ARCH}" >"$ROOT/offline/images/SHA256SUMS-${ARCH}"

if [ -n "$DEBS_DIR" ] && [ -d "$DEBS_DIR" ]; then
  say "copying Docker Engine packages for offline install"
  mkdir -p "$ROOT/docker-debs"
  cp "$DEBS_DIR"/*.deb "$ROOT/docker-debs/"
  cp "$OFFLINE_DIR/scripts/install-docker-offline.sh" "$ROOT/docker-debs/install.sh"
  chmod +x "$ROOT/docker-debs/install.sh"
fi

say "writing QUICKSTART.md"
{
  cat <<EOF
# Buzz 오프라인 릴레이 — 설치 안내 (${ARCH}, ${RELEASE})

인터넷이 없는 Ubuntu 24.04 (${ARCH}) 서버에 이 압축파일 하나만 옮기면 됩니다.
안에 들어 있는 것: 이미지 6개(릴레이·postgres·redis·silo·mc·caddy), compose/설치 스크립트,
인증서 설치용 certs/install-ca.bat, (amd64면) Docker Engine 패키지 + dockerd 가 쓰는 iptables/nftables 패키지.

## 1. 압축 풀기

\`\`\`bash
tar -xzf ${NAME}.tar.gz
cd ${NAME}
\`\`\`

## 2. Docker 설치 (이미 있으면 건너뛰기)

\`\`\`bash
docker version            # 이미 설치돼 있으면 3번으로
cd docker-debs && sudo ./install.sh && cd ..
\`\`\`

\`install.sh\` 는 최소 설치 Ubuntu 24.04 에 없는 iptables/nftables 와 그 라이브러리까지
같이 설치합니다(이미 있으면 건너뜀). 그래도 "의존 패키지가 없다"고 나오면, 인터넷 되는 PC에서
같은 Ubuntu 24.04 로 \`apt-get download <패키지명>\` 을 받아 이 폴더에 넣고 다시 실행하세요.

## 3. 설치 (TLS 기본 ON)

\`\`\`bash
cd offline
sudo ./scripts/install.sh --host <서버IP> --tls-port 40009
\`\`\`

- \`--host\` 에 다른 PC가 접속할 주소를 넣습니다 (예: 203.0.113.10). 인증서 SAN 은 이 주소로 만들어집니다.
- \`--tls-port\` 는 caddy 가 여는 wss 포트입니다 (기본 40009). 앱에는 \`wss://IP:40009\` 를 넣습니다.
- 설치 시 사설 CA 와 서버 인증서가 \`offline/certs/\` 에 자동 발급됩니다 (\`scripts/make-ca.sh\`).
- 비밀키·DB 비밀번호는 자동 생성되고 \`offline/.env\` 에 저장됩니다. **이 파일과 \`certs/ca.key\` 를 백업하세요.**
- 이미지 6개는 이미 \`offline/images/\` 에 들어 있어 따로 옮길 것이 없습니다. **풀(pull) 하지 않습니다.**
- 예전처럼 평문 HTTP(ws://)로 쓰려면: \`sudo ./scripts/install.sh --host <서버IP> --no-tls --port 80\`

## 4. 확인

\`\`\`bash
sudo ./scripts/verify.sh   # 헬스/웹/웹소켓/TLS 인증서/외부 접속/인터넷 차단 검사
\`\`\`

\`relay reached 1.1.1.1:443\` 만 red 로 뜨면 이 서버에 인터넷 경로가 있는 것입니다.
\`sudo ./scripts/lockdown.sh apply\` 로 막으면 통과합니다. (폐쇄망이면 자동 통과)

## 5. 클라이언트 설정 (Windows PC 마다 1회)

1. 서버의 \`offline/certs/ca.crt\` 와 \`offline/certs/install-ca.bat\` 두 파일을 PC로 복사합니다.
2. \`install-ca.bat\` 를 **우클릭 → 관리자 권한으로 실행** (한 번만; 내부적으로 `certutil -addstore -f Root ca.crt` 를 실행합니다).
3. Buzz 데스크탑 앱 → 커뮤니티 추가 → \`wss://<서버IP>:40009\` 입력.
   (데스크탑 1.0.0은 wss:// 또는 https:// 만 받습니다. ws:// 는 앱에서 거부됩니다.)

브라우저 확인용: \`https://<서버IP>:40009/\` (서버 정보 JSON), 초대 링크는 \`https://<서버IP>:40009/invite/<코드>\`.
인증서가 신뢰 안 되면 브라우저가 자체 경고를 표시합니다 — 위 5-1~5-2 단계를 깜빡했는지 확인하세요.

## 6. 새 릴리즈 업그레이드 (한 번에)

\`\`\`bash
# 새 릴리즈 압축파일과 .sha256 을 이 서버로 옮긴 뒤:
sudo <기존설치경로>/offline/scripts/upgrade.sh --bundle buzz-offline-${ARCH}-<새릴리즈>.tar.gz
\`\`\`

기존 \`.env\`(릴레이 identity·비밀키)와 볼륨은 그대로 유지되고 이미지 태그만 새 릴리즈로 바뀝니다.

## 자주 쓰는 명령

\`\`\`bash
cd offline
sudo ./scripts/set-address.sh --host <새IP> --port 40009   # 주소/포트 변경 (데이터 유지, 인증서 재발급)
sudo ./scripts/make-ca.sh --host <서버IP> --port 40009     # 인증서만 다시 발급
sudo ./scripts/backup.sh                                   # DB + git 볼륨 + .env + certs 백업
sudo docker compose logs -f relay                          # 로그
sudo docker compose down                                   # 중지
\`\`\`

전체 문서: \`offline/README.md\` · 인증서: \`offline/certs/README.md\`
EOF
} >"$ROOT/QUICKSTART.md"

say "compressing ${NAME}.tar.gz"
tar -czf "$OUT_DIR/${NAME}.tar.gz" -C "$STAGE" "$NAME"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else openssl dgst -sha256 -r "$1" | cut -d' ' -f1
  fi
}
sum=$(sha256_of "$OUT_DIR/${NAME}.tar.gz")
printf '%s  %s\n' "$sum" "${NAME}.tar.gz" >"$OUT_DIR/${NAME}.tar.gz.sha256"

say "done"
ls -lh "$OUT_DIR/${NAME}.tar.gz" "$OUT_DIR/${NAME}.tar.gz.sha256" | sed 's/^/  /'
echo "  sha256: $sum"
