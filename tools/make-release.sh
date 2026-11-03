#!/usr/bin/env bash
#
# make-release.sh —— anShot 正式发布打包（本地使用，未公证）
#
# 产物（全部落在 dist/，该目录不入库）：
#   anShot-<版本>.dmg          安装镜像（内含 app + Applications 链接 + 安装说明）
#   anShot-<版本>.zip          ditto 归档（保留符号链接与权限，供脚本分发）
#   SHA256SUMS                 两个产物的校验和
#   RELEASE-NOTES.md           发布说明（从 docs/release/ 复制）
#   logs/build-release.log     本次构建的完整日志（审计用）
#
# ── 为什么用脚本而不是手工点 Xcode ────────────────────────────────
#
# 「构建必须检查退出码」是本项目的既有纪律（曾出现构建失败却启动了旧二进制）。
# 手工流程无法保证「校验通过才出包」，而这个脚本每一步都以退出码为准：
# 构建、双架构、版本号、签名校验任一不过，脚本立刻失败，不会产出半成品 DMG。
#
# ── 签名与 Gatekeeper 的现状（如实声明）──────────────────────────
#
# 本机使用自签名证书 `anShot Dev`（无 Team ID）。它能通过 codesign 严格校验，
# 也在本机稳定保留 TCC 权限（DR 锚定 bundleID + 证书根哈希），
# 但 `spctl -a` 会给出 rejected —— 自签且未公证的必然结果。
#
# 本脚本**不试图掩盖**这一点：它把 spctl 的真实结论打印出来。
# 本地使用不受影响（本机自建的文件不带 com.apple.quarantine）；
# 若要分发给他人，必须换成 Apple Developer ID 签名 + notarytool 公证，
# 那是另一条流水线，不是在本脚本里加参数能做到的。
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# 失败时指出出错行：发布脚本最怕的就是「什么都没打印就退出」。
# 注意：必须与 `set -e` 配合使用，且**不能**把「非零但是正常结论」的命令
# （如 spctl 对未公证应用返回的拦截码）交给它——那类命令要显式 `|| true`。
trap 'echo "✗ 脚本在第 ${LINENO} 行失败" >&2' ERR

# ── 版本号取自 project.yml（单一事实来源），不在这里再写一份
VERSION="$(grep -E '^[[:space:]]+MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
if [[ -z "${VERSION}" ]]; then
    echo "无法从 project.yml 解析 MARKETING_VERSION" >&2
    exit 1
fi

DIST="${ROOT}/dist"
BUILD_DIR="${ROOT}/build-release"
APP_NAME="anShot"
APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"
STAGE="${DIST}/stage"
LOG_DIR="${DIST}/logs"
LOG="${LOG_DIR}/build-release.log"

rm -rf "${DIST}"
mkdir -p "${DIST}" "${LOG_DIR}"

echo "════ anShot ${VERSION} 发布打包 ════"

# ── 0. 单元测试门禁
#
# 为什么放在最前面：下面的 Release 构建要几分钟，而测试只要十几秒。
# 测试不过就直接退出，不必等构建跑完才知道这个包不该出。
#
# 为什么必须有这一步：本脚本此前的全部校验都针对**产物**
#（架构、版本号、签名、CDHash）——没有任何一步检查**代码本身**是否正确。
# 即 1.0.0 是在从未运行过任何自动化测试的情况下构建并发布的。
# 产物校验通过只能证明「打包没问题」，不能证明「代码没坏」。
#
# 包清单与顺序无关；任一包的测试失败即中止，不产出任何产物。
# 若某个包因**环境**（而非代码）失败——例如 TCC 权限未授予——
# 必须先解决环境，不得直接注释掉本步骤。
echo "── 0/7 单元测试门禁"
if ! command -v swift >/dev/null 2>&1; then
    echo "缺少 swift 工具链，无法运行测试门禁" >&2
    exit 1
