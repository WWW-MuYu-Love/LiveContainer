# copy lc
wget https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify
chmod +x dylibify
brew install ldid

# move lc to working folder
mv "$archive_path.xcarchive/Products/Applications" Payload

# 瘦身：删掉 Payload 里所有 Mach-O 的本地符号（-S 保留导出符号、-x 删
# 本地符号）。本地符号表运行时用不到，功能不变；单个文件失败不中断打包。
find Payload -type f | while IFS= read -r f; do
  if file "$f" | grep -q "Mach-O"; then
    strip -S -x "$f" 2>/dev/null || true
  fi
done

# temporarily move sidestore support framrwork to tmp before zip
mkdir tmp
mv Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework ./tmp

zip -9 -r "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"

# —— 二合一版（+SideStore）已废弃（Campbell 2026-11-06 令）——
# 原来在本步之后还有：还原 SideStoreSupport.framework、给
# Info.plist 塞 SideStore 键、下载 SideStore nightly 拼装成
# SideStoreApp.framework、打第二个包 $scheme+SideStore.ipa。
# 现在只构建、只发布单版本，上面的单包 zip 即最终产物，
# 后续步骤全部删除。SideStoreSupport.framework 留在 tmp 里
# 不还原（单版本本来就不带它，与旧单包一致）。
