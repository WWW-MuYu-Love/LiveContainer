#!/bin/bash
# Codemagic 构建完成后自动发版到 GitHub（MuYu-Blog/LiveContainer-zh）。
# 只发布单版本（Campbell 2026-11-06 令：二合一版废弃）：
# 1) 刷新滚动 release「update」：正文首行 **Commit:** [sha]（App 内
#    更新检查靠它比对版本）、LiveContainer.ipa、apps_nightly.json，
#    并清掉该 release 上残留的 SideStore 包（存量二合一装机从此
#    更新到单版本）；
# 2) 正式版 release（tag = Info.plist 版本号）：不存在则创建并设
#    为 Latest，已存在则只换 LiveContainer.ipa 附件（幂等，可重
#    复跑），同样清残留的 SideStore 包。
# （原第 2 步「release 1.0 的 apps_ss_lc.json 同步」是二合一版的
# AltStore 源，随二合一废弃一并停止。）
# 需要环境变量 GH_TOKEN（在 Codemagic 里配的加密变量；细粒度
# PAT，只有本仓库 Contents 写权限）。未设置时跳过并以成功退出，
# 不让发版配置缺失拖垮构建产物本身。
set -o pipefail
# 注意：故意不开 set -u。构建 #5/#6/#8/#9 四次都死在
# 「MSG: unbound variable」，且每次失败行都是展开 $MSG 的
# echo——尽管脚本在前面已给 MSG 绑了默认值（#8/#9 的脚本
# 第 31 行就有 MSG="（无提交信息）"，本地与远端逐字节一致，
# 本地 bash 5.2 实测该段运行正常）。runner 上为何仍报未绑定
# 始终未能实证（Codemagic 日志只有那一行报错，无其他输出）。
# 结论：不再试图满足 set -u，直接撤掉 nounset——没有 set -u
# 就不可能再出现 unbound variable 这一类失败；关键变量另在
# 展开处加 ${VAR:-} 兜底，逻辑不依赖 set -u。

if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN 未设置，跳过自动发版（IPA 仍在 Codemagic artifacts 里）"
  exit 0
fi

export REPO="MuYu-Blog/LiveContainer-zh"
API="https://api.github.com/repos/$REPO"
UPLOADS="https://uploads.github.com/repos/$REPO"
AUTH=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

# 变量先全部给默认值再逐个赋值；提交号优先用 Codemagic
# 自带的 CM_COMMIT，git 只作兜底（git 在 Codemagic 检出
# 目录可能因 dubious ownership 不可用）。
SHA=""
MSG="（无提交信息）"
VER=""
BUILD_LINK="https://codemagic.io"
SHA=${CM_COMMIT:-$(git rev-parse HEAD 2>/dev/null || true)}
GIT_MSG=$(git log -1 --pretty=%s 2>/dev/null || true)
if [ -n "$GIT_MSG" ]; then MSG="$GIT_MSG"; fi
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" LiveContainer/Info.plist 2>/dev/null || true)
if [ -z "$VER" ]; then
  VER=$(grep -A1 CFBundleShortVersionString LiveContainer/Info.plist | grep -o '[0-9][0-9.]*' | head -1 || true)
fi
BUILD_LINK="${CM_BUILD_URL:-https://codemagic.io}"
export SHA MSG VER BUILD_LINK
echo "发版目标：$REPO 版本 ${VER:-} 提交 ${SHA:0:7}（${MSG:-（无提交信息）}）"

release_id() {
  curl -s "${AUTH[@]}" "$API/releases/tags/$1" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('id',''))
except Exception:
    print('')"
}

