#!/usr/bin/env bash
#
# build-hdf5-xcframework.sh
#
# Downloads HDF5 source and builds a static XCFramework for:
#   - macOS arm64
#   - iOS arm64 (device)
#   - iOS Simulator arm64
#
# Output: Frameworks/CHDF5.xcframework
#
# The XCFramework includes:
#   - libhdf5.a static library (per platform)
#   - All HDF5 public headers
#   - chdf5_shim.h (inline C wrappers for HDF5 macros Swift can't import)
#   - module.modulemap defining the CHDF5 module
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

HDF5_VERSION="1.14.6"
HDF5_TARBALL="hdf5-${HDF5_VERSION}.tar.gz"
HDF5_SRC_DIR="hdf5-${HDF5_VERSION}"

BUILD_DIR="${PROJECT_ROOT}/.hdf5-build"
FRAMEWORKS_DIR="${PROJECT_ROOT}/Frameworks"

# Deployment targets
MACOS_DEPLOYMENT_TARGET="14.0"
IOS_DEPLOYMENT_TARGET="16.0"

# Common CMake flags for HDF5
HDF5_CMAKE_FLAGS=(
    -DBUILD_SHARED_LIBS=OFF
    -DBUILD_STATIC_LIBS=ON
    -DHDF5_BUILD_TOOLS=OFF
    -DHDF5_BUILD_EXAMPLES=OFF
    -DHDF5_BUILD_TESTING=OFF
    -DHDF5_BUILD_CPP_LIB=OFF
    -DHDF5_BUILD_HL_LIB=OFF
    -DHDF5_BUILD_FORTRAN=OFF
    -DHDF5_BUILD_JAVA=OFF
    -DHDF5_ENABLE_Z_LIB_SUPPORT=ON
    -DHDF5_ENABLE_SZIP_SUPPORT=OFF
    -DHDF5_ENABLE_PARALLEL=OFF
    -DHDF5_ENABLE_THREADSAFE=OFF
    -DHDF5_ENABLE_MIRROR_VFD=OFF
    -DHDF5_BUILD_UTILS=OFF
    -DHDF5_ENABLE_SUBFILING_VFD=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)

echo "=== HDF5 XCFramework Builder ==="
echo "HDF5 version: ${HDF5_VERSION}"
echo "Build directory: ${BUILD_DIR}"
echo "Output: ${FRAMEWORKS_DIR}/CHDF5.xcframework"
echo ""

# --- Step 1: Download HDF5 source ---
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [ ! -d "${HDF5_SRC_DIR}" ]; then
    if [ ! -f "${HDF5_TARBALL}" ]; then
        echo "==> Downloading HDF5 ${HDF5_VERSION}..."

        # Try GitHub releases first
        GITHUB_URL="https://github.com/HDFGroup/hdf5/releases/download/hdf5_${HDF5_VERSION}/${HDF5_TARBALL}"
        echo "    Trying: ${GITHUB_URL}"
        if curl -fL -o "${HDF5_TARBALL}" "${GITHUB_URL}" 2>/dev/null; then
            echo "    Downloaded from GitHub."
        else
            # Try HDF Group support site
            HDFGROUP_URL="https://support.hdfgroup.org/releases/hdf5/v1_14/v1_14_6/downloads/${HDF5_TARBALL}"
            echo "    GitHub failed, trying: ${HDFGROUP_URL}"
            if curl -fL -o "${HDF5_TARBALL}" "${HDFGROUP_URL}" 2>/dev/null; then
                echo "    Downloaded from HDF Group."
            else
                # Try alternate GitHub URL pattern
                ALT_URL="https://github.com/HDFGroup/hdf5/releases/download/hdf5-${HDF5_VERSION}/${HDF5_TARBALL}"
                echo "    HDF Group failed, trying: ${ALT_URL}"
                if curl -fL -o "${HDF5_TARBALL}" "${ALT_URL}" 2>/dev/null; then
                    echo "    Downloaded from GitHub (alt)."
                else
                    echo "ERROR: Could not download HDF5 ${HDF5_VERSION} from any source."
                    echo "Please download manually and place at: ${BUILD_DIR}/${HDF5_TARBALL}"
                    exit 1
                fi
            fi
        fi
    fi

    echo "==> Extracting HDF5 source..."
    tar xzf "${HDF5_TARBALL}"

    # Handle case where tarball extracts to a different directory name
    if [ ! -d "${HDF5_SRC_DIR}" ]; then
        EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "hdf5*" ! -name "." | head -1 | sed 's|^\./||')
        if [ -n "${EXTRACTED_DIR}" ] && [ -d "${EXTRACTED_DIR}" ]; then
            echo "    Extracted to: ${EXTRACTED_DIR}"
            if [ "${EXTRACTED_DIR}" != "${HDF5_SRC_DIR}" ]; then
                mv "${EXTRACTED_DIR}" "${HDF5_SRC_DIR}"
            fi
        else
            echo "ERROR: Could not find extracted HDF5 source directory"
            ls -la
            exit 1
        fi
    fi