fi
TEST_FAILED=0
for pkg in AnShotCore AnShotCapture AnShotAutomation AnShotUI; do
    echo "   swift test → ${pkg}"
    if ! swift test --package-path "Packages/${pkg}" >>"${LOG}" 2>&1; then
        echo "   ✘ ${pkg} 测试失败" >&2
        TEST_FAILED=1
    fi
done
if [[ ${TEST_FAILED} -ne 0 ]]; then
    echo "测试门禁未通过，中止打包（未产出任何产物）；完整输出见 ${LOG}" >&2
    exit 1
fi
echo "   ✅ 四个包的单元测试全部通过"

# ── 1. 生成工程（.xcodeproj 是生成物，版本号从这里才生效）
echo "── 1/7 生成 Xcode 工程"
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "缺少 xcodegen，无法生成工程" >&2
    exit 1
fi
xcodegen generate >>"${LOG}" 2>&1

# ── 2. Release 构建（universal：ARCHS = arm64 x86_64）
echo "── 2/7 Release 构建（arm64 + x86_64）"
set +e
xcodebuild \
    -project anShot.xcodeproj \
    -scheme anShot \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${BUILD_DIR}" \
    build >>"${LOG}" 2>&1
BUILD_STATUS=$?
set -e
if [[ ${BUILD_STATUS} -ne 0 ]]; then
    echo "构建失败（退出码 ${BUILD_STATUS}），完整日志：${LOG}" >&2
    grep -E "error:" "${LOG}" | head -20 >&2 || true
    exit 1
fi
grep -E "BUILD SUCCEEDED" "${LOG}" | tail -1 || true

if [[ ! -d "${APP_PATH}" ]]; then
    echo "构建声称成功但找不到产物：${APP_PATH}" >&2
    exit 1
fi

# ── 3. 产物校验：双架构、版本号、签名
echo "── 3/7 校验产物"
LIPO="$(lipo -info "${APP_PATH}/Contents/MacOS/${APP_NAME}")"
echo "   ${LIPO}"
for arch in arm64 x86_64; do
    if ! grep -q "${arch}" <<<"${LIPO}"; then
        echo "产物缺少 ${arch} 切片" >&2
        exit 1
    fi
done

PLIST="${APP_PATH}/Contents/Info.plist"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"
PLIST_MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${PLIST}")"
echo "   CFBundleShortVersionString=${PLIST_VERSION} CFBundleVersion=${PLIST_BUILD} LSMinimumSystemVersion=${PLIST_MIN}"
if [[ "${PLIST_VERSION}" != "${VERSION}" ]]; then
    echo "Info.plist 版本（${PLIST_VERSION}）与 project.yml（${VERSION}）不一致" >&2
    exit 1
fi

codesign --verify --strict --verbose=2 "${APP_PATH}" 2>&1 | sed 's/^/   /'
AUTHORITY="$(codesign -dvvv "${APP_PATH}" 2>&1 | grep -E '^Authority=' || true)"
echo "   ${AUTHORITY:-Authority=（无）}"

# spctl 的结论**如实打印**：自签未公证必然是 rejected，这不是脚本的失败条件。
#
# ⚠️ 必须 `|| true`：pipefail 下，spctl 的「拦截」退出码会经管道传播上来，
# 被 set -e 当成致命错误——首版就这样在没有任何报错的情况下中途退出了。
# 这正是「检查退出码」纪律的另一面：**先分清哪些非零是正常结论**。
SPCTL_RESULT="$(spctl -a -vvv "${APP_PATH}" 2>&1 | head -2 | tr '\n' ' ' || true)"
echo "   Gatekeeper: ${SPCTL_RESULT}（自签 + 未公证的预期结果，见脚本头说明）"

# ── 4. 组装安装镜像的内容
echo "── 4/7 组装镜像内容"
mkdir -p "${STAGE}"
# ditto 而非 cp -R：保真拷贝 bundle 的全部元数据与签名信息
ditto "${APP_PATH}" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"

cat > "${STAGE}/安装说明.txt" <<EOF
anShot ${VERSION} 安装说明
────────────────────────────────────────

