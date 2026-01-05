#!/usr/bin/env bash

# 檢查 CIVIT_API 是否已設定
if [ -z "$CIVIT_API" ]; then
  echo "錯誤：環境變數 CIVIT_API 尚未設定！"
  echo "請先執行：export CIVIT_API=<你的 Civitai API Key>"
  exit 1
fi

# 檢查是否至少有一個參數（URL）
if [ $# -lt 1 ]; then
  echo "用法：CIVIT_Download.sh <URL1> [URL2] [URL3] ..."
  echo "範例："
  echo "  CIVIT_Download.sh 'https://civitai.com/api/download/models/1111838?type=Model&format=SafeTensor' \\"
  echo "                     'https://civitai.com/api/download/models/2222222?type=Model&format=SafeTensor'"
  exit 1
fi

# 逐一處理每個引數(URL)
for DOWNLOAD_URL in "$@"; do
  echo "—————"
  echo "開始下載：$DOWNLOAD_URL"
  
  # 用 curl 帶 Authorization 標頭下載
  curl -L \
    -H "Authorization: Bearer $CIVIT_API" \
    -H "Content-Type: application/json" \
    -J -O \
    "$DOWNLOAD_URL"
  
  if [ $? -ne 0 ]; then
    echo "下載失敗：(URL: $DOWNLOAD_URL)"
  else
    echo "下載成功！(URL: $DOWNLOAD_URL)"
  fi
done

echo "全部下載完成。"
