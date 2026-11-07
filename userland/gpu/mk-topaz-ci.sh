#!/bin/bash
# libtopaz-gl.dylib (OpenGL ES behind EAGLContext: eagl.c + gl_osmesa.c over Mesa's OSMesa), libtopaz-inject.dylib
# and the backboardd wrapper, built with Xcode's clang. Result: build-topaz/out/
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(pwd)/build-topaz/out
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
FL="-target arm64-apple-ios16.0 -isysroot $SDK -O2 -fno-objc-arc -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers"
FW="-framework CoreFoundation -framework IOKit -framework IOSurface"
IOKIT_PRIV=
[ -d "$SDK/System/Library/PrivateFrameworks/IOSurface.framework" ] && IOKIT_PRIV="-iframework $SDK/System/Library/PrivateFrameworks"
mkdir -p stub
"$CC" -target arm64-apple-ios16.0 -isysroot "$SDK" -dynamiclib -install_name /topaz/lib/libOSMesa.8.dylib \
	-o stub/libOSMesa.8.dylib "$HERE/stub_osmesa.c"
"$CC" $FL $IOKIT_PRIV -dynamiclib -install_name /topaz/lib/libtopaz-gl.dylib -I"$HERE" \
	-o "$OUT/libtopaz-gl.dylib" "$HERE/eagl.c" "$HERE/gl_osmesa.c" stub/libOSMesa.8.dylib $FW -lobjc
"$CC" $FL $IOKIT_PRIV -dynamiclib -install_name /topaz/lib/libtopaz-inject.dylib -I"$HERE" \
	-o "$OUT/libtopaz-inject.dylib" "$HERE/topaz_inject.c" $FW -lobjc
"$CC" $FL -o "$OUT/backboardd-wrap" "$HERE/bbd_wrap.c"
for f in libtopaz-gl.dylib libtopaz-inject.dylib backboardd-wrap; do codesign -f -s - "$OUT/$f"; done
nm -gU "$OUT/libtopaz-gl.dylib" | grep redwood_gl_function || echo "NOTE: redwood_gl_function_* not exported"
otool -L "$OUT/libtopaz-gl.dylib"
ls -l "$OUT"
