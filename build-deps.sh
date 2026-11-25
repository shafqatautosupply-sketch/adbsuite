#!/bin/sh
# Builds OpenSSL 1.1.1 (TLS 1.3 + exporter, required for ADB pairing) for iOS 6 armv7.
# Usage: SDK=/path/to/iPhoneOS6.1.sdk sh build-deps.sh openssl-1.1.1w.tar.gz
# (downloads it automatically if missing)
set -e
SDK=${SDK:-$THEOS/sdks/iPhoneOS6.1.sdk}
PREFIX=${PREFIX:-$HOME/ios6-openssl}
TAR=${1:-openssl-1.1.1w.tar.gz}
if [ ! -f "$TAR" ]; then
  echo "Downloading $TAR ..."
  URLS="https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz https://www.openssl.org/source/openssl-1.1.1w.tar.gz"
  for U in $URLS; do
    [ -s "$TAR" ] && break
    # iOS 6 curl/wget often can't do modern TLS, so try python3 (own OpenSSL) first
    python3 -c "import sys,urllib.request as u; open(sys.argv[2],'wb').write(u.urlopen(sys.argv[1]).read())" "$U" "$TAR" 2>/dev/null || \
      curl -fsSL -o "$TAR" "$U" 2>/dev/null || wget -q -O "$TAR" "$U" 2>/dev/null || rm -f "$TAR"
  done
  [ -s "$TAR" ] || { echo "Download failed. Fetch openssl-1.1.1w.tar.gz elsewhere and copy it here."; exit 1; }
fi
tar xzf "$TAR"; cd "$(basename "$TAR" .tar.gz)"
# Some on-device toolchains ship an `ar` that shells out to <triple>-ranlib, which is missing.
RL=/usr/bin/armv7-apple-darwin11-ranlib
if [ ! -e "$RL" ]; then
  REAL=$(command -v ranlib || ls /usr/bin/*ranlib* 2>/dev/null | head -1)
  if [ -n "$REAL" ]; then ln -s "$REAL" "$RL" && echo "linked $RL -> $REAL"
  else echo "no ranlib found: install 'cctools'/'odcctools' (apt-get install cctools) and rerun"; exit 1; fi
fi
export CC="clang -arch armv7 -isysroot $SDK -miphoneos-version-min=6.0"
./Configure BSD-generic32 no-shared no-asm no-async no-dso no-engine no-threads no-tests no-comp \
    no-ssl3 no-hw no-unit-test -DL_ENDIAN --prefix="$PREFIX" --openssldir="$PREFIX/ssl"
make -j2 build_libs
make install_dev
echo "OpenSSL installed in $PREFIX"