delete_asset_if_exists() {
  local rid="$1" name="$2" aid
  aid=$(curl -s "${AUTH[@]}" "$API/releases/$rid/assets" | ASSET_NAME="$name" python3 -c "import json,os,sys
name = os.environ['ASSET_NAME']
try:
    for a in json.load(sys.stdin):
        if a.get('name') == name:
            print(a['id']); break
except Exception:
    pass")
  if [ -n "$aid" ]; then
    echo "删除旧附件 $name（asset $aid）"
    curl -s -X DELETE "${AUTH[@]}" "$API/releases/assets/$aid" >/dev/null
  fi
}

# 删掉某个 release 上所有名字含指定子串的附件（发版清理用：
# 二合一废弃后，把 update/正式版上残留的 SideStore 包清掉；
# 每次发版都跑，幂等、无残留时无操作）。
delete_assets_matching() {
  local rid="$1" substr="$2"
  curl -s "${AUTH[@]}" "$API/releases/$rid/assets" | ASSET_SUBSTR="$substr" python3 -c "import json,os,sys
substr = os.environ['ASSET_SUBSTR']
try:
    for a in json.load(sys.stdin):
        if substr in (a.get('name') or ''):
            print(a['id'])
except Exception:
    pass" | while read -r aid; do
    if [ -n "$aid" ]; then
      echo "清理残留附件（asset $aid）"
      curl -s -X DELETE "${AUTH[@]}" "$API/releases/assets/$aid" >/dev/null
    fi
  done
}

upload_asset() {
  local rid="$1" file="$2" name
  name=$(basename "$file")
  echo "上传 $name → release $rid"
  curl -sf -X POST "${AUTH[@]}" -H "Content-Type: application/octet-stream" \
    --data-binary @"$file" "$UPLOADS/releases/$rid/assets?name=$name" >/dev/null
}

replace_assets() {
  local rid="$1"; shift
  local f
  for f in "$@"; do
    delete_asset_if_exists "$rid" "$(basename "$f")"
    upload_asset "$rid" "$f"
  done
}

# ---- 0) 生成 AltStore 源 JSON（与 GitHub nightly 同一步，失败不阻断发版）
export NIGHTLY_LINK="$BUILD_LINK"
export commit_sha="$SHA"
export commit_msg="${MSG:-（无提交信息）}"
export GITHUB_TOKEN="$GH_TOKEN"
python3 -m pip install --quiet requests 2>/dev/null || true
python3 .github/update_json.py || echo "警告：update_json.py 失败，apps_nightly.json 用仓库内现版"

# ---- 1) 滚动 release「update」
UID_REL=$(release_id "update")
if [ -z "$UID_REL" ]; then
  echo "找不到 update release，新建一个"
  UID_REL=$(curl -sf -X POST "${AUTH[@]}" "$API/releases" \
    -d '{"tag_name":"update","name":"update","prerelease":true,"body":""}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")
fi
BODY_JSON=$(python3 -c "import json,os
sha = os.environ['SHA']; msg = os.environ['MSG']
body = f\"**Commit:** [{sha}](https://github.com/{os.environ['REPO']}/commit/{sha})\n**Version:** {os.environ['VER']}\n**Message:** {msg}\n\nThis is an update release [created automatically with Codemagic workflow]({os.environ['BUILD_LINK']}).\"
print(json.dumps({'body': body}))")
curl -sf -X PATCH "${AUTH[@]}" "$API/releases/$UID_REL" -d "$BODY_JSON" >/dev/null
replace_assets "$UID_REL" "LiveContainer.ipa" ".github/apps_nightly.json"
delete_assets_matching "$UID_REL" "SideStore"
echo "update release 已刷新"

# ---- 2) 正式版 release
FID_REL=$(release_id "$VER")
if [ -z "$FID_REL" ]; then
  echo "创建正式版 release $VER"
  CREATE_JSON=$(python3 -c "import json,os
sha = os.environ['SHA']
print(json.dumps({'tag_name': os.environ['VER'], 'name': os.environ['VER'],
  'body': f'**Commit:** [{sha}](https://github.com/{os.environ[\"REPO\"]}/commit/{sha})\n\n由 Codemagic 自动构建发布。',
  'draft': False, 'prerelease': False, 'make_latest': 'true'}))")
  FID_REL=$(curl -sf -X POST "${AUTH[@]}" "$API/releases" -d "$CREATE_JSON" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")
fi
replace_assets "$FID_REL" "LiveContainer.ipa"
delete_assets_matching "$FID_REL" "SideStore"
echo "正式版 $VER 已发布：https://github.com/$REPO/releases/tag/$VER"
