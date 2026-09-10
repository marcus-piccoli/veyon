#!/usr/bin/env bash
set -Eeuo pipefail

# Reproducible native Windows build for the Veyon Fix branch.
# Run from an MSYS2 UCRT64 shell.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build-veyon-fix"
CACHE_DIR="$ROOT/.veyon-fix-cache"
ARTIFACT_DIR="$ROOT/artifacts"
VERSION="4.11.2.0"
PACKAGE_NAME="veyon-win64-$VERSION"
PACKAGE_DIR="$BUILD_DIR/$PACKAGE_NAME"
INSTALLER_NAME="veyon-$VERSION-win64-setup.exe"
INTERCEPTION_REPO="https://github.com/oblitum/Interception.git"
INTERCEPTION_COMMIT="39eecbbc46a52e0402f783b872ef62b0254a896a"
LIBVNC_PATCH="$ROOT/patches/libvncserver-mingw-unicode.patch"
LIBVNC_DIR="$ROOT/3rdparty/libvncserver"
PATCH_APPLIED_BY_SCRIPT=0

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_file() {
    [[ -f "$1" ]] || fail "Required file not found: $1"
}

cleanup() {
    local status=$?
    if [[ "$PATCH_APPLIED_BY_SCRIPT" == "1" ]]; then
        log "Restoring bundled LibVNCServer source tree"
        git -C "$LIBVNC_DIR" apply --reverse "$LIBVNC_PATCH" || true
    fi
    trap - EXIT
    exit "$status"
}
trap cleanup EXIT

[[ "${MSYSTEM:-}" == "UCRT64" ]] || fail "Run this script from the MSYS2 UCRT64 shell (current MSYSTEM=${MSYSTEM:-unset})."
[[ -f "$ROOT/CMakeLists.txt" ]] || fail "Repository root could not be located."

for cmd in git gcc g++ cmake ninja python ntldd makensis cygpath sha256sum; do
    require_command "$cmd"
done

require_file "$LIBVNC_PATCH"
require_file "$ROOT/3rdparty/ddengine/ddengine64.dll"
require_file "$ROOT/nsis/veyon.nsi.in"

log "Validating Veyon Fix source state"
grep -q 'DNS_QUERY_BYPASS_CACHE' "$ROOT/core/src/VncConnection.cpp" || fail "Fresh DNS code is missing from VncConnection.cpp"
grep -q -- '-ldnsapi' "$ROOT/core/CMakeLists.txt" || fail "dnsapi link dependency is missing"
grep -q 'CMAKE_SIZEOF_VOID_P EQUAL 8' "$ROOT/CMakeLists.txt" || fail "Win64 pointer-size detection fix is missing"
grep -q 'Wno-unused-but-set-variable' "$ROOT/plugins/platform/windows/CMakeLists.txt" || fail "Windows platform GCC compatibility flag is missing"
grep -q 'Wno-old-style-definition' "$ROOT/plugins/vncserver/ultravnc-builtin/CMakeLists.txt" || fail "UltraVNC C compatibility flag is missing"
grep -q 'Wno-error=sfinae-incomplete' "$ROOT/plugins/webapi/CMakeLists.txt" || fail "Qt/GCC WebAPI compatibility flag is missing"

log "Initializing Git submodules"
git -C "$ROOT" submodule update --init --recursive

log "Applying bundled LibVNCServer Unicode compatibility patch"
if git -C "$LIBVNC_DIR" apply --reverse --check "$LIBVNC_PATCH" >/dev/null 2>&1; then
    echo "LibVNCServer patch is already applied; leaving it unchanged."
elif [[ -n "$(git -C "$LIBVNC_DIR" status --porcelain)" ]]; then
    fail "3rdparty/libvncserver has unrelated local changes. Clean the submodule before building."
elif git -C "$LIBVNC_DIR" apply --check "$LIBVNC_PATCH" >/dev/null 2>&1; then
    git -C "$LIBVNC_DIR" apply "$LIBVNC_PATCH"
    PATCH_APPLIED_BY_SCRIPT=1
else
    fail "LibVNCServer compatibility patch does not apply to the checked-out submodule revision."
fi

log "Preparing pinned Interception user-mode library"
mkdir -p "$CACHE_DIR"
INTERCEPTION_SRC="$CACHE_DIR/Interception"
if [[ ! -d "$INTERCEPTION_SRC/.git" ]]; then
    rm -rf "$INTERCEPTION_SRC"
    git clone --no-checkout "$INTERCEPTION_REPO" "$INTERCEPTION_SRC"
fi

git -C "$INTERCEPTION_SRC" fetch --depth 1 origin "$INTERCEPTION_COMMIT"
git -C "$INTERCEPTION_SRC" checkout --detach --force "$INTERCEPTION_COMMIT"
git -C "$INTERCEPTION_SRC" clean -fdx

