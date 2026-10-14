#!/bin/bash
# Package the iOS build of Zero Hour into a signed .app or unsigned .ipa.
#
# Flow:
#   1. xcodegen + xcodebuild produce a provisioning-shell app.
#   2. The stub executable is replaced with the real z_generals engine binary.
#   3. Runtime dylibs and MoltenVK are embedded in Frameworks/.
#   4. Signed builds are re-signed inside-out. Unsigned builds are left for a
#      sideloading tool such as AltStore or SideStore to sign during install.
#   5. Optional: create an .ipa and install a signed build to a connected device.
#
# Usage: ./scripts/build/ios/package-ios-zh.sh [--dev] [--install] [--unsigned] [--ipa]
#   --dev       skip bundling the 2.7 GB of game assets (copy owned assets later)
#   --install   install the signed app to the first connected device
#   --unsigned  build without an Apple Developer certificate for later sideloading
#   --ipa       also create build/ios-package/GeneralsXZH-unsigned.ipa (or signed.ipa)
set -euo pipefail

DEV_MODE=0
DO_INSTALL=0
UNSIGNED=0
MAKE_IPA=0
for arg in "$@"; do
    case "$arg" in
        --dev)      DEV_MODE=1 ;;
        --install)  DO_INSTALL=1 ;;
        --unsigned) UNSIGNED=1 ;;
        --ipa)      MAKE_IPA=1 ;;
        *) echo "ERROR: unknown argument '$arg' (usage: $0 [--dev] [--install] [--unsigned] [--ipa])"; exit 1 ;;
    esac
done

if [[ "${UNSIGNED}" == "1" && "${DO_INSTALL}" == "1" ]]; then
    echo "ERROR: --install requires a signed build; install an unsigned IPA with AltStore or SideStore."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build/ios-vulkan"
IOS_DIR="${PROJECT_ROOT}/ios"
DERIVED="${IOS_DIR}/build"
OUT_DIR="${PROJECT_ROOT}/build/ios-package"
APP_NAME="GeneralsXZH"
IDENTITY="${GX_SIGN_IDENTITY:-Apple Development}"

# Signing/bundle identity — override for your own Apple Developer account:
#   GX_TEAM_ID=ABCDE12345 GX_BUNDLE_ID=com.you.generalszh ./package-ios-zh.sh --install
# Unsigned CI builds only need a unique bundle id:
#   GX_BUNDLE_ID=com.you.generalszh ./package-ios-zh.sh --dev --unsigned --ipa
TEAM_ID="${GX_TEAM_ID:-7S264298H8}"
BUNDLE_ID="${GX_BUNDLE_ID:-me.ammaar.generalszh}"

GAME_BIN="${BUILD_DIR}/GeneralsMD/GeneralsXZH.app/GeneralsXZH"
DXVK_BUILD="${BUILD_DIR}/_deps/dxvk-build-macos"

if [[ ! -f "${GAME_BIN}" ]]; then
    echo "ERROR: engine binary not found at ${GAME_BIN} — build the ios-vulkan preset first."
    exit 1
fi

echo "==> Generating Xcode project (xcodegen)"
(cd "${IOS_DIR}" && xcodegen generate --quiet)

echo "==> Building provisioning shell app"
XCODEBUILD_ARGS=(
    -project "${IOS_DIR}/${APP_NAME}.xcodeproj"
    -scheme "${APP_NAME}"
    -configuration Release
    -destination 'generic/platform=iOS'
    -derivedDataPath "${DERIVED}"
    PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}"
)
if [[ "${UNSIGNED}" == "1" ]]; then
    XCODEBUILD_ARGS+=(
        DEVELOPMENT_TEAM=""
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
    )
else
    XCODEBUILD_ARGS+=(
        DEVELOPMENT_TEAM="${TEAM_ID}"
        -allowProvisioningUpdates
    )
fi
xcodebuild "${XCODEBUILD_ARGS[@]}" build | tail -3

SHELL_APP="${DERIVED}/Build/Products/Release-iphoneos/${APP_NAME}.app"
if [[ ! -d "${SHELL_APP}" ]]; then
    echo "ERROR: shell app not produced at ${SHELL_APP}"
    exit 1
fi

