#!/usr/bin/env bash
# Builds the Serk Finance office installers into dist/:
#   SerkFinance-<version>-Setup.exe          Windows 10/11 x64 installer (NSIS)
#   serk-finance_<debversion>_amd64.deb       Debian / Ubuntu package
#   serk-finance-<version>-linux-amd64.tar.gz Other Linux (install.sh)
#   SHA256SUMS
# Needs: Go (see go.mod), Node.js and npm, Python 3 with pip, makensis (NSIS 3), dpkg-deb.
# Third-party downloads are pinned by SHA-256 below and verified before use.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(grep -o 'ReleaseVersion = "[^"]*"' internal/platform/database/database.go | cut -d'"' -f2)
NUM=${VERSION%%-*}
VERSION4="$NUM.0"
DEBVERSION=${VERSION/-/\~}
OUT=${OUT:-dist}
CACHE=${CACHE:-.cache/installer}
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

PG_NPM_VERSION=17.10.0-beta.17
PG_LINUX_SHA256=5bad48012c3a7415c06310f632ce9a0f9da20dadb70e774e4985c2f416a4445b
PG_WINDOWS_SHA256=262161722259e884ec238d9dfb163fec84b9f474649e207238af97b7fcdf62f7
VCRT_VERSION=14.44.35112
VCRT_SHA256=32f9c706009e16ccc319d6947ce3bffe20e5192bee52b18cf48313f9e7bedfbe

mkdir -p "$OUT" "$CACHE"
verify() { echo "$2  $1" | sha256sum -c --quiet - || { echo "checksum mismatch: $1" >&2; exit 1; }; }
fetch_pg() { # os sha256 -> path of the verified npm tarball
  local file="$CACHE/embedded-postgres-$1-x64-$PG_NPM_VERSION.tgz"
  [ -f "$file" ] || (cd "$CACHE" && npm pack --silent "@embedded-postgres/$1-x64@$PG_NPM_VERSION" >/dev/null)
  verify "$file" "$2"
  echo "$file"
}

echo "== Serk Finance $VERSION"
echo "== web interface"
if [ "${SKIP_WEB_BUILD:-}" != "1" ]; then npm --prefix web ci --ignore-scripts --no-audit --no-fund >/dev/null && npm --prefix web run build >/dev/null; fi
test -f web/dist/index.html

echo "== serk-server binaries"
for target in linux/amd64 windows/amd64; do
  os=${target%/*}; arch=${target#*/}; ext=""; [ "$os" = windows ] && ext=.exe
  mkdir -p "$STAGE/$os/serk-finance"
  GOOS=$os GOARCH=$arch CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags "-s -w" -o "$STAGE/$os/serk-finance/serk-server$ext" ./cmd/serk-server
  cp -r web/dist "$STAGE/$os/serk-finance/web"
  cp deploy/installer/README-INSTALL.txt deploy/installer/LICENSE-INSTALL.txt deploy/installer/THIRD-PARTY-NOTICES.txt "$STAGE/$os/serk-finance/"
done

echo "== PostgreSQL $PG_NPM_VERSION"
for os in linux windows; do
  sha=$PG_LINUX_SHA256; [ "$os" = windows ] && sha=$PG_WINDOWS_SHA256
  tgz=$(fetch_pg "$os" "$sha")
  tmp="$STAGE/pg-$os"; mkdir -p "$tmp"; tar xzf "$tgz" -C "$tmp"
  mkdir -p "$STAGE/$os/serk-finance/pgsql"
  cp -a "$tmp/package/native/bin" "$tmp/package/native/lib" "$tmp/package/native/share" "$STAGE/$os/serk-finance/pgsql/"
  if [ "$os" = linux ]; then
    python3 - "$tmp/package/native/pg-symlinks.json" "$STAGE/linux/serk-finance/pgsql" <<'PY'
