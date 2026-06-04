#!/bin/bash
# ==========================================
# Vivado 工程清理脚本 (Linux/macOS)
# 工程现在整体生成在 build/（一次性产物），清理即删除 build/。
# 脚本位置: scripts/clean_vivado.sh
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "=========================================="
echo "Vivado 工程清理脚本"
echo "=========================================="
echo "工程根目录: $PROJECT_ROOT"
echo "构建目录:   $BUILD_DIR"

if [ ! -d "$BUILD_DIR" ]; then
    echo -e "${YELLOW}build/ 不存在，无需清理。${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}清理前空间占用:${NC}"
du -sh "$BUILD_DIR" 2>/dev/null || echo "无法计算大小"

echo ""
echo -e "${YELLOW}将要删除整个 build/ 目录（可由 scripts/build.tcl 重新生成）${NC}"
read -p "确认删除? (y/n): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
fi

echo -e "${GREEN}开始清理...${NC}"
rm -rf "$BUILD_DIR"

# 顺带清理根目录下 Vivado 偶尔遗留的日志
find "$PROJECT_ROOT" -maxdepth 1 \( -name "*.log" -o -name "*.jou" -o -name "*.str" \) -type f -delete 2>/dev/null || true

echo -e "${GREEN}清理完成! 用 'source scripts/build.tcl' 可随时重建工程。${NC}"
