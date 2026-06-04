# 工程管理与重建说明

## 设计原则

Vivado 工程本身是**一次性产物**，全部生成在 `build/`（已 gitignore），可随时删除重建。
git 里只保存**真正的源**：

| 源 | 位置 | 说明 |
|---|---|---|
| Block Design | `scripts/recreate_bd.tcl` | 由 `write_bd_tcl` 自动导出，脚本自身健壮 |
| 约束 | `constraints/*.xdc` | debug_core / sorter / ad7606 |
| 自定义 IP | `ip_repo/` | signal_analyzer、ad_sample |
| 接口定义 | `interfaces/` | ad7606c_port 等 |
| 构建入口 | `scripts/build.tcl` | **手写、稳定，请勿用 write_project_tcl 覆盖** |

> ⚠️ 不要再使用 `write_project_tcl` / `create_project.tcl`。它生成的 `create_project ... ./seek_cytometer`
> 会把工程建到源码目录、配合 `-force` 删除源码，且每次导出都会复发路径问题。构建入口固定用
> `scripts/build.tcl`。

## 从 Git 克隆后重建工程

在 Vivado 2023.1 的 Tcl 控制台（任意工作目录均可）：

```tcl
source <repo>/scripts/build.tcl
```

工程会生成在 `<repo>/build/seek_cytometer/`，源码全程只读引用，绝不会被改动。

## 修改设计后如何更新版本库

1. 在 GUI 里编辑设计（工程在 `build/`，可随意改、随意删重建）；
2. 改完后**只需重新导出 BD**：

   ```tcl
   write_bd_tcl -force <repo>/scripts/recreate_bd.tcl
   ```
3. 若新增/修改了约束，保存到 `constraints/`；
4. 提交 `scripts/recreate_bd.tcl` 与 `constraints/`，**不要提交 `build/`**。

## 清理生成文件

```bash
scripts/clean_vivado.sh      # Linux/macOS
scripts\clean_vivado.bat     # Windows
scripts\clean_vivado.ps1     # PowerShell
```

效果等同于删除整个 `build/`。
