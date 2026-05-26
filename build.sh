#!/usr/bin/env bash

set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.1}"
LIBASS_VERSION="${LIBASS_VERSION:-0.17.4}"
FREETYPE_VERSION="${FREETYPE_VERSION:-2.14.3}"
FRIBIDI_VERSION="${FRIBIDI_VERSION:-1.0.16}"
HARFBUZZ_VERSION="${HARFBUZZ_VERSION:-14.2.0}"

DEPLOYMENT_TARGET_IOS="${DEPLOYMENT_TARGET_IOS:-15.0}"
DEPLOYMENT_TARGET_TVOS="${DEPLOYMENT_TARGET_TVOS:-17.0}"
DEPLOYMENT_TARGET_MACOS="${DEPLOYMENT_TARGET_MACOS:-10.15}"
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
SOURCES_DIR="$BUILD_DIR/sources"
WORK_DIR="$BUILD_DIR/work"
INSTALL_DIR="$BUILD_DIR/install"
PRODUCTS_DIR="$BUILD_DIR/Frameworks"

PLATFORMS=("MacOSX" "iPhoneOS" "iPhoneSimulator" "AppleTVOS" "AppleTVSimulator")
FFMPEG_LIBS=("libavcodec" "libavfilter" "libavformat" "libavutil" "libswresample" "libswscale" "libavdevice")

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required tool '$1'" >&2
    echo "install prerequisites with: brew install meson ninja pkg-config yasm nasm" >&2
    exit 1
  fi
}

require_tool curl
require_tool git
require_tool tar
require_tool make
require_tool xcodebuild
require_tool xcrun
require_tool lipo
require_tool libtool
require_tool autoconf
require_tool aclocal
require_tool glibtoolize
require_tool pkg-config
require_tool meson
require_tool ninja

download_source() {
  local name="$1"
  local version="$2"
  local url="$3"
  local source_dir="$SOURCES_DIR/$name-$version"
  local archive="$SOURCES_DIR/$name-$version.tar.xz"

  if [ -d "$source_dir" ]; then
    return
  fi

  mkdir -p "$SOURCES_DIR"
  echo "downloading $name $version"
  curl -L --fail "$url" -o "$archive"
  mkdir -p "$source_dir"
  tar -xJf "$archive" -C "$source_dir" --strip-components=1
}

download_freetype_source() {
  local version="$1"
  local source_dir="$SOURCES_DIR/freetype-$version"
  local tag="VER-${version//./-}"
  local repo="https://github.com/freetype/freetype.git"

  if [ -d "$source_dir" ] && [ ! -d "$source_dir/.git" ]; then
    rm -rf "$source_dir"
  fi

  if [ ! -d "$source_dir" ]; then
    mkdir -p "$SOURCES_DIR"
    echo "cloning freetype $version"
    git clone --depth 1 --branch "$tag" "$repo" "$source_dir"
  fi

  if [ ! -x "$source_dir/builds/unix/configure" ]; then
    pushd "$source_dir" >/dev/null
    ./autogen.sh
    popd >/dev/null
  fi
}

download_sources() {
  download_source "ffmpeg" "$FFMPEG_VERSION" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  download_source "libass" "$LIBASS_VERSION" "https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.xz"
  download_freetype_source "$FREETYPE_VERSION"
  download_source "fribidi" "$FRIBIDI_VERSION" "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz"
  download_source "harfbuzz" "$HARFBUZZ_VERSION" "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz"
}

sdk_name() {
  case "$1" in
    MacOSX) echo "macosx" ;;
    iPhoneOS) echo "iphoneos" ;;
    iPhoneSimulator) echo "iphonesimulator" ;;
    AppleTVOS) echo "appletvos" ;;
    AppleTVSimulator) echo "appletvsimulator" ;;
    *) echo "error: unsupported platform $1" >&2; exit 1 ;;
  esac
}

archs_for_platform() {
  case "$1" in
    MacOSX|iPhoneSimulator|AppleTVSimulator) echo "arm64 x86_64" ;;
    iPhoneOS|AppleTVOS) echo "arm64" ;;
    *) echo "error: unsupported platform $1" >&2; exit 1 ;;
  esac
}

