#!/bin/bash
# ==========================================
# Vivado 工程清理脚本 (Linux/macOS)
# 用于 Git 提交前清理生成文件
# 脚本位置: scripts/clean_vivado.sh
# ==========================================

set -e

# 获取脚本所在目录，然后定位到工程根目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 工程目录名称
PROJECT_NAME="seek_cytometer"
PROJECT_PATH="$PROJECT_ROOT/$PROJECT_NAME"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Vivado 工程清理脚本"
echo "=========================================="
echo "脚本位置: $SCRIPT_DIR"
echo "工程根目录: $PROJECT_ROOT"
echo "工程目录: $PROJECT_PATH"

# 检查工程目录是否存在
if [ ! -d "$PROJECT_PATH" ]; then
    echo -e "${RED}错误: 未找到 $PROJECT_PATH 目录${NC}"
    exit 1
fi

# 显示当前占用空间
echo ""
echo -e "${YELLOW}清理前空间占用:${NC}"
du -sh "$PROJECT_PATH" 2>/dev/null || echo "无法计算大小"

echo ""
echo -e "${YELLOW}将要删除的目录和文件:${NC}"
echo "  - $PROJECT_NAME/$PROJECT_NAME.cache/"
echo "  - $PROJECT_NAME/$PROJECT_NAME.gen/"
echo "  - $PROJECT_NAME/$PROJECT_NAME.hw/"
echo "  - $PROJECT_NAME/$PROJECT_NAME.runs/"
echo "  - $PROJECT_NAME/$PROJECT_NAME.sim/"
echo "  - $PROJECT_NAME/$PROJECT_NAME.tmp/"
echo "  - $PROJECT_NAME/$PROJECT_NAME.ip_user_files/"
echo "  - $PROJECT_NAME/.Xil/"
echo "  - 日志文件 (*.log, *.jou)"
echo "  - 二进制产物 (*.bit, *.dcp, *.ltx, *.xsa)"

echo ""
read -p "确认删除这些文件? (y/n): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "已取消"
    exit 0
fi

echo ""
echo -e "${GREEN}开始清理...${NC}"

# 删除生成目录
echo "[1/7] 删除 cache 目录..."
rm -rf "$PROJECT_PATH/$PROJECT_NAME.cache"

echo "[2/7] 删除 gen 目录..."
rm -rf "$PROJECT_PATH/$PROJECT_NAME.gen"

echo "[3/7] 删除 hw 目录..."
rm -rf "$PROJECT_PATH/$PROJECT_NAME.hw"

echo "[4/7] 删除 runs 目录..."
rm -rf "$PROJECT_PATH/$PROJECT_NAME.runs"

echo "[5/7] 删除 sim 目录..."
rm -rf "$PROJECT_PATH/$PROJECT_NAME.sim"

echo "[6/7] 删除 tmp 目录..."
rm -rf "$PROJECT_PATH/$PROJECT_NAME.tmp"

echo "[7/7] 删除其他生成文件..."
rm -rf "$PROJECT_PATH/$PROJECT_NAME.ip_user_files"
rm -rf "$PROJECT_PATH/.Xil"

# 删除日志文件
find "$PROJECT_PATH" -name "*.log" -type f -delete 2>/dev/null || true
find "$PROJECT_PATH" -name "*.jou" -type f -delete 2>/dev/null || true
find "$PROJECT_PATH" -name "*.str" -type f -delete 2>/dev/null || true
find "$PROJECT_PATH" -name "*.backup.*" -type f -delete 2>/dev/null || true

# 删除二进制产物（在主目录下的）
find "$PROJECT_PATH" -maxdepth 1 -name "*.bit" -type f -delete 2>/dev/null || true
find "$PROJECT_PATH" -maxdepth 1 -name "*.ltx" -type f -delete 2>/dev/null || true
find "$PROJECT_PATH" -maxdepth 1 -name "*.xsa" -type f -delete 2>/dev/null || true
find "$PROJECT_PATH" -maxdepth 1 -name "ip_upgrade.log" -type f -delete 2>/dev/null || true

# 显示清理后空间
echo ""
echo -e "${GREEN}清理完成!${NC}"
echo ""
echo -e "${YELLOW}清理后空间占用:${NC}"
du -sh "$PROJECT_PATH" 2>/dev/null || echo "无法计算大小"

echo ""
echo "现在可以进行 Git 提交了:"
echo "  cd $PROJECT_ROOT"
echo "  git add -A"
echo "  git commit -m \"your message\""