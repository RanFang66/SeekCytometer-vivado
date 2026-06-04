#*****************************************************************************************
# build.tcl —— 手写、稳定的工程构建入口。请勿用 write_project_tcl 覆盖本文件。
#
# 用法（Vivado 2023.1 Tcl 控制台，任意目录均可）:
#     source <repo>/scripts/build.tcl
#
# 设计哲学：Vivado 工程本身是一次性产物，全部生成在 build/（已 gitignore）。
# git 里只保存真正的源：scripts/recreate_bd.tcl（BD）、constraints/*.xdc、
# ip_repo/、interfaces/。改完设计后只需 write_bd_tcl 重新导出 recreate_bd.tcl。
#*****************************************************************************************

set script_dir [file dirname [file normalize [info script]]]   ;# 自定位，与当前工作目录无关
set repo_dir   [file normalize "$script_dir/.."]
set proj_name  seek_cytometer
set proj_dir   "$repo_dir/build/$proj_name"
set part       xczu2cg-sfvc784-1-e

# 1) 在一次性的 build/ 目录里重建工程（仅含再生产物，-force 在此安全）
file mkdir "$repo_dir/build"
create_project $proj_name $proj_dir -part $part -force

# 2) 构建 BD 前，必须先把自定义 IP 仓库挂到 IP catalog
set_property ip_repo_paths [list \
  "$repo_dir/ip_repo/signal_analyzer_1_0" \
  "$repo_dir/ip_repo/ad_sample_1_0" \
  "$repo_dir/interfaces"] [current_project]
update_ip_catalog -rebuild

# 3) 由生成脚本重建 BD（覆盖 recreate_bd.tcl 默认的 origin_dir，让 .bd 落在本工程内）
set ::origin_dir_loc "$proj_dir/$proj_name.srcs/sources_1/bd"
source "$script_dir/recreate_bd.tcl"

# 4) 生成 wrapper 并设为 top
make_wrapper -files [get_files cytometer_platform.bd] -top -import
set_property top cytometer_platform_wrapper [get_filesets sources_1]

# 5) 加入约束
add_files -fileset constrs_1 -norecurse [glob "$repo_dir/constraints/*.xdc"]
set_property target_constrs_file "$repo_dir/constraints/debug_core.xdc" [get_filesets constrs_1]

puts "INFO: 工程已重建于 $proj_dir"