deployment_flag() {
  case "$1" in
    MacOSX) echo "-mmacosx-version-min=$DEPLOYMENT_TARGET_MACOS" ;;
    iPhoneOS) echo "-miphoneos-version-min=$DEPLOYMENT_TARGET_IOS" ;;
    iPhoneSimulator) echo "-mios-simulator-version-min=$DEPLOYMENT_TARGET_IOS" ;;
    AppleTVOS) echo "-mtvos-version-min=$DEPLOYMENT_TARGET_TVOS" ;;
    AppleTVSimulator) echo "-mtvos-simulator-version-min=$DEPLOYMENT_TARGET_TVOS" ;;
    *) echo "error: unsupported platform $1" >&2; exit 1 ;;
  esac
}

host_for_arch() {
  case "$1" in
    arm64) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) echo "error: unsupported arch $1" >&2; exit 1 ;;
  esac
}

meson_cpu_family() {
  case "$1" in
    arm64) echo "aarch64" ;;
    x86_64) echo "x86_64" ;;
    *) echo "error: unsupported arch $1" >&2; exit 1 ;;
  esac
}

write_meson_cross_file() {
  local platform="$1"
  local arch="$2"
  local prefix="$3"
  local file="$4"
  local sdk
  local sdkroot
  local min_flag
  local cpu_family

  sdk="$(sdk_name "$platform")"
  sdkroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  min_flag="$(deployment_flag "$platform")"
  cpu_family="$(meson_cpu_family "$arch")"

  cat >"$file" <<EOF
[binaries]
c = ['xcrun', '--sdk', '$sdk', 'clang']
cpp = ['xcrun', '--sdk', '$sdk', 'clang++']
ar = ['xcrun', '--sdk', '$sdk', 'ar']
strip = ['xcrun', '--sdk', '$sdk', 'strip']
pkgconfig = 'pkg-config'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sdkroot', '-I$prefix/include', '-I$prefix/include/freetype2']
cpp_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sdkroot', '-I$prefix/include', '-I$prefix/include/freetype2']
c_link_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sdkroot', '-L$prefix/lib']
cpp_link_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sdkroot', '-L$prefix/lib']
pkg_config_path = '$prefix/lib/pkgconfig'

[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$arch'
endian = 'little'
EOF
}

build_freetype() {
  local platform="$1"
  local arch="$2"
  local prefix="$3"
  local source="$SOURCES_DIR/freetype-$FREETYPE_VERSION"
  local build="$WORK_DIR/$platform-$arch/freetype"
  local sdk
  local sdkroot
  local cflags
  local cc

  sdk="$(sdk_name "$platform")"
  sdkroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cflags="-arch $arch $(deployment_flag "$platform") -isysroot $sdkroot"
  cc="xcrun --sdk $sdk clang"

  rm -rf "$build"
  mkdir -p "$build"
  pushd "$build" >/dev/null
  env \
    CC="$cc" \
    AR="$(xcrun --sdk "$sdk" --find ar)" \
    RANLIB="$(xcrun --sdk "$sdk" --find ranlib)" \
    CFLAGS="$cflags" \
    LDFLAGS="$cflags" \
    "$source/configure" \
      --host="$(host_for_arch "$arch")" \
      --prefix="$prefix" \
      --disable-shared \
      --enable-static \
      --without-bzip2 \
      --without-brotli \
      --without-harfbuzz \
      --without-png \
      --without-zlib
  make -j"$JOBS"
  make install
  popd >/dev/null
}

build_meson_project() {
  local name="$1"
  local platform="$2"
  local arch="$3"
  local prefix="$4"
  local source="$5"
  shift 5

  local build="$WORK_DIR/$platform-$arch/$name"
  local cross_file="$WORK_DIR/$platform-$arch/$name-cross.ini"
  local sdk
  local sdkroot
  local common_flags

  sdk="$(sdk_name "$platform")"
  sdkroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  common_flags="-arch $arch $(deployment_flag "$platform") -isysroot $sdkroot -I$prefix/include -I$prefix/include/freetype2 -L$prefix/lib"

  rm -rf "$build"
  mkdir -p "$(dirname "$cross_file")"
  write_meson_cross_file "$platform" "$arch" "$prefix" "$cross_file"

  env \
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" \
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
    CFLAGS="$common_flags" \
    LDFLAGS="$common_flags" \
    meson setup "$build" "$source" \
      --cross-file "$cross_file" \
      --prefix "$prefix" \
      --libdir lib \
      --buildtype release \
      --default-library static \
      "$@"

  ninja -C "$build"
  ninja -C "$build" install
}

build_fribidi() {
  build_meson_project \
    "fribidi" "$1" "$2" "$3" "$SOURCES_DIR/fribidi-$FRIBIDI_VERSION" \
    -Ddeprecated=false \
    -Ddocs=false \
    -Dtests=false \
    -Dbin=false
}

build_harfbuzz() {
  build_meson_project \
    "harfbuzz" "$1" "$2" "$3" "$SOURCES_DIR/harfbuzz-$HARFBUZZ_VERSION" \
    -Dglib=disabled \
    -Dgobject=disabled \
    -Dcairo=disabled \
    -Dchafa=disabled \
    -Dicu=disabled \
    -Dgraphite=disabled \
    -Dgraphite2=disabled \
    -Dfreetype=disabled \
    -Dcoretext=disabled \
    -Dtests=disabled \
    -Dintrospection=disabled \
    -Ddocs=disabled \
    -Dutilities=disabled
}

build_libass() {
  build_meson_project \
    "libass" "$1" "$2" "$3" "$SOURCES_DIR/libass-$LIBASS_VERSION" \
    -Dfontconfig=disabled \
    -Dcoretext=enabled \
    -Dtest=disabled \
    -Dcompare=disabled \
    -Dprofile=disabled \
    -Dfuzz=disabled \
    -Dcheckasm=disabled
}

build_ffmpeg() {
  local platform="$1"
  local arch="$2"
  local prefix="$3"
  local source="$SOURCES_DIR/ffmpeg-$FFMPEG_VERSION"
  local build="$WORK_DIR/$platform-$arch/ffmpeg"
  local sdk
  local sdkroot
  local cc
  local as
  local cflags
  local ldflags
  local extra_ldflags
  local configure_flags

  sdk="$(sdk_name "$platform")"
  sdkroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="xcrun -sdk $sdk clang"
  cflags="-arch $arch $(deployment_flag "$platform") -isysroot $sdkroot -I$prefix/include -I$prefix/include/freetype2"
  ldflags="-arch $arch $(deployment_flag "$platform") -isysroot $sdkroot -L$prefix/lib"
  extra_ldflags="$ldflags -lass -lfreetype -lfribidi -lharfbuzz -lc++ -framework CoreText -framework CoreFoundation -framework CoreGraphics"

  if command -v gas-preprocessor.pl >/dev/null 2>&1; then
    if [ "$arch" = "x86_64" ]; then
      as="gas-preprocessor.pl -arch amd64 -- $cc"
    else
      as="gas-preprocessor.pl -arch aarch64 -- $cc"
    fi
  else
    as="$cc"
  fi

  configure_flags=(
    --target-os=darwin
    --arch="$arch"
    --cc="$cc"
    --as="$as"
    --enable-cross-compile
    --disable-debug
    --disable-programs
    --disable-doc
    --enable-pic
    --enable-libass
    --pkg-config-flags=--static
    --extra-cflags="$cflags"
    --extra-ldflags="$extra_ldflags"
    --prefix="$prefix"
  )

  case "$platform" in
    iPhoneOS|iPhoneSimulator)
      configure_flags+=(--disable-audiotoolbox)
      ;;
    AppleTVOS|AppleTVSimulator)
      configure_flags+=(--disable-avdevice)
      ;;
  esac

  rm -rf "$build"
  mkdir -p "$build"
  pushd "$build" >/dev/null
  env \
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" \
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
    TMPDIR="${TMPDIR:-/tmp}" \
    "$source/configure" "${configure_flags[@]}"
  make -j"$JOBS"
  make install
  popd >/dev/null
}