INTERCEPTION_OUT="$CACHE_DIR/interception-build"
rm -rf "$INTERCEPTION_OUT"
mkdir -p "$INTERCEPTION_OUT"

gcc -shared \
    -DINTERCEPTION_EXPORT \
    -O2 \
    "$INTERCEPTION_SRC/library/interception.c" \
    -o "$INTERCEPTION_OUT/interception.dll" \
    -Wl,--out-implib,"$INTERCEPTION_OUT/libinterception.dll.a"

install -m 0644 "$INTERCEPTION_SRC/library/interception.h" /ucrt64/include/interception.h
install -m 0644 "$INTERCEPTION_OUT/libinterception.dll.a" /ucrt64/lib/libinterception.dll.a
install -m 0755 "$INTERCEPTION_OUT/interception.dll" /ucrt64/bin/interception.dll

log "Checking required Qt/UCRT runtime files"
for file in \
    /ucrt64/share/qt6/plugins/platforms/qwindows.dll \
    /ucrt64/share/qt6/plugins/imageformats/qjpeg.dll \
    /ucrt64/share/qt6/plugins/tls/qopensslbackend.dll \
    /ucrt64/share/qt6/plugins/crypto/libqca-ossl.dll; do
    require_file "$file"
done

log "Configuring a clean CMake/Ninja build"
rm -rf "$BUILD_DIR"
cmake -S "$ROOT" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DWITH_QT6=ON \
    -DWITH_BUNDLED_LIBVNC=ON \
    -DWITH_TESTS=OFF \
    -DWITH_TRANSLATIONS=OFF

log "Building Veyon Fix"
cmake --build "$BUILD_DIR" --parallel

log "Creating redistributable package tree"
mkdir -p \
    "$PACKAGE_DIR/plugins" \
    "$PACKAGE_DIR/translations" \
    "$PACKAGE_DIR/crypto" \
    "$PACKAGE_DIR/imageformats" \
    "$PACKAGE_DIR/platforms" \
    "$PACKAGE_DIR/styles" \
    "$PACKAGE_DIR/tls" \
    "$PACKAGE_DIR/interception"

for exe in \
    cli/veyon-cli.exe \
    cli/veyon-wcli.exe \
    configurator/veyon-configurator.exe \
    master/veyon-master.exe \
    server/veyon-server.exe \
    service/veyon-service.exe \
    worker/veyon-worker.exe; do
    require_file "$BUILD_DIR/$exe"
    cp -v "$BUILD_DIR/$exe" "$PACKAGE_DIR/"
done

require_file "$BUILD_DIR/core/veyon-core.dll"
cp -v "$BUILD_DIR/core/veyon-core.dll" "$PACKAGE_DIR/"

find "$BUILD_DIR/plugins" -type f -iname '*.dll' -exec cp -v '{}' "$PACKAGE_DIR/plugins/" ';'

find "$PACKAGE_DIR/plugins" -maxdepth 1 -type f -iname 'lib*.dll' -exec mv -v '{}' "$PACKAGE_DIR/" ';' || true
if [[ -f "$PACKAGE_DIR/plugins/vnchooks.dll" ]]; then
    mv -v "$PACKAGE_DIR/plugins/vnchooks.dll" "$PACKAGE_DIR/"
fi

cp -v "$ROOT/3rdparty/ddengine/ddengine64.dll" "$PACKAGE_DIR/"
cp -v "$ROOT/3rdparty/interception/"* "$PACKAGE_DIR/interception/"
cp -v /ucrt64/bin/interception.dll "$PACKAGE_DIR/"

cp -v /ucrt64/share/qt6/plugins/platforms/qwindows.dll "$PACKAGE_DIR/platforms/"
cp -v /ucrt64/share/qt6/plugins/imageformats/qjpeg.dll "$PACKAGE_DIR/imageformats/"
cp -v /ucrt64/share/qt6/plugins/tls/qopensslbackend.dll "$PACKAGE_DIR/tls/"
cp -v /ucrt64/share/qt6/plugins/crypto/libqca-ossl.dll "$PACKAGE_DIR/crypto/"
if compgen -G '/ucrt64/share/qt6/plugins/styles/*.dll' >/dev/null; then
    cp -v /ucrt64/share/qt6/plugins/styles/*.dll "$PACKAGE_DIR/styles/"
fi

log "Collecting recursive UCRT64 DLL dependencies"
DEPS_FILE="$CACHE_DIR/ucrt64-runtime-deps.txt"
: > "$DEPS_FILE"
while IFS= read -r -d '' binary; do
    ntldd -R "$binary" 2>/dev/null || true
done < <(find "$PACKAGE_DIR" -type f \( -iname '*.exe' -o -iname '*.dll' \) -print0) \
    | sed -n 's/.*=> \(.*\.dll\) (0x.*/\1/p' \
    | sort -fu > "$DEPS_FILE"

