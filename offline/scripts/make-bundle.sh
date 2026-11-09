#!/usr/bin/env bash
# Assemble everything an offline Ubuntu host needs into ONE archive.
#
#   scripts/make-bundle.sh <amd64|arm64> <release> <images-dir> <out-dir> [docker-debs-dir]
#
# Result: <out-dir>/buzz-offline-<arch>-<release>.tar.gz containing
#
#   buzz-offline-<arch>-<release>/
#     QUICKSTART.md          step-by-step install (no internet needed)
#     offline/               compose, scripts, README
#     offline/images/        the five `docker save` tarballs + checksums
#     docker-debs/           optional: Docker Engine .debs + install.sh (amd64)
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
  --exclude='./offline/backups' --exclude='__pycache__' --exclude='*.pyc' \
  "$(basename "$OFFLINE_DIR")" | tar -xf - -C "$ROOT"

say "copying images"
cp "$IMAGES_DIR"/*-linux-"${ARCH}".tar.gz "$ROOT/offline/images/"
cp "$IMAGES_DIR/images-${ARCH}.txt" "$IMAGES_DIR/images-${ARCH}.json" "$ROOT/offline/images/"
cp "$IMAGES_DIR/SHA256SUMS-${ARCH}" "$ROOT/offline/images/"

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
안에 들어 있는 것: 릴레이 이미지 5개, compose/설치 스크립트, (해당하면) Docker 설치 패키지.

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

의존 패키지가 없다고 나오면, 인터넷 되는 PC에서 같은 Ubuntu 24.04로
\`apt-get download iptables nftables\` 를 받아 이 폴더에 넣고 다시 실행하세요.

## 3. 설치

\`\`\`bash
cd offline
sudo ./scripts/install.sh --host <서버IP> --port 80
\`\`\`

- \`--host\` 에 다른 PC가 접속할 주소를 넣습니다 (예: 166.103.175.321).
- 포트를 80이 아닌 값으로 쓰려면 \`--port 5000\` 처럼 주고, 앱에는 \`ws://IP:5000\` 을 넣습니다.
- 비밀키·DB 비밀번호는 자동 생성되고 \`offline/.env\` 에 저장됩니다. **이 파일을 백업하세요.**
- 이미지 5개는 이미 \`offline/images/\` 에 들어 있어 따로 옮길 것이 없습니다.
- 포트 80을 쓰려면 root 가 필요하므로 \`sudo\` 로 실행합니다. 이후 명령도 같은 이유로 \`sudo\` 를 붙이세요.

## 4. 확인

\`\`\`bash
./scripts/verify.sh        # 헬스/웹/웹소켓/외부 접속/인터넷 차단 검사
\`\`\`

맨 아래 \`relay reached 1.1.1.1:443\` 만 red 로 뜨면, 이 서버에 인터넷 경로가 있다는 뜻입니다.
\`sudo ./scripts/lockdown.sh apply\` 로 막으면 통과합니다. (폐쇄망이면 자동 통과)

## 5. 클라이언트 접속

다른 PC의 Buzz 데스크탑 앱 → 커뮤니티 추가 → 주소에 \`ws://<서버IP>\` (포트가 80이 아니면 \`:포트\` 까지).
브라우저 확인용: \`http://<서버IP>/\` (서버 정보 JSON), 초대 링크는 \`http://<서버IP>/invite/<코드>\`.

## 자주 쓰는 명령

\`\`\`bash
cd offline
sudo ./scripts/install.sh --host <새IP> --port <새포트>   # 주소 변경 (데이터 유지)
./scripts/backup.sh                                      # DB + git 볼륨 백업
docker compose logs -f relay                             # 로그
docker compose down                                      # 중지
\`\`\`

전체 문서: \`offline/README.md\`
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
