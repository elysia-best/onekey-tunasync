#!/bin/bash
# ==================================================
# tunasync 引导式安装与管理脚本
# ==================================================

# ================= 配置变量 =================
RUN_USER="tuansyncer"
RUN_GROUP="www"
RUN_USER_HOME="/data/${RUN_USER}"
MIRROR_DIR="/data/mirrors"
LOG_DIR="/data/log"
CONF_DIR="/etc/tunasync"
BIN_DIR="/usr/local/bin"

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本！"
  exit 1
fi

function install_env() {
    echo "================开始安装 tunasync 运行环境================"
    
    echo "正在安装必要依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl wget jq ca-certificates rsync
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget jq ca-certificates rsync
    else
        echo "未找到受支持的包管理器 (apt-get/yum)，请确保已安装 curl wget jq rsync"
    fi
    
    echo "正在创建用户与目录..."
    if ! getent group "${RUN_GROUP}" >/dev/null; then groupadd "${RUN_GROUP}"; fi
    if ! getent passwd "${RUN_USER}" >/dev/null; then useradd -r -s /bin/bash -g "${RUN_GROUP}" -d "${RUN_USER_HOME}" "${RUN_USER}"; fi
    if [ ! -d "${RUN_USER_HOME}" ]; then mkdir -p "${RUN_USER_HOME}"; chown ${RUN_USER}:${RUN_GROUP} "${RUN_USER_HOME}"; fi
    
    mkdir -p "${MIRROR_DIR}" "${LOG_DIR}" "${CONF_DIR}"
    chown -R ${RUN_USER}:${RUN_GROUP} "${MIRROR_DIR}" "${LOG_DIR}" "${CONF_DIR}"
    chmod -R 775 "${MIRROR_DIR}" "${LOG_DIR}"
    
    echo "正在下载 tunasync 核心组件..."
    RELEASE_DATA=$(curl -s https://api.github.com/repos/tuna/tunasync/releases/latest)
    DOWNLOAD_URL=$(echo "$RELEASE_DATA" | jq -r '.assets[] | select(.name | test("linux-amd64-bin.tar.gz$|linux-amd64.tar.gz$")) | .browser_download_url' | head -n 1)
    
    if [ -z "$DOWNLOAD_URL" ]; then echo "下载失败！"; return 1; fi
    
    wget -qO /tmp/tunasync.tar.gz "$DOWNLOAD_URL"
    tar -xzf /tmp/tunasync.tar.gz -C /tmp
    mv /tmp/tunasync ${BIN_DIR}/
    
    # 兼容可能存在的不同拼写 tunasyncctl 或 tunasynctl
    if [ -f "/tmp/tunasynctl" ]; then
        mv /tmp/tunasynctl ${BIN_DIR}/tunasynctl
        chmod +x ${BIN_DIR}/tunasync ${BIN_DIR}/tunasynctl
        ln -sf ${BIN_DIR}/tunasynctl ${BIN_DIR}/tunasyncctl
    elif [ -f "/tmp/tunasyncctl" ]; then
        mv /tmp/tunasyncctl ${BIN_DIR}/tunasyncctl
        chmod +x ${BIN_DIR}/tunasync ${BIN_DIR}/tunasyncctl
        ln -sf ${BIN_DIR}/tunasyncctl ${BIN_DIR}/tunasynctl
    fi
    
    rm -f /tmp/tunasync.tar.gz
    
    echo "配置 Manager 服务与控制台环境..."
    
    # Tunasyncctl 配置文件
    cat > ${CONF_DIR}/ctl.conf <<EOF
manager_addr = "127.0.0.1"
manager_port = 14242
ca_cert = ""
EOF
    chown ${RUN_USER}:${RUN_GROUP} ${CONF_DIR}/ctl.conf

    cat > ${CONF_DIR}/manager.conf <<EOF
debug = false
[server]
addr = "127.0.0.1"
port = 14242
[files]
db_type = "bolt"
db_file = "${MIRROR_DIR}/manager.db"
EOF
    
    cat > /etc/systemd/system/tunasync-manager.service <<EOF
[Unit]
Description=TUNA mirrors sync manager
After=network.target
Requires=network.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
ExecStart=${BIN_DIR}/tunasync manager --config ${CONF_DIR}/manager.conf --with-systemd
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    echo "生成默认 Worker 基础配置..."
    cat > ${CONF_DIR}/worker.conf <<EOF
[global]
name = "main_worker"
log_dir = "${LOG_DIR}/{{.Name}}"
mirror_dir = "${MIRROR_DIR}"
concurrent = 10
interval = 120

[docker]
enable = true

[manager]
api_base = "http://127.0.0.1:14242"
token = ""
ca_cert = ""

[cgroup]
enable = false
base_path = "/sys/fs/cgroup"
group = "tunasync"

[server]
hostname = "localhost"
listen_addr = "127.0.0.1"
listen_port = 16010
ssl_cert = ""
ssl_key = ""

# 镜像配置将在此后自动追加...
EOF

    chown ${RUN_USER}:${RUN_GROUP} ${CONF_DIR}/worker.conf

    cat > /etc/systemd/system/tunasync-worker.service <<EOF
[Unit]
Description=TUNA mirrors sync worker
After=network.target tunasync-manager.service
Requires=tunasync-manager.service

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
PermissionsStartOnly=true
ExecStart=${BIN_DIR}/tunasync worker --config ${CONF_DIR}/worker.conf --with-systemd
ExecReload=/bin/kill -SIGHUP \$MAINPID
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tunasync-manager --now
    systemctl enable tunasync-worker --now
    echo "安装完成，Manager 与基础 Worker 已启动！"
}

function add_mirror() {
    echo "================添加镜像同步任务================"
    local conf_file="${CONF_DIR}/worker.conf"
    if [ ! -f "$conf_file" ]; then
        echo "未找到基础的 worker.conf，请先执行“安装 Tunasync 环境与 Manager 服务”。"
        return 1
    fi
    
    read -p "请输入要同步的镜像项目名称 (如 debian, centos 等): " mirror_name
    
    echo "请选择同步 Provider (1=rsync, 2=command, 默认 1):"
    read -p "选项 [1-2]: " provider_opt
    local provider="rsync"
    if [ "$provider_opt" == "2" ]; then
        provider="command"
    fi
    
    read -p "请输入同步源的上游地址 (URL, rsync或http): " upstream_url
    
    read -p "请输入同步间隔(分钟) (默认 1440): " interval_val
    interval_val=${interval_val:-1440}

    local command_str=""
    local docker_image=""
    if [ "$provider" == "command" ]; then
        read -p "请输入调用的外部命令或脚本路径: " command_str
        read -p "是否在 Docker 中运行? 是则输入镜像名(如 tunathu/tunasync-scripts), 否则回车跳过: " docker_image
    fi
    
    # 备份配置文件以防万一
    cp "${conf_file}" "${conf_file}.bak_$(date +%s)"

    # 追加到 worker.conf
    cat >> ${conf_file} <<EOF

[[mirrors]]
name = "${mirror_name}"
provider = "${provider}"
upstream = "${upstream_url}"
interval = ${interval_val}
EOF

    if [ "$provider" == "command" ]; then
        echo "command = \"${command_str}\"" >> ${conf_file}
        if [ -n "$docker_image" ]; then
            echo "docker_image = \"${docker_image}\"" >> ${conf_file}
        fi
    fi

    # 追加示例注释（可用于定制高级用法）
    cat >> ${conf_file} <<EOF

# =========================================================
# 【高级配置示例】（根据需要取消注释并修改相应的配置即可生效）
# retry = 3                       # 失败重试次数
# timeout = 120                   # 超时时间(分钟)
# role = "master"                 # 同步角色 (master 或 slave)
# use_ipv4 = true                 # 强制使用 IPv4 (常用于 rsync)
# use_ipv6 = false                # 强制使用 IPv6
# success_exit_codes = [0, 24]    # 哪些进程退出码视为同步成功
# exec_on_success = ["/bin/notify_success.sh"]        # 成功时执行钩子
# exec_on_failure_extra = ["/bin/notify_failure.sh"]  # 失败时执行钩子
# memory_limit = "512M"           # 内存占用限制 (CGroup功能)
#
# 对于 Provider: command 还支持:
# size_pattern = "size-sum: ([0-9\\\\.]+[KMGTP]?)"
# fail_on_match = "sync failed error"
# docker_volumes = ["/etc/ssl:/etc/ssl:ro"]
#
# [mirrors.env]                   # 自定义环境变量传给同步脚本
# CUSTOM_VAR = "value"
# =========================================================
EOF

    chown ${RUN_USER}:${RUN_GROUP} ${conf_file}
    
    echo "配置已追加至 ${conf_file}。"
    echo "正在重启 Worker 以应用新配置..."
    systemctl restart tunasync-worker
    echo "镜像 [${mirror_name}] 添加成功！"
}

function manage_workers() {
    echo "================Worker 状态管理================"
    echo "当前 Worker 服务运行状态:"
    systemctl status tunasync-worker --no-pager | head -n 10
    echo ""
    echo "使用 tunasyncctl 查看已加载的任务节点详情:"
    ${BIN_DIR}/tunasyncctl list --all || echo "tunasyncctl 尚无法获取任务数据"
    echo "================================================="
}

function manual_sync() {
    echo "================手动触发镜像同步================"
    read -p "请输入相关的 Worker 名称 (敲回车使用默认: main_worker): " worker_name
    worker_name=${worker_name:-main_worker}
    
    read -p "请输入要触发同步的镜像项目名称 (如 debian): " mirror_name
    
    if [ -z "$mirror_name" ]; then
        echo "错误：镜像名称不能为空。"
        return 1
    fi
    
    echo "正在发送手动触发指令..."
    ${BIN_DIR}/tunasynctl start -w "${worker_name}" "${mirror_name}"
    echo "触发请求已发送。请稍后使用状态查看选项观察变化。"
}

function manage_mirror_tasks() {
    while true; do
        echo ""
        echo "================ 镜像任务跟踪与管理 ================"
        local conf_file="${CONF_DIR}/worker.conf"
        if [ ! -f "$conf_file" ]; then
            echo "错误: $conf_file 不存在，请先安装。环境不完整。"
            return 1
        fi
        
        # 提取已配置的名称
        local mirrors=($(grep -E '^name\s*=' "$conf_file" | grep -v 'name = "main_worker"' | awk -F'"' '{print $2}'))
        
        if [ ${#mirrors[@]} -eq 0 ]; then
            echo "当前未配置任何附加的镜像任务 (未发现配置列表)。"
        else
            echo "当前记录在脚本中的配置列表："
            local i=1
            for m in "${mirrors[@]}"; do
                echo "  ${i}) $m"
                let i++
            done
        fi
        echo "-------------------------------------------"
        echo "操作选项："
        echo "  [s] 暂停/停止某项任务 (disable & flush)"
        echo "  [r] 恢复/重新启动某项任务 (enable & start)"
        echo "  [d] 彻底删除某项任务并清理配置文件"
        echo "  [x] 注销整个 Worker 节点调度"
        echo "  [q] 返回上级主菜单"
        read -p "请输入您的操作 [s/r/d/x/q]: " action
        
        case "$action" in
            q|Q) return ;;
            x|X)
                read -p "请输入相关的 Worker 名称 (默认: main_worker): " worker_name
                worker_name=${worker_name:-main_worker}
                echo "正在注销 Worker [${worker_name}]..."
                ${BIN_DIR}/tunasynctl rm-worker -w "${worker_name}"
                echo "注销成功！(注意：本地 Worker 需要您退出后手动执行重启或卸载生效)"
                continue
                ;;
            s|S|r|R|d|D)
                if [ ${#mirrors[@]} -eq 0 ]; then
                     echo "暂无任务可以操作，请先通过菜单 2 添加！"
                     continue
                fi
                read -p "请选择相关的镜像任务序号 (1-${#mirrors[@]}): " idx
                if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#mirrors[@]}" ]; then
                    echo "无效的任务序号"
                    continue
                fi
                local target_mirror="${mirrors[$((idx-1))]}"
                local worker_name="main_worker"
                ;;
            *)
                echo "无效输入"
                continue
                ;;
        esac
        
        case "$action" in
            s|S)
                echo "正在停止任务 [${target_mirror}]..."
                ${BIN_DIR}/tunasynctl disable -w "${worker_name}" "${target_mirror}" 2>/dev/null
                ${BIN_DIR}/tunasynctl flush 2>/dev/null
                echo "操作完成！任务已置为被禁用且从缓存刷出。"
                ;;
            r|R)
                echo "正在启用并恢复任务同步 [${target_mirror}]..."
                ${BIN_DIR}/tunasynctl enable -w "${worker_name}" "${target_mirror}" 2>/dev/null
                ${BIN_DIR}/tunasynctl start -w "${worker_name}" "${target_mirror}" 2>/dev/null
                echo "操作完成！任务已成功触发恢复/重启信号。"
                ;;
            d|D)
                echo "1. 从系统调度中移除并停用..."
                ${BIN_DIR}/tunasynctl disable -w "${worker_name}" "${target_mirror}" 2>/dev/null
                ${BIN_DIR}/tunasynctl flush 2>/dev/null
                
                echo "2. 正在智能清理配置文件 ${conf_file}..."
                cp "${conf_file}" "${conf_file}.bak_rm_$(date +%s)"
                
                # 使用 awk 对块落进行自动安全删除处理
                awk -v target="${target_mirror}" '
                /^\[\[mirrors\]\]|^\[global\]|^\[manager\]|^\[server\]|^\[docker\]|^\[cgroup\]/ {
                    if ($0 ~ /^\[\[mirrors\]\]/) { block_type = "mirrors" } else { block_type = "other" }
                    if (buf != "") { if (!delete_block) print buf; }
                    buf = $0
                    delete_block = 0
                    next
                }
                {
                    if (block_type == "mirrors" && $0 ~ "^name\\s*=\\s*\"" target "\"") { delete_block = 1 }
                    if (buf != "") { buf = buf "\n" $0 } else { buf = $0 }
                }
                END { if (buf != "" && !delete_block) print buf; }
                ' "${conf_file}" > "${conf_file}.tmp"
                
                mv "${conf_file}.tmp" "${conf_file}"
                chown ${RUN_USER}:${RUN_GROUP} "${conf_file}"
                
                echo "3. 正在重新重载服务端配置使改变落地..."
                systemctl restart tunasync-worker
                echo "任务 [${target_mirror}] 已彻底从配置文件及后台中删除清理干净！"
                ;;
        esac
    done
}