while IFS= read -r winpath; do
    [[ -n "$winpath" ]] || continue
    unixpath="$(cygpath -u "$winpath" 2>/dev/null || true)"
    case "$unixpath" in
        /ucrt64/bin/*.dll)
            [[ -f "$unixpath" ]] && cp -uv "$unixpath" "$PACKAGE_DIR/"
            ;;
    esac
done < "$DEPS_FILE"

log "Adding license, README and NSIS resources"
cp -v "$ROOT/COPYING" "$PACKAGE_DIR/COPYING"
cp -v "$ROOT/COPYING" "$PACKAGE_DIR/LICENSE.TXT"
cp -v "$ROOT/README.md" "$PACKAGE_DIR/README.TXT"
cp -a "$ROOT/nsis" "$PACKAGE_DIR/nsis"
require_file "$BUILD_DIR/nsis/veyon.nsi"
cp -v "$BUILD_DIR/nsis/veyon.nsi" "$PACKAGE_DIR/veyon.nsi"

log "Making NSIS compile-time input paths independent of the current directory"
python - "$PACKAGE_DIR/veyon.nsi" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

if not s.startswith('!cd "${__FILEDIR__}"'):
    s = '!cd "${__FILEDIR__}"\n\n' + s

s = s.replace('!define LICENSE_TXT "COPYING"', r'!define LICENSE_TXT "${__FILEDIR__}\COPYING"')
s = s.replace('OutFile "${INSTALLER_NAME}"', r'OutFile "${__FILEDIR__}\${INSTALLER_NAME}"')

resource_replacements = {
    '"nsis/welcome-page.bmp"': r'"${__FILEDIR__}\nsis\welcome-page.bmp"',
    '"nsis/header.bmp"': r'"${__FILEDIR__}\nsis\header.bmp"',
    '"nsis/installer.ico"': r'"${__FILEDIR__}\nsis\installer.ico"',
    '"nsis/uninstaller.ico"': r'"${__FILEDIR__}\nsis\uninstaller.ico"',
}
for old, new in resource_replacements.items():
    s = s.replace(old, new)

lines = []
for line in s.splitlines():
    stripped = line.lstrip()
    if stripped.startswith('File '):
        if 'translations/*.qm' in line or r'translations\*.qm' in line:
            if '/nonfatal' not in line:
                line = line.replace('File ', 'File /nonfatal ', 1)
        if 'styles/*.dll' in line or r'styles\*.dll' in line:
            if '/nonfatal' not in line:
                line = line.replace('File ', 'File /nonfatal ', 1)

        match = re.search(r'"([^"]+)"', line)
        if match:
            path = match.group(1)
            if '${__FILEDIR__}' not in path and not path.startswith('$'):
                absolute = '${__FILEDIR__}\\' + path.replace('/', '\\')
                line = line[:match.start(1)] + absolute + line[match.end(1):]
    lines.append(line)

p.write_text('\n'.join(lines) + '\n', encoding="utf-8")
PY

log "Validating package contents"
python - "$PACKAGE_DIR" <<'PY'
from pathlib import Path
import glob
import sys

root = Path(sys.argv[1])
required = [
    "veyon-server.exe",
    "veyon-service.exe",
    "veyon-configurator.exe",
    "veyon-cli.exe",
    "veyon-wcli.exe",
    "veyon-worker.exe",
    "veyon-master.exe",
    "veyon-core.dll",
    "COPYING",
    "LICENSE.TXT",
    "README.TXT",
    "plugins/*.dll",
    "crypto/*.dll",
    "imageformats/qjpeg.dll",
    "platforms/qwindows.dll",
    "tls/qopensslbackend.dll",
    "interception/*",
    "nsis/welcome-page.bmp",
    "nsis/header.bmp",
    "nsis/installer.ico",
    "nsis/uninstaller.ico",
    "veyon.nsi",
]
missing = []
for pattern in required:
    matches = glob.glob(str(root / pattern))
    if not matches:
        missing.append(pattern)
if missing:
    print("Package validation failed; missing:")
    for item in missing:
        print(f"  - {item}")
    raise SystemExit(1)
print(f"Package validation passed: {root}")
PY

log "Generating NSIS installer"
(
    cd "$PACKAGE_DIR"
    makensis veyon.nsi
)

require_file "$PACKAGE_DIR/$INSTALLER_NAME"
mkdir -p "$ARTIFACT_DIR"
cp -v "$PACKAGE_DIR/$INSTALLER_NAME" "$ARTIFACT_DIR/$INSTALLER_NAME"
sha256sum "$ARTIFACT_DIR/$INSTALLER_NAME" > "$ARTIFACT_DIR/$INSTALLER_NAME.sha256"

log "Build completed successfully"
echo "Installer: $ARTIFACT_DIR/$INSTALLER_NAME"
echo "SHA256:   $ARTIFACT_DIR/$INSTALLER_NAME.sha256"