import json,os,sys
for l in json.load(open(sys.argv[1])):
    src=l["source"].replace("native/","",1); dst=l["target"].replace("native/","",1)
    path=os.path.join(sys.argv[2],dst)
    if os.path.lexists(path): os.remove(path)
    os.symlink(os.path.relpath(os.path.join(sys.argv[2],src),os.path.dirname(path)),path)
PY
  else
    # Unused GUI and test libraries shipped with the Windows build.
    rm -f "$STAGE/windows/serk-finance/pgsql/bin/"wx*.dll "$STAGE/windows/serk-finance/pgsql/bin/testplug.dll"
  fi
done

echo "== Microsoft Visual C++ runtime $VCRT_VERSION (Windows)"
whl="$CACHE/msvc_runtime-$VCRT_VERSION-cp312-cp312-win_amd64.whl"
[ -f "$whl" ] || pip download --quiet --no-deps --only-binary=:all: --platform win_amd64 --python-version 3.12 -d "$CACHE" "msvc-runtime==$VCRT_VERSION"
verify "$whl" "$VCRT_SHA256"
python3 - "$whl" "$STAGE/windows/serk-finance/pgsql/bin" <<'PY'
import sys,zipfile
z=zipfile.ZipFile(sys.argv[1])
for n in ("vcruntime140.dll","vcruntime140_1.dll","msvcp140.dll"):
    open(sys.argv[2]+"/"+n,"wb").write(z.read("msvc_runtime-14.44.35112.data/data/Scripts/"+n))
PY

echo "== Windows installer"
cp deploy/installer/windows/starting.html deploy/installer/windows/backup-now.cmd deploy/installer/windows/reset-password.cmd "$STAGE/windows/serk-finance/"
exe="$OUT/SerkFinance-$VERSION-Setup.exe"
makensis -V2 -DVERSION="$VERSION" -DVERSION4="$VERSION4" -DSRC="$STAGE/windows/serk-finance" -DOUTFILE="$(realpath -m "$exe")" deploy/installer/windows/serk-finance.nsi

echo "== Linux .tar.gz"
cp deploy/installer/linux/install.sh deploy/installer/linux/uninstall.sh deploy/installer/linux/serk-finance deploy/installer/linux/serk-finance.service "$STAGE/linux/serk-finance/"
tar -C "$STAGE/linux" --owner=0 --group=0 -czf "$OUT/serk-finance-$VERSION-linux-amd64.tar.gz" serk-finance

echo "== Debian package"
deb="$STAGE/deb"
mkdir -p "$deb/DEBIAN" "$deb/opt" "$deb/lib/systemd/system" "$deb/usr/local/bin"
cp -a "$STAGE/linux/serk-finance" "$deb/opt/serk-finance"
rm -f "$deb/opt/serk-finance/install.sh" "$deb/opt/serk-finance/uninstall.sh" "$deb/opt/serk-finance/serk-finance" "$deb/opt/serk-finance/serk-finance.service"
cp deploy/installer/linux/serk-finance.service "$deb/lib/systemd/system/"
cp deploy/installer/linux/serk-finance "$deb/usr/local/bin/"
cp deploy/installer/linux/debian/postinst deploy/installer/linux/debian/prerm deploy/installer/linux/debian/postrm "$deb/DEBIAN/"
size=$(du -sk "$deb" | cut -f1)
sed -e "s/@DEBVERSION@/$DEBVERSION/" -e "s/@SIZE@/$size/" deploy/installer/linux/debian/control.in > "$deb/DEBIAN/control"
chmod 755 "$deb/DEBIAN/postinst" "$deb/DEBIAN/prerm" "$deb/DEBIAN/postrm"
dpkg-deb --root-owner-group -Zxz --build "$deb" "$OUT/serk-finance_${DEBVERSION}_amd64.deb" >/dev/null

(cd "$OUT" && sha256sum "SerkFinance-$VERSION-Setup.exe" "serk-finance_${DEBVERSION}_amd64.deb" "serk-finance-$VERSION-linux-amd64.tar.gz" > SHA256SUMS)
ls -la "$OUT"
