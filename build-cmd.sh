#!/usr/bin/env bash

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain on unset env variable
set -u

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
    # Turn off Incredibuild: it seems to swallow unit-test errors, reporting
    # only that something failed. How useful.
    export USE_INCREDIBUILD=0
else
    autobuild="$AUTOBUILD"
fi

# run build commands from root checkout directory
cd "$(dirname "$0")"
top="$(pwd)"
stage="${top}"/stage

# load autbuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# remove_cxxstd
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

PCRE_SOURCE_DIR="pcre"
VERSION_HEADER_FILE="$PCRE_SOURCE_DIR/config.h.generic"
version=$(sed -n -E 's/#define PACKAGE_VERSION "([0-9.]+)"/\1/p' "${VERSION_HEADER_FILE}")
echo "${version}.${AUTOBUILD_BUILD_ID}" > "${stage}/VERSION.txt"

case "$AUTOBUILD_PLATFORM" in
    windows*)
        load_vsvars
        pushd pcre

            # Create project/build directory
            mkdir -p Win
            pushd Win

                cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" \
                      -DCMAKE_CXX_FLAGS="$LL_BUILD_RELEASE" ..

                build_sln PCRE.sln "Release|$AUTOBUILD_WIN_VSPLATFORM" ALL_BUILD

                # Install and move pieces around
                build_sln PCRE.sln "Release|$AUTOBUILD_WIN_VSPLATFORM" INSTALL.vcxproj
                mkdir -p "$stage"/lib/release/

                mv -v Release/*.lib "$stage"/lib/release/

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    build_sln PCRE.sln "Release|$AUTOBUILD_WIN_VSPLATFORM" RUN_TESTS.vcxproj
                fi
            popd

            # Fixup include directory
            mkdir -p "$stage"/include/pcre/
            cp -vp *.h "$stage"/include/pcre/
            cp -vp Win/*.h "$stage"/include/pcre/
        popd
    ;;

    darwin*)
        pushd pcre
            libdir="$top/stage/lib"
            mkdir -p "$libdir"/release

            opts="${TARGET_OPTS:--arch $AUTOBUILD_CONFIGURE_ARCH $LL_BUILD_RELEASE}"
            plainopts="$(remove_cxxstd $opts)"

            # Prefer llvm-g++ if available.
            if [ -x /usr/bin/llvm-gcc -a -x /usr/bin/llvm-g++ ]; then
                export CC=/usr/bin/llvm-gcc
                export CXX=/usr/bin/llvm-g++
            fi

	    # work around timestamps being inaccurate after recent git checkout resulting in spurious aclocal errors
	    # see https://github.com/actions/checkout/issues/364#issuecomment-812618265
	    touch *

            # Release
            CFLAGS="$plainopts" CXXFLAGS="$opts" LDFLAGS="$plainopts" \
                ./configure --disable-dependency-tracking --with-pic --enable-utf --enable-unicode-properties \
                --enable-static=yes --enable-shared=no \
                --prefix="$stage" --includedir="$stage"/include/pcre --libdir="$libdir"/release
            make
            make install

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            make clean

        popd
    ;;

    linux*)
        libdir="$top/stage/lib/"
        mkdir -p "$libdir"/release
        pushd pcre
            # Default target per AUTOBUILD_ADDRSIZE
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"
            plainopts="$(remove_cxxstd $opts)"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Release
            CFLAGS="$plainopts" CXXFLAGS="$opts" LDFLAGS="$plainopts" \
                ./configure --with-pic --enable-utf --enable-unicode-properties \
                --enable-static=yes --enable-shared=no \
                --prefix="$stage" --includedir="$stage"/include/pcre --libdir="$libdir"/release
            make
            make install

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            make clean
        popd
    ;;

    *)
        echo "Unrecognized platform" 1>&2
        exit 1
    ;;
esac

mkdir -p stage/LICENSES
cp -a "pcre/LICENCE" "stage/LICENSES/pcre-license.txt"
mkdir -p "$stage"/docs/pcre/
cp -a "$top"/README.Linden "$stage"/docs/pcre/