embed_subtitle_dependencies_into_avfilter() {
  local platform="$1"
  local arch="$2"
  local prefix="$3"
  local sdk
  local libtool
  local output

  sdk="$(sdk_name "$platform")"
  libtool="$(xcrun --sdk "$sdk" --find libtool)"
  output="$prefix/lib/libavfilter-with-libass.a"

  "$libtool" -static -o "$output" \
    "$prefix/lib/libavfilter.a" \
    "$prefix/lib/libass.a" \
    "$prefix/lib/libfreetype.a" \
    "$prefix/lib/libfribidi.a" \
    "$prefix/lib/libharfbuzz.a"

  mv "$output" "$prefix/lib/libavfilter.a"
}

build_arch() {
  local platform="$1"
  local arch="$2"
  local prefix="$INSTALL_DIR/$platform/$arch"

  echo "building $platform $arch"
  rm -rf "$prefix"
  mkdir -p "$prefix"

  build_freetype "$platform" "$arch" "$prefix"
  build_fribidi "$platform" "$arch" "$prefix"
  build_harfbuzz "$platform" "$arch" "$prefix"
  build_libass "$platform" "$arch" "$prefix"
  build_ffmpeg "$platform" "$arch" "$prefix"
  embed_subtitle_dependencies_into_avfilter "$platform" "$arch" "$prefix"
}

