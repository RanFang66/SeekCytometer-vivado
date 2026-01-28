# 工程重建说明

## 从Git克隆后重建工程

### 方法1: 使用 .xpr 文件直接打开

```tcl
# 在 Vivado 中
open_project seek_cytometer/seek_cytometer.xpr

# 更新IP仓库路径
set_property ip_repo_paths [list \
    [file normalize "../ip_repo"] \
    [file normalize "../interfaces"]] [current_project]
update_ip_catalog

# 如有需要，升级IP
report_ip_status
upgrade_ip [get_ips]
```

### 方法2: 使用 TCL 脚本重建（推荐）

```tcl
source scripts/create_project.tcl
```

## 导出 TCL 脚本

每次修改工程后，建议导出TCL脚本：

```tcl
write_project_tcl -force scripts/create_project.tcl
```

## 导出 Block Design

```tcl
write_bd_tcl -force scripts/recreate_bd.tcl
```