function uninstall_env() {
    echo "================卸载 Tunasync================"
    read -p "警告：将停止服务并删除应用文件、服务，确认卸载吗？(y/N): " confirm_uninstall
    if [[ ! "$confirm_uninstall" =~ ^[Yy]$ ]]; then
        echo "已取消卸载。"
        return
    fi

    echo "1. 停止并禁用 systemd 服务..."
    systemctl stop tunasync-worker 2>/dev/null
    systemctl stop tunasync-manager 2>/dev/null
    systemctl disable tunasync-worker 2>/dev/null
    systemctl disable tunasync-manager 2>/dev/null

    echo "2. 删除 systemd 服务配置文件..."
    rm -f /etc/systemd/system/tunasync-manager.service
    rm -f /etc/systemd/system/tunasync-worker.service
    systemctl daemon-reload

    echo "3. 删除 Tunasync 二进制文件..."
    rm -f ${BIN_DIR}/tunasync
    rm -f ${BIN_DIR}/tunasynctl
    rm -f ${BIN_DIR}/tunasyncctl

    echo "4. 删除配置文件目录 (${CONF_DIR})..."
    rm -rf ${CONF_DIR}

    read -p "是否同时删除日志 (${LOG_DIR}) 与用户? (y/N): " rm_logs
    if [[ "$rm_logs" =~ ^[Yy]$ ]]; then
        rm -rf ${LOG_DIR}
        userdel ${RUN_USER} 2>/dev/null
        groupdel ${RUN_GROUP} 2>/dev/null
    fi

    echo "-------------------------------------------------------"
    echo "卸载完成！本脚本*没有*自动删除您的镜像数据存储目录："
    echo "  ${MIRROR_DIR}"
    echo "如需彻底清理镜像数据，请手动执行: rm -rf ${MIRROR_DIR}"
    echo "-------------------------------------------------------"
}

function show_menu() {
    while true; do
        echo ""
        echo "==========================================="
        echo "      Tunasync 引导式安装与管理向导"
        echo "==========================================="
        echo "  1) 安装 Tunasync 环境与基础 Worker 服务"
        echo "  2) 向 Worker 添加一个新的镜像同步任务 (Mirror)"
        echo "  3) 查看当前 Worker 与任务状态"
        echo "  4) 手动触发执行一次镜像同步活动"
        echo "  5) 列表管理现有的镜像任务 (停止/重新启动/删除/注销 Worker)"
        echo "  6) 卸载 Tunasync 并清理环境"
        echo "  0) 退出"
        echo "==========================================="
        read -p "请选择操作 [0-6]: " option
        case "$option" in
            1) install_env ;;
            2) add_mirror ;;
            3) manage_workers ;;
            4) manual_sync ;;
            5) manage_mirror_tasks ;;
            6) uninstall_env ;;
            0)
                echo "退出，再见！"
                exit 0
                ;;
            *)
                echo "无效输入，请重新选择"
                ;;
        esac
    done
}

# 启动菜单
show_menu
