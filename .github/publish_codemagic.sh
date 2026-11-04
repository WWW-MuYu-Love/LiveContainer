#!/bin/bash
# Codemagic 构建完成后自动发版到 GitHub（MuYu-Blog/LiveContainer-zh）。
# 与 GitHub Actions 的 nightly 发布保持同一套规矩：
# 1) 刷新滚动 release「update」：正文首行 **Commit:** [sha]（App 内
#    更新检查靠它比对版本）、两个 IPA 附件、apps_nightly.json；
# 2) release「1.0」的 apps_ss_lc.json 同步替换（AltStore 源）；
# 3) 正式版 release（tag = Info.plist 版本号）：不存在则创建并设
#    为 Latest，已存在则只换两个 IPA 附件（幂等，可重复跑）。
# 需要环境变量 GH_TOKEN（在 Codemagic 里配的加密变量；细粒度
# PAT，只有本仓库 Contents 写权限）。未设置时跳过并以成功退出，
# 不让发版配置缺失拖垮构建产物本身。
set -uo pipefail

if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN 未设置，跳过自动发版（IPA 仍在 Codemagic artifacts 里）"
  exit 0
fi

export REPO="MuYu-Blog/LiveContainer-zh"
API="https://api.github.com/repos/$REPO"
UPLOADS="https://uploads.github.com/repos/$REPO"
AUTH=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

# 先普通赋值再统一 export：macOS 自带 bash 3.2 下，
# export VAR=$(...) 的命令替换一旦失败，变量会保持未绑定，
# 后面 set -u 展开时直接报 unbound variable（构建 #5 实测
# 死在这里）。git log 加 || true 兜底，MSG 再给默认文案。
SHA=$(git rev-parse HEAD)
MSG=$(git log -1 --pretty=%s || true)
MSG=${MSG:-"（无提交信息）"}
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" LiveContainer/Info.plist)
BUILD_LINK="${CM_BUILD_URL:-https://codemagic.io}"
export SHA MSG VER BUILD_LINK
echo "发版目标：$REPO 版本 $VER 提交 ${SHA:0:7}（$MSG）"

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
export commit_msg="$MSG"
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
body = f\"**Commit:** [{sha}](https://github.com/{os.environ['REPO']}/commit/{sha})\n**Message:** {msg}\n\nThis is an update release [created automatically with Codemagic workflow]({os.environ['BUILD_LINK']}).\"
print(json.dumps({'body': body}))")
curl -sf -X PATCH "${AUTH[@]}" "$API/releases/$UID_REL" -d "$BODY_JSON" >/dev/null
replace_assets "$UID_REL" "LiveContainer.ipa" "LiveContainer+SideStore.ipa" ".github/apps_nightly.json"
echo "update release 已刷新"

# ---- 2) release「1.0」的 apps_ss_lc.json
OID_REL=$(release_id "1.0")
if [ -n "$OID_REL" ]; then
  replace_assets "$OID_REL" ".github/apps_ss_lc.json"
  echo "1.0 release 的 apps_ss_lc.json 已更新"
fi

# ---- 3) 正式版 release
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
replace_assets "$FID_REL" "LiveContainer.ipa" "LiveContainer+SideStore.ipa"
echo "正式版 $VER 已发布：https://github.com/$REPO/releases/tag/$VER"
