#!/usr/bin/env bash
# 本地预览 Hugo 博客。用法： ./serve.sh
set -e
cd "$(dirname "$0")"

if ! command -v hugo >/dev/null 2>&1; then
    echo "未检测到 hugo，正在用 Homebrew 安装 hugo(extended)…"
    if ! command -v brew >/dev/null 2>&1; then
        echo "没有 Homebrew。请先安装： https://brew.sh ，或手动安装 hugo。"
        exit 1
    fi
    brew install hugo
fi

# 确保主题 submodule 已拉取
git submodule update --init --recursive

echo "启动中… 打开 http://localhost:1313/"
hugo server -D --bind 0.0.0.0 --port 1313