fi

SRC_PATH="${BUILD_DIR}/${HDF5_SRC_DIR}"
echo "==> Source at: ${SRC_PATH}"

# --- Step 2: Build for macOS (arm64 + x86_64 universal) ---
echo ""
echo "=== Building for macOS (arm64 + x86_64) ==="
MACOS_BUILD="${BUILD_DIR}/build-macos"
MACOS_INSTALL="${BUILD_DIR}/install-macos"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "${MACOS_BUILD}"
mkdir -p "${MACOS_BUILD}"
cmake -S "${SRC_PATH}" -B "${MACOS_BUILD}" \
    "${HDF5_CMAKE_FLAGS[@]}" \
    -DCMAKE_INSTALL_PREFIX="${MACOS_INSTALL}" \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}" \
    -DCMAKE_SYSTEM_NAME=Darwin \
    -DZLIB_LIBRARY="${MACOS_SDK}/usr/lib/libz.tbd" \
    -DZLIB_INCLUDE_DIR="${MACOS_SDK}/usr/include" \
    -G "Unix Makefiles" \
    2>&1 | tail -5

cmake --build "${MACOS_BUILD}" --parallel "$(sysctl -n hw.ncpu)" 2>&1 | tail -3
cmake --install "${MACOS_BUILD}" 2>&1 | tail -3
echo "    macOS universal build complete."

# --- Step 3: Build for iOS arm64 (device) ---
echo ""
echo "=== Building for iOS arm64 (device) ==="
IOS_BUILD="${BUILD_DIR}/build-ios-arm64"
IOS_INSTALL="${BUILD_DIR}/install-ios-arm64"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

rm -rf "${IOS_BUILD}"
mkdir -p "${IOS_BUILD}"
cmake -S "${SRC_PATH}" -B "${IOS_BUILD}" \
    "${HDF5_CMAKE_FLAGS[@]}" \
    -DCMAKE_INSTALL_PREFIX="${IOS_INSTALL}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${IOS_SDK}" \
    -DZLIB_LIBRARY="${IOS_SDK}/usr/lib/libz.tbd" \
    -DZLIB_INCLUDE_DIR="${IOS_SDK}/usr/include" \
    -DCMAKE_C_FLAGS="-fembed-bitcode" \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DH5_HAVE_GETPWUID=OFF \
    -DH5_HAVE_SIGNAL=OFF \
    -G "Unix Makefiles" \
    2>&1 | tail -5

cmake --build "${IOS_BUILD}" --parallel "$(sysctl -n hw.ncpu)" 2>&1 | tail -3
cmake --install "${IOS_BUILD}" 2>&1 | tail -3
echo "    iOS arm64 build complete."

# --- Step 4: Build for iOS Simulator (arm64 + x86_64) ---
echo ""
echo "=== Building for iOS Simulator (arm64 + x86_64) ==="
SIM_BUILD="${BUILD_DIR}/build-sim"
SIM_INSTALL="${BUILD_DIR}/install-sim"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