【安装】
1. 把左边的「anShot.app」拖到右边的「Applications」文件夹里。
2. 打开「访达 → 应用程序 → anShot」。

【首次打开可能被系统拦下】
本版本使用自签名，且未经过 Apple 公证，因此首次打开时系统的
「隐私与安全性」可能提示「无法打开，因为来自身份不明的开发者」。
放行方式（任选其一）：
  · 在「应用程序」里按住 Control 点击 anShot → 选择「打开」→ 再点「打开」；
  · 或打开「系统设置 → 隐私与安全性」，在页面下方找到关于 anShot 的提示，
    点「仍要打开」。
命令行方式（适合脚本）：
  xattr -dr com.apple.quarantine /Applications/anShot.app
注意：macOS 15 起 spctl --master-disable 已失效，不要用它。

【首次运行需要授予的权限】
· 屏幕录制：截图与录屏必需。系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 anShot。
· 麦克风：仅在录制时勾选了「麦克风」才需要。

【anShot 在哪】
它是菜单栏应用，没有 Dock 图标。启动后请看屏幕**顶部菜单栏右上角**的
相机图标；点它可以截图，默认快捷键是 ⌃1。

【卸载】
把「应用程序」里的 anShot.app 拖进废纸篓即可。若想一并清除配置：
  defaults delete com.anshot.app
EOF

# ── 5. 生成 DMG 与 zip
#
# 用 `diskutil image create from` 而不是 `hdiutil create`：后者已被系统标为废弃
# （macOS 27 上实测会输出 “hdiutil: WARNING: 'hdiutil create -volname …' is deprecated”）。
# **已实测**：两者都能产出可挂载的 UDZO 镜像；diskutil 产出的是 APFS 卷，
# 而最低系统基线是 13.0（APFS 自 10.13 起受支持），故不影响兼容性。
# 这条不是“反正能用就行”：发布脚本里的每条命令都会被长期复制，
# 用一个已声明废弃的命令会在将来的系统上突然变成硬错误。
echo "── 5/7 生成 DMG 与 zip"
DMG="${DIST}/anShot-${VERSION}.dmg"
ZIP="${DIST}/anShot-${VERSION}.zip"
diskutil image create from "${STAGE}" \
    --volumeName "anShot ${VERSION}" \
    --format UDZO \
    "${DMG}" >>"${LOG}" 2>&1
# --sequesterRsrc 与 --keepParent：保留资源叉与顶层目录，解压即得完整的 .app
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP}"
rm -rf "${STAGE}"

# ── 6. 校验和与发布说明
echo "── 6/7 校验和与发布说明"
( cd "${DIST}" && shasum -a 256 "anShot-${VERSION}.dmg" "anShot-${VERSION}.zip" > SHA256SUMS )
# 校验和文件自己也留在 dist/ 里，供下载后核对
sed 's/^/   /' "${DIST}/SHA256SUMS"
NOTES_SOURCE="${ROOT}/docs/release/release-notes-${VERSION}.md"
if [[ -f "${NOTES_SOURCE}" ]]; then
    cp "${NOTES_SOURCE}" "${DIST}/RELEASE-NOTES.md"
else
    echo "   未找到 ${NOTES_SOURCE}，跳过发布说明" >&2
fi

# ── 7. 摘要
echo "── 7/7 完成"
ls -lh "${DIST}" | tail -n +2 | sed 's/^/   /'
echo
echo "产物目录：${DIST}"
echo "人工冒烟（发布门禁的最后一步，必须由人做）："
echo "  1) open \"${DMG}\" 后把 anShot.app 拖入 /Applications"
echo "  2) 启动它，确认菜单栏出现图标、能截一次图"
echo "  3) 走一次 GIF 录制（选区 → 摄影机按钮 → 选 GIF → 开始 → 停止）"
echo "  4) diskutil eject \"/Volumes/anShot ${VERSION}\" 卸载镜像"