combined_library_path() {
  local lib="$1"
  local platform="$2"
  local first_arch
  local archs

  read -r -a archs <<<"$(archs_for_platform "$platform")"
  first_arch="${archs[0]}"

  if [ "${#archs[@]}" -eq 1 ]; then
    echo "$INSTALL_DIR/$platform/$first_arch/lib/$lib.a"
    return
  fi

  local output="$WORK_DIR/$platform/universal/lib/$lib.a"
  mkdir -p "$(dirname "$output")"
  lipo -create \
    "$INSTALL_DIR/$platform/arm64/lib/$lib.a" \
    "$INSTALL_DIR/$platform/x86_64/lib/$lib.a" \
    -output "$output"
  echo "$output"
}

headers_path() {
  local platform="$1"
  local lib="$2"
  local source
  local headers

  case "$lib" in
    libav*|libsw*)
      source="$INSTALL_DIR/$platform/arm64/include/$lib"
      headers="$WORK_DIR/$platform/headers/$lib"
      rm -rf "$headers"
      mkdir -p "$headers/$lib"
      cp -R "$source/." "$headers/$lib/"
      echo "$headers"
      ;;
    *) echo "error: unsupported library $lib" >&2; exit 1 ;;
  esac
}

platform_supports_library() {
  local platform="$1"
  local lib="$2"

  if [ "$lib" = "libavdevice" ] && { [ "$platform" = "AppleTVOS" ] || [ "$platform" = "AppleTVSimulator" ]; }; then
    return 1
  fi

  return 0
}

create_xcframework() {
  local lib="$1"
  local args=()
  local platform
  local library
  local headers

  echo "creating $lib.xcframework"
  for platform in "${PLATFORMS[@]}"; do
    if ! platform_supports_library "$platform" "$lib"; then
      continue
    fi

    library="$(combined_library_path "$lib" "$platform")"
    headers="$(headers_path "$platform" "$lib")"
    args+=(-library "$library" -headers "$headers")
  done

  rm -rf "$PRODUCTS_DIR/$lib.xcframework"
  xcodebuild -create-xcframework "${args[@]}" -output "$PRODUCTS_DIR/$lib.xcframework"
}

create_dist_package() {
  echo "creating Swift package in $DIST_DIR"
  rm -rf "$DIST_DIR"
  mkdir -p "$DIST_DIR"

  cp "$ROOT_DIR/Package.swift" "$DIST_DIR/Package.swift"
  cp -R "$ROOT_DIR/Sources" "$DIST_DIR/Sources"
  mv "$PRODUCTS_DIR" "$DIST_DIR/Frameworks"
  find "$DIST_DIR" -name ".DS_Store" -delete
}

main() {
  download_sources

  rm -rf "$WORK_DIR" "$INSTALL_DIR" "$PRODUCTS_DIR"
  mkdir -p "$WORK_DIR" "$INSTALL_DIR" "$PRODUCTS_DIR"

  for platform in "${PLATFORMS[@]}"; do
    read -r -a archs <<<"$(archs_for_platform "$platform")"
    for arch in "${archs[@]}"; do
      build_arch "$platform" "$arch"
    done
  done

  for lib in "${FFMPEG_LIBS[@]}"; do
    create_xcframework "$lib"
  done

  create_dist_package

  echo "Done"
  echo "Swift package: $DIST_DIR"
  echo "FFmpeg: $FFMPEG_VERSION"
  echo "libass: $LIBASS_VERSION"
}

main "$@"
