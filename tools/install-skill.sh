#!/usr/bin/env bash
#
# install-skill.sh —— 把仓库内的 skill 安装到**全局** skill 目录
#
# ── 它解决什么 ────────────────────────────────────────────────
#
#   skill 放在仓库的 `.agents/skills/` 下是**项目级**的：只有在该项目里
#   打开的会话才看得到它，而 agent 一旦在别处工作就用不上「截图看一眼」的能力。
#
#   本脚本把 `skills/<name>/` 的内容**实体复制**到 `~/.agents/skills/<name>/`，
#   使它对所有项目生效。
#
# ── 为什么必须是实体复制，而不是符号链接回仓库 ─────────────────
#
#   两条都踩过：
#     1. 软链回仓库时，skill 只在仓库存在且路径不变的前提下可用；
#     2. 更麻烦的是「项目级覆盖」——仓库里若同时留着 `.agents/skills/<name>/`，
#        宿主会优先把它当成项目级 skill（location=project），
#        全局那一份形同不存在。
#
#   所以：**仓库不保留 `.agents/skills/`**，skill 的唯一事实源是 `skills/`，
#   由本脚本同步到全局。改完 SKILL.md 重新跑一次即可。
#
# ── 用法 ──────────────────────────────────────────────────────
#
#   tools/install-skill.sh                    # 安装到 ~/.agents/skills
#   tools/install-skill.sh --target /tmp/sk   # 指定目标根目录（测试用）
#   tools/install-skill.sh --list             # 只看会安装什么，不写盘
#
#   安装后需要**重开会话**：skill 列表在会话启动时读取。

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
while [ -L "${SELF}" ]; do
    _target="$(readlink "${SELF}")"
    case "${_target}" in
        /*) SELF="${_target}" ;;
        *)  SELF="$(dirname "${SELF}")/${_target}" ;;
    esac
done
REPO_ROOT="$(cd -P "$(dirname "${SELF}")/.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/skills"

TARGET_ROOT="${HOME}/.agents/skills"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            [ $# -ge 2 ] || { echo "✗ --target 缺少值" >&2; exit 2; }
            TARGET_ROOT="$2"
            shift 2
            ;;
        --list|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "✗ 未知参数：$1（可用 --target / --list / --help）" >&2
            exit 2
            ;;
    esac
done

if [ ! -d "${SOURCE_DIR}" ]; then
    echo "✗ 找不到 skill 源目录：${SOURCE_DIR}" >&2
    exit 1
fi

# 声明式的宿主侧软链目录。
# 只在**已经存在**的宿主目录里建链：不替用户创建他从没用过的 agent 目录，
# 否则 ~/.claude / ~/.codex 会被这个脚本凭空造出来，而用户根本没装那些工具。
HOST_LINK_DIRS=(
    "${HOME}/.claude/skills"
    "${HOME}/.codex/skills"
)

installed=0

for skill_dir in "${SOURCE_DIR}"/*/; do
    [ -d "${skill_dir}" ] || continue
    name="$(basename "${skill_dir}")"

    if [ ! -f "${skill_dir}SKILL.md" ]; then
        echo "⚠ 跳过 ${name}：目录里没有 SKILL.md" >&2
        continue
    fi

    dest="${TARGET_ROOT}/${name}"

    if [ "${DRY_RUN}" = true ]; then
        echo "会安装：${skill_dir}  →  ${dest}"
        installed=$((installed + 1))
        continue
    fi

    # 先清空目标：它可能是一个指向别处的**旧软链**（本仓库早期就是软链回仓库），
    # 直接复制会写进软链指向的目录，而不是替换软链本身。
    # `${dest:?}` 保证变量非空时才执行 rm -rf——这条命令的破坏面太大，
    # 不允许它在任何「变量意外为空」的情形下被解释成 `rm -rf /`。
    if [ -e "${dest}" ] || [ -L "${dest}" ]; then
        rm -rf "${dest:?}"
    fi

    mkdir -p "${dest}"
    cp -R "${skill_dir}." "${dest}/"

    echo "✓ 已安装 ${name} → ${dest}"
    installed=$((installed + 1))

    # 宿主侧软链：指向全局那一份（而不是仓库），仓库搬走也不影响。
    for host_dir in "${HOST_LINK_DIRS[@]}"; do
        [ -d "${host_dir}" ] || continue

        link="${host_dir}/${name}"
        if [ -e "${link}" ] && [ ! -L "${link}" ]; then
            echo "  ⚠ ${link} 是实体目录而非软链，已跳过（请自行确认它是否重复）" >&2
            continue
        fi

        ln -sfn "${dest}" "${link}"
        echo "  ↳ 已建立软链 ${link}"
    done
done

if [ "${installed}" -eq 0 ]; then
    echo "⚠ ${SOURCE_DIR} 下没有可安装的 skill" >&2
    exit 1
fi

if [ "${DRY_RUN}" = false ]; then
    echo
    echo "完成：${installed} 个 skill 已安装到 ${TARGET_ROOT}"
    echo "注意：skill 列表在**会话启动时**读取，请重开一个会话让它生效。"
fi