rm -rf "${SIM_BUILD}"
mkdir -p "${SIM_BUILD}"
cmake -S "${SRC_PATH}" -B "${SIM_BUILD}" \
    "${HDF5_CMAKE_FLAGS[@]}" \
    -DCMAKE_INSTALL_PREFIX="${SIM_INSTALL}" \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${SIM_SDK}" \
    -DZLIB_LIBRARY="${SIM_SDK}/usr/lib/libz.tbd" \
    -DZLIB_INCLUDE_DIR="${SIM_SDK}/usr/include" \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DH5_HAVE_GETPWUID=OFF \
    -DH5_HAVE_SIGNAL=OFF \
    -G "Unix Makefiles" \
    2>&1 | tail -5

cmake --build "${SIM_BUILD}" --parallel "$(sysctl -n hw.ncpu)" 2>&1 | tail -3
cmake --install "${SIM_BUILD}" 2>&1 | tail -3
echo "    iOS Simulator universal build complete."

# --- Step 5: Prepare headers with shim and module map ---
echo ""
echo "=== Preparing headers ==="

# The shim header provides inline C functions for HDF5 macros Swift can't import.
# We copy it into each platform's header directory and create a module map.
SHIM_HEADER="${PROJECT_ROOT}/Sources/CHDF5Shim/include/chdf5_shim.h"

find_hdf5_lib() {
    local install_dir="$1"
    find "${install_dir}" -name "libhdf5*.a" ! -name "*hl*" ! -name "*cpp*" ! -name "*tools*" | head -1
}

find_hdf5_headers() {
    local install_dir="$1"
    find "${install_dir}" -name "hdf5.h" -exec dirname {} \; | head -1
}

MACOS_LIB=$(find_hdf5_lib "${MACOS_INSTALL}")
IOS_LIB=$(find_hdf5_lib "${IOS_INSTALL}")
SIM_LIB=$(find_hdf5_lib "${SIM_INSTALL}")

MACOS_HEADERS=$(find_hdf5_headers "${MACOS_INSTALL}")
IOS_HEADERS=$(find_hdf5_headers "${IOS_INSTALL}")
SIM_HEADERS=$(find_hdf5_headers "${SIM_INSTALL}")

echo "    macOS lib: ${MACOS_LIB}"
echo "    iOS lib: ${IOS_LIB}"
echo "    Simulator lib: ${SIM_LIB}"
echo "    macOS headers: ${MACOS_HEADERS}"
echo "    iOS headers: ${IOS_HEADERS}"
echo "    Simulator headers: ${SIM_HEADERS}"

# For each platform: copy shim header and create module map
for HEADERS_DIR in "${MACOS_HEADERS}" "${IOS_HEADERS}" "${SIM_HEADERS}"; do
    # Copy the shim header
    cp "${SHIM_HEADER}" "${HEADERS_DIR}/chdf5_shim.h"

    # Create module map that exposes HDF5 + shim under module name "CHDF5"
    cat > "${HEADERS_DIR}/module.modulemap" << 'MODULEMAP'
module CHDF5 {
    header "hdf5.h"
    header "chdf5_shim.h"
    link "hdf5"
    link "z"
    export *
}
MODULEMAP
    echo "    Prepared headers in ${HEADERS_DIR}"
done

# --- Step 6: Create XCFramework ---
echo ""
echo "=== Creating XCFramework ==="

rm -rf "${FRAMEWORKS_DIR}/CHDF5.xcframework"
mkdir -p "${FRAMEWORKS_DIR}"

xcodebuild -create-xcframework \
    -library "${MACOS_LIB}" -headers "${MACOS_HEADERS}" \
    -library "${IOS_LIB}" -headers "${IOS_HEADERS}" \
    -library "${SIM_LIB}" -headers "${SIM_HEADERS}" \
    -output "${FRAMEWORKS_DIR}/CHDF5.xcframework"

echo ""
echo "=== XCFramework created successfully ==="
echo "Location: ${FRAMEWORKS_DIR}/CHDF5.xcframework"
echo ""

echo "XCFramework contents:"
find "${FRAMEWORKS_DIR}/CHDF5.xcframework" -maxdepth 3 -type f | sort | head -30
echo ""
echo "Done!"
