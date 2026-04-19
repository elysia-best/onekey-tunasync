#!/bin/bash
# ==================================================
# tunasync 一键安装与配置脚本 (适用 Debian/Ubuntu)
# ==================================================

set -e

# ================= 配置变量 =================
RUN_USER="tuansyncer"
RUN_GROUP="www"
MIRROR_DIR="/data/mirrors"
LOG_DIR="/data/log"
CONF_DIR="/etc/tunasync"
BIN_DIR="/usr/local/bin"

echo "开始安装 tunasync..."

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本！"
  exit 1
fi

# 2. 安装必要依赖
echo "正在安装必要依赖 (curl, wget, jq, ca-certificates)..."
apt-get update -y
apt-get install -y curl wget jq ca-certificates rsync

# 3. 创建用户与用户组
echo "正在创建用户组 ${RUN_GROUP} 和用户 ${RUN_USER}..."
if ! getent group "${RUN_GROUP}" >/dev/null; then
    groupadd "${RUN_GROUP}"
fi
if ! getent passwd "${RUN_USER}" >/dev/null; then
    useradd -r -s /bin/bash -g "${RUN_GROUP}" -d "${MIRROR_DIR}" "${RUN_USER}"
fi

# 4. 创建目录并设置权限
echo "正在创建数据和日志目录..."
mkdir -p "${MIRROR_DIR}"
mkdir -p "${LOG_DIR}"
mkdir -p "${CONF_DIR}"

chown -R ${RUN_USER}:${RUN_GROUP} "${MIRROR_DIR}"
chown -R ${RUN_USER}:${RUN_GROUP} "${LOG_DIR}"
# 给目录设置组可读写执行的权限
chmod -R 775 "${MIRROR_DIR}"
chmod -R 775 "${LOG_DIR}"

# 5. 获取并下载最新版 tunasync 二进制文件
echo "正在从 GitHub 获取 tunasync 最新版本..."
# 获取最新 release 的下载链接
RELEASE_DATA=$(curl -s https://api.github.com/repos/tuna/tunasync/releases/latest)
DOWNLOAD_URL=$(echo "$RELEASE_DATA" | jq -r '.assets[] | select(.name | test("linux-amd64-bin.tar.gz$|linux-amd64.tar.gz$")) | .browser_download_url' | head -n 1)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "无法获取到最新的下载链接，请检查网络或 GitHub API 限制。"
    exit 1
fi

echo "下载链接: $DOWNLOAD_URL"
wget -qO /tmp/tunasync.tar.gz "$DOWNLOAD_URL"

echo "正在解压并安装..."
tar -xzf /tmp/tunasync.tar.gz -C /tmp
mv /tmp/tunasync ${BIN_DIR}/
mv /tmp/tunasyncctl ${BIN_DIR}/
chmod +x ${BIN_DIR}/tunasync ${BIN_DIR}/tunasyncctl
rm -f /tmp/tunasync.tar.gz

# 6. 生成配置文件
echo "正在生成 Manager 和 Worker 配置文件..."

# Manager 配置文件
cat > ${CONF_DIR}/manager.conf <<EOF
debug = false

[server]
addr = "127.0.0.1"
port = 14242
ssl_cert = ""
ssl_key = ""

[files]
db_type = "bolt"
db_file = "${MIRROR_DIR}/manager.db"
ca_cert = ""
EOF

# Worker 配置文件
cat > ${CONF_DIR}/worker.conf <<EOF
[global]
name = "main-worker"
log_dir = "${LOG_DIR}"
mirror_dir = "${MIRROR_DIR}"
concurrent = 10
interval = 120

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

# 这是���个演示镜像，后续你可以直接修改这个文件添加更多的镜像同步配置
[[mirrors]]
name = "hello-world"
provider = "command"
upstream = "https://example.com"
command = "echo 'tunasync worker is running!'"
interval = 1440
EOF

chown -R ${RUN_USER}:${RUN_GROUP} ${CONF_DIR}

# 7. 配置 systemd 服务
echo "正在创建 systemd 服务文件..."

# Manager service
cat > /etc/systemd/system/tunasync-manager.service <<EOF
[Unit]
Description=TUNA mirrors sync manager
After=network.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
ExecStart=${BIN_DIR}/tunasync manager --config ${CONF_DIR}/manager.conf
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Worker service
cat > /etc/systemd/system/tunasync-worker.service <<EOF
[Unit]
Description=TUNA mirrors sync worker
After=network.target tunasync-manager.service
Requires=tunasync-manager.service

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
ExecStart=${BIN_DIR}/tunasync worker --config ${CONF_DIR}/worker.conf
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动并设置开机自启
echo "正在加载并启动 systemd 服务..."
systemctl daemon-reload
systemctl enable tunasync-manager
systemctl enable tunasync-worker
systemctl start tunasync-manager
systemctl start tunasync-worker

echo "=================================================="
echo "Tunasync 安装完成！"
echo "- 执行文件目录: /usr/local/bin/tunasync"
echo "- 配置文件目录: /etc/tunasync/"
echo "- 数据存储目录: /data/mirrors"
echo "- 日志存储目录: /data/log"
echo ""
echo "检查服务状态："
echo "  systemctl status tunasync-manager"
echo "  systemctl status tunasync-worker"
echo ""
echo "你可以使用 tunasyncctl 来管理同步任务："
echo "  tunasyncctl list -p 14242"
echo "=================================================="
