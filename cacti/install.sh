#!/bin/bash
set -e

BASE_DIR="/opt/cacti"

# ===============================
# 1️⃣ 检测 Docker
# ===============================
echo "=== 检查 Docker ==="
if ! command -v docker &> /dev/null; then
    echo "Docker 未安装，正在安装..."
    apt update
    apt install -y docker.io
    systemctl enable docker
    systemctl start docker
else
    echo "Docker 已安装"
fi

# ===============================
# 2️⃣ 检测 docker-compose
# ===============================
echo "=== 检查 docker-compose ==="
if ! command -v docker-compose &> /dev/null; then
    echo "docker-compose 未安装，正在安装..."
    apt update
    apt install -y docker-compose
else
    echo "docker-compose 已安装"
fi

COMPOSE_CMD="docker-compose"

# ===============================
# 3️⃣ 创建目录结构
# ===============================
echo "=== 创建目录结构 ==="
mkdir -p $BASE_DIR/{mysql_data,rra,plugins,resource,scripts}
cd $BASE_DIR

# ===============================
# 4️⃣ 生成 docker-compose.yml
# ===============================
echo "=== 生成 docker-compose.yml ==="
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  cacti:
    image: joehorn/cacti:latest
    container_name: cacti
    ports:
      - "80:80"
    volumes:
      - ./mysql_data:/var/lib/mysql
      - ./rra:/opt/cacti/rra
      - ./plugins:/opt/cacti/plugins
      - ./resource:/opt/cacti/resource
      - ./scripts:/opt/cacti/scripts
      - ./mysql.cnf:/etc/mysql/mysql.conf.d/zz-cacti.cnf
    environment:
      - TZ=Asia/Shanghai
    restart: always
EOF

# ===============================
# 5️⃣ 生成 mysql.cnf
# ===============================
echo "=== 生成 mysql.cnf ==="
cat > mysql.cnf << 'EOF'
[mysqld]
user = mysql
pid-file = /var/run/mysqld/mysqld.pid
socket = /var/run/mysqld/mysqld.sock
port = 3306
datadir = /var/lib/mysql
bind-address = 127.0.0.1
mysqlx-bind-address = 127.0.0.1

character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

sql-mode = NO_ENGINE_SUBSTITUTION

max_connections = 500
max_allowed_packet = 1G

default-storage-engine = InnoDB
innodb_buffer_pool_size = 4G
innodb_buffer_pool_chunk_size = 128M
innodb_buffer_pool_instances = 16
innodb_log_file_size = 1G
innodb_lock_wait_timeout = 120
innodb_file_per_table = ON
innodb_doublewrite = ON
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 2
innodb_io_capacity = 5000
innodb_io_capacity_max = 10000
innodb_read_io_threads = 32
innodb_write_io_threads = 16
innodb_flush_log_at_timeout = 3

max_heap_table_size = 256M
tmp_table_size = 256M
join_buffer_size = 8M
sort_buffer_size = 256K

sync_binlog = 0

table_open_cache = 2000
thread_cache_size = 100
key_buffer_size = 16M
myisam-recover-options = BACKUP

default-time-zone = '+08:00'

log_error = /var/log/mysql/error.log
max_binlog_size = 100M

ft_min_word_len = 1
innodb_ft_min_token_size = 1

[client]
default-character-set = utf8mb4
socket = /var/run/mysqld/mysqld.sock

[mysql]
default-character-set = utf8mb4
EOF

# ===============================
# 6️⃣ 启动 Cacti 容器
# ===============================
echo "=== 启动 Cacti 容器 ==="
$COMPOSE_CMD up -d

# 等待容器启动
echo "=== 等待容器启动（10 秒）==="
sleep 10

# ===============================
# 7️⃣ 安装中文字体
# ===============================
echo "=== 安装中文字体 ==="
docker exec -it cacti bash -c "apt update && apt install -y fonts-wqy-microhei fonts-dejavu-core && fc-cache -fv"

# ===============================
# 8️⃣ 输出访问 IP
# ===============================
IP_ADDR=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./) {print $i; exit}}')

echo "=== 安装完成！访问 Cacti ==="
echo "URL: http://$IP_ADDR"