echo "==> Assembling final app"
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
cp -R "${SHELL_APP}" "${OUT_DIR}/"
APP="${OUT_DIR}/${APP_NAME}.app"

# Replace stub executable with the engine.
cp "${GAME_BIN}" "${APP}/${APP_NAME}"

# Embed runtime dylibs.
mkdir -p "${APP}/Frameworks"
for lib in \
    "${DXVK_BUILD}/src/d3d8/libdxvk_d3d8.0.dylib" \
    "${DXVK_BUILD}/src/d3d9/libdxvk_d3d9.0.dylib" \
    "${BUILD_DIR}/_deps/sdl3-build/libSDL3.0.dylib" \
    "${BUILD_DIR}/_deps/sdl3_image-build/libSDL3_image.0.dylib" \
    "${BUILD_DIR}/_deps/openal_soft-build/libopenal.1.24.2.dylib" \
    "${BUILD_DIR}/libgamespy.dylib"; do
    if [[ -f "${lib}" ]]; then
        cp "${lib}" "${APP}/Frameworks/"
        echo "    embedded $(basename "${lib}")"
    else
        case "$(basename "${lib}")" in
            libgamespy.dylib)
                echo "    (skip, optional: $(basename "${lib}"))" ;;
            *)
                echo "ERROR: required dylib not built: ${lib}"
                echo "  Build first: cmake --preset ios-vulkan && cmake --build build/ios-vulkan --target z_generals"
                exit 1 ;;
        esac
    fi
done

# openal-soft's install name is libopenal.1.dylib; the embedded file must match it.
if [[ -f "${APP}/Frameworks/libopenal.1.24.2.dylib" ]]; then
    mv "${APP}/Frameworks/libopenal.1.24.2.dylib" "${APP}/Frameworks/libopenal.1.dylib"
fi

# MoltenVK: DXVK dlopens @executable_path/Frameworks/MoltenVK.framework/MoltenVK.
MVK_FRAMEWORK="${GX_MOLTENVK:-${HOME}/GeneralsX/MoltenVK/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework}"
if [[ -d "${MVK_FRAMEWORK}" ]]; then
    cp -R "${MVK_FRAMEWORK}" "${APP}/Frameworks/"
    echo "    embedded MoltenVK.framework"
else
    echo "ERROR: MoltenVK.framework not found at ${MVK_FRAMEWORK}"
    echo "  Run scripts/build/ios/fetch-moltenvk.sh (pinned version + checksum)."
    exit 1
fi

# Game assets inside the bundle. --dev leaves them out so users can copy their
# owned game data to the app's Documents directory after sideloading.
GAME_DATA_SRC="${GX_GAME_DATA:-${HOME}/GeneralsX/GeneralsZH}"
FONTS_SRC="${GX_FONTS:-${HOME}/GeneralsX/ios-staging/fonts}"
CONFIG_SRC="${GX_CONFIG:-${IOS_DIR}/config}"
if [[ "${DEV_MODE}" != "1" ]]; then
    echo "==> Bundling game assets into the app"
    mkdir -p "${APP}/GameData"
    rsync -a --exclude=".*" \
        --exclude="*.dylib" --exclude="run.sh" --exclude="GeneralsXZH" \
        --exclude="GeneralsXZH.dxvk-cache" --exclude="*_d3d9.log" \
        --exclude="MoltenVK_icd.json" --exclude="dxvk.conf" --exclude="fontconfig" \
        --exclude="*.DLL" --exclude="*.dll" --exclude="*.dat" --exclude="*.ico" \
        --exclude="*.bmp" --exclude="*.doc" --exclude="*.lcf" --exclude="Launcher.txt" \
        --exclude="MSS" --exclude="Manuals" --exclude="steamapps" \
        --exclude="steam_appid.txt" --exclude="00000000.*" \
        --exclude="RedistInstallers" --exclude="_CommonRedist" --exclude="*.txt" \
        "${GAME_DATA_SRC}/" "${APP}/GameData/"
    if [[ -d "${FONTS_SRC}" ]]; then
        mkdir -p "${APP}/GameData/fonts"
        cp "${FONTS_SRC}"/*.ttf "${APP}/GameData/fonts/"
    else
        echo "ERROR: fonts not staged at ${FONTS_SRC} — the app would render no text."
        echo "  Run scripts/build/ios/stage-fonts.sh once."
        exit 1
    fi
    for cfg in dxvk.conf Options.ini; do
        if [[ ! -f "${CONFIG_SRC}/${cfg}" ]]; then
            echo "ERROR: ${CONFIG_SRC}/${cfg} missing (should ship with the repo in ios/config/)"
            exit 1
        fi
    done
    cp "${CONFIG_SRC}/dxvk.conf" "${APP}/GameData/dxvk.conf"
    cp "${CONFIG_SRC}/Options.ini" "${APP}/GameData/DefaultOptions.ini"
    echo "    bundled $(du -sh "${APP}/GameData" | cut -f1) of game data"
fi

# Loose icon PNGs help developer-signed sideloads display the icon immediately.
ICON_SRC="${IOS_DIR}/Stub/Assets.xcassets/AppIcon.appiconset/icon.png"
if [[ -f "${ICON_SRC}" ]]; then
    sips -z 120 120 "${ICON_SRC}" --out "${APP}/AppIcon60x60@2x.png" >/dev/null
    sips -z 152 152 "${ICON_SRC}" --out "${APP}/AppIcon76x76@2x.png" >/dev/null
    sips -z 167 167 "${ICON_SRC}" --out "${APP}/AppIcon83.5x83.5@2x.png" >/dev/null
    echo "    icon PNG fallbacks added"
fi

# Point the executable's rpath at the embedded frameworks.
install_name_tool -add_rpath "@executable_path/Frameworks" "${APP}/${APP_NAME}" 2>/dev/null || true

if [[ "${UNSIGNED}" == "1" ]]; then
    echo "==> Leaving bundle unsigned for sideloading"
    rm -rf "${APP}/_CodeSignature"
    find "${APP}" -name _CodeSignature -type d -prune -exec rm -rf {} + 2>/dev/null || true
else
    echo "==> Re-signing"
    ENTITLEMENTS="${OUT_DIR}/entitlements.plist"
    codesign -d --entitlements - --xml "${SHELL_APP}" > "${ENTITLEMENTS}" 2>/dev/null
    for f in "${APP}/Frameworks/"*.dylib; do
        [[ -f "$f" ]] && codesign --force --sign "${IDENTITY}" --timestamp=none "$f"
    done
    if [[ -d "${APP}/Frameworks/MoltenVK.framework" ]]; then
        codesign --force --sign "${IDENTITY}" --timestamp=none "${APP}/Frameworks/MoltenVK.framework"
    fi
    codesign --force --sign "${IDENTITY}" --timestamp=none \
        --entitlements "${ENTITLEMENTS}" "${APP}"
    codesign --verify --deep "${APP}" && echo "    signature OK"
fi

echo "==> App ready: ${APP}"

if [[ "${MAKE_IPA}" == "1" ]]; then
    IPA_KIND="signed"
    [[ "${UNSIGNED}" == "1" ]] && IPA_KIND="unsigned"
    IPA_PATH="${OUT_DIR}/${APP_NAME}-${IPA_KIND}.ipa"
    IPA_STAGE="${OUT_DIR}/ipa-stage"
    rm -rf "${IPA_STAGE}"
    mkdir -p "${IPA_STAGE}/Payload"
    cp -R "${APP}" "${IPA_STAGE}/Payload/"
    (cd "${IPA_STAGE}" && /usr/bin/zip -qry "${IPA_PATH}" Payload)
    rm -rf "${IPA_STAGE}"
    echo "==> IPA ready: ${IPA_PATH}"
fi

if [[ "${DO_INSTALL}" == "1" ]]; then
    echo "==> Installing to connected device"
    DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | awk '/connected/{print $(NF-2); exit}')
    if [[ -z "${DEVICE_ID}" ]]; then
        DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | grep -i connected | grep -oE '[0-9A-F-]{36}' | head -1)
    fi
    if [[ -z "${DEVICE_ID}" ]]; then
        echo "ERROR: no connected device found (xcrun devicectl list devices)"
        exit 1
    fi
    xcrun devicectl device install app --device "${DEVICE_ID}" "${APP}"
    echo "==> Installed. Copy game assets to the app's Documents via Finder/Files app."
fi
