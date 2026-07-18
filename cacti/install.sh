#!/bin/bash
##############################################################################
# Cacti + Spine 一键安装脚本 (AlmaLinux 9.x - Nginx + PHP-FPM 最终版)
# 功能：安装 PHP 8.3 + MariaDB 10.11 + Cacti 1.2.31 + Spine 1.2.31
# 特点：基于 Nginx + PHP-FPM，智能内存优化，无警告，路径正确
##############################################################################

# ======================== 配置项（仅需修改此处）========================
DB_ROOT_PASS="Huawei12#$"             # MariaDB root 密码
FONT_FILE="/root/DejaVuSans.ttf"      # 中文字体路径（用于修复乱码）
SET_MYSQL_TIMEZONE="yes"              # 是否显式设置 MySQL 时区为 +08:00
# 阿里 NTP 服务器列表
ALI_NTP_SERVERS=(
    "ntp.aliyun.com"
    "ntp1.aliyun.com"
    "ntp2.aliyun.com"
    "ntp3.aliyun.com"
    "ntp4.aliyun.com"
)
# ======================================================================

# 固定配置
CACTI_DB_PASS="cactiuser"
TIMEZONE="Asia/Shanghai"
CACTI_VERSION="1.2.31"
SPINE_VERSION="1.2.31"
CACTI_SOURCE_URL="https://www.cacti.net/downloads/cacti-${CACTI_VERSION}.tar.gz"
SPINE_SOURCE_URL="https://www.cacti.net/downloads/spine/cacti-spine-${SPINE_VERSION}.tar.gz"
WEB_USER="nginx"

# 颜色输出
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }

# 获取服务器 IP
get_server_ip() {
    SERVER_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
    [ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')
    [ -z "$SERVER_IP" ] && SERVER_IP=$(ip addr | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1 | head -1)
    [ -z "$SERVER_IP" ] && SERVER_IP="127.0.0.1" && yellow "⚠️ 未获取到公网 IP，使用 127.0.0.1"
    green "✅ 服务器 IP：$SERVER_IP"
}

# 前置检查
pre_check() {
    [ "$(id -u)" -ne 0 ] && red "❌ 请以 root 用户运行" && exit 1
    if [ ! -f "$FONT_FILE" ]; then
        yellow "⚠️ 字体文件 $FONT_FILE 不存在，中文可能乱码"
        read -p "继续安装？(y/N) " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    get_server_ip

    blue "=================================================="
    blue "   Cacti $CACTI_VERSION + Spine $SPINE_VERSION (Nginx 版)"
    blue "   MariaDB root 密码：$DB_ROOT_PASS"
    blue "   Cacti 数据库密码：$CACTI_DB_PASS"
    blue "   访问地址：http://$SERVER_IP"
    blue "   时区：$TIMEZONE"
    blue "=================================================="
    sleep 1
}

# 1. 系统更新
system_update() {
    blue "=== 步骤1：系统全量更新 ==="
    dnf update -y || { red "更新失败"; exit 1; }
    green "✅ 系统更新完成"
}

# 2. 时区与 NTP 同步
time_sync_config() {
    blue "=== 步骤2：时区设置与 NTP 同步 ==="
    timedatectl set-timezone "$TIMEZONE"
    dnf install -y chrony
    cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null
    sed -i '/^server/d' /etc/chrony.conf
    for ntp in "${ALI_NTP_SERVERS[@]}"; do echo "server $ntp iburst" >> /etc/chrony.conf; done
    echo "local stratum 10" >> /etc/chrony.conf
    systemctl enable --now chronyd
    chronyc -a makestep 2>/dev/null
    green "✅ 当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# 3. 基础系统配置
basic_config() {
    blue "=== 步骤3：防火墙/SELinux/rc.local ==="
    systemctl stop firewalld && systemctl disable firewalld 2>/dev/null
    setenforce 0 2>/dev/null
    sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
    chmod +x /etc/rc.d/rc.local 2>/dev/null
    green "✅ 防火墙已关闭，SELinux 已禁用"
}

# 4. 仓库配置
repo_config() {
    blue "=== 步骤4：配置 EPEL + Remi 仓库 ==="
    dnf install -y dnf-plugins-core
    dnf config-manager --set-enabled crb
    dnf install -y https://mirrors.huaweicloud.com/epel/epel-release-latest-9.noarch.rpm
    dnf install -y https://mirrors.huaweicloud.com/remi/enterprise/remi-release-9.2.rpm
    dnf clean all && dnf makecache -y
    green "✅ 仓库配置完成"
}

# 5. 安装 Nginx
nginx_install() {
    blue "=== 步骤5：安装 Nginx ==="
    dnf install -y nginx
    systemctl enable --now nginx
    green "✅ Nginx 已启动"
}

# 5.5 配置 Nginx（最终正确版，保留 /cacti 路径）
nginx_config() {
    blue "=== 步骤5.5：配置 Nginx 虚拟主机 ==="
    # 备份默认配置（避免冲突）
    [ -f /etc/nginx/conf.d/default.conf ] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak

    cat > /etc/nginx/conf.d/cacti.conf << 'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/cacti;
    index index.php;

    # 根路径跳转
    location = / {
        return 301 /cacti/;
    }

    # 处理所有 /cacti 请求（使用 alias 避免路径重叠）
    location /cacti {
        alias /usr/share/cacti;
        try_files $uri $uri/ /cacti/index.php?$args;

        location ~ \.php$ {
            fastcgi_pass unix:/run/php-fpm/www.sock;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $request_filename;
        }
    }

    # 禁止访问隐藏文件
    location ~ /\. {
        deny all;
    }
}
EOF

    systemctl restart nginx
    green "✅ Nginx 配置完成（保留 /cacti 路径）"
}

# 6. 安装与配置 PHP 8.3 + PHP-FPM
php_config() {
    blue "=== 步骤6：安装 PHP 8.3 及 PHP-FPM ==="
    dnf module reset php -y
    dnf module enable php:remi-8.3 -y
    dnf install -y php php-fpm php-xml php-session php-sockets php-ldap php-gd php-json \
        php-mysqlnd php-gmp php-mbstring php-posix php-pecl-rrd php-snmp php-intl php-cli

    # 配置 php.ini
    sed -i '/^memory_limit/ c\memory_limit = 512M' /etc/php.ini
    sed -i '/^max_execution_time/ c\max_execution_time = 60' /etc/php.ini
    sed -i '/;*date.timezone/d' /etc/php.ini
    echo 'date.timezone = "Asia/Shanghai"' >> /etc/php.ini

    # 配置 PHP-FPM（www.conf）
    cat > /etc/php-fpm.d/www.conf << 'FPMCONF'
[www]
user = nginx
group = nginx
listen = /run/php-fpm/www.sock
listen.owner = nginx
listen.group = nginx
listen.mode = 0660
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
security.limit_extensions = .php .php3 .php4 .php5 .php7 .php8
FPMCONF

    systemctl enable --now php-fpm
    systemctl restart nginx
    green "✅ PHP 8.3 安装完成，版本：$(php -v | head -1 | awk '{print $2}')"
}

# 7. 安装 SNMP / rrdtool
snmp_install() {
    blue "=== 步骤7：安装 SNMP/rrdtool ==="
    dnf install -y glibc-langpack-zh net-snmp net-snmp-utils net-snmp-libs rrdtool
    systemctl enable --now snmpd
    green "✅ SNMP 安装完成"
}

# 8. MariaDB 安装与调优
mariadb_config() {
    blue "=== 步骤8：安装 MariaDB 10.11（内存自适应优化） ==="
    dnf module enable mariadb:10.11 -y
    dnf install -y @mariadb

    TOTAL_MEM_MB=$(free -m | awk '/^Mem:/ {print $2}')
    [ "$TOTAL_MEM_MB" -lt 1024 ] && red "❌ 内存不足 1GB" && exit 1

    INNODB_BUFFER_POOL_MB=$((TOTAL_MEM_MB * 50 / 100))
    [ $INNODB_BUFFER_POOL_MB -gt 4096 ] && INNODB_BUFFER_POOL_MB=4096
    [ $INNODB_BUFFER_POOL_MB -lt 256 ] && INNODB_BUFFER_POOL_MB=256

    JOIN_BUFFER_MB=$((TOTAL_MEM_MB / 2000))
    [ $JOIN_BUFFER_MB -lt 4 ] && JOIN_BUFFER_MB=4
    [ $JOIN_BUFFER_MB -gt 16 ] && JOIN_BUFFER_MB=16

    HEAP_TMP_TABLE_MB=$((TOTAL_MEM_MB * 10 / 100))
    [ $HEAP_TMP_TABLE_MB -lt 64 ] && HEAP_TMP_TABLE_MB=64
    [ $HEAP_TMP_TABLE_MB -gt 512 ] && HEAP_TMP_TABLE_MB=512

    green "✅ MariaDB 优化参数：InnoDB Buffer ${INNODB_BUFFER_POOL_MB}M, Heap ${HEAP_TMP_TABLE_MB}M"

    cp /etc/my.cnf /etc/my.cnf.bak 2>/dev/null
    cat > /etc/my.cnf << EOF
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-storage-engine=InnoDB
max_connections=300
max_allowed_packet=64M
tmp_table_size=${HEAP_TMP_TABLE_MB}M
max_heap_table_size=${HEAP_TMP_TABLE_MB}M
join_buffer_size=${JOIN_BUFFER_MB}M
sort_buffer_size=128K
read_buffer_size=128K
read_rnd_buffer_size=128K
thread_stack=192K
innodb_file_per_table=ON
innodb_buffer_pool_size=${INNODB_BUFFER_POOL_MB}M
innodb_doublewrite=OFF
innodb_flush_method=O_DIRECT
innodb_log_file_size=128M
innodb_log_buffer_size=32M
EOF

    [ "$SET_MYSQL_TIMEZONE" = "yes" ] && echo 'default-time-zone="+08:00"' >> /etc/my.cnf

    systemctl enable --now mariadb
    mysql_secure_installation <<EOF

y
$DB_ROOT_PASS
$DB_ROOT_PASS
y
y
y
y
EOF

    mysql -u root -p"$DB_ROOT_PASS" -e "SELECT 1" &>/dev/null || { red "MariaDB 密码设置失败"; exit 1; }
    mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root -p"$DB_ROOT_PASS" mysql
    green "✅ MariaDB 配置完成"
}

# 9. 创建 Cacti 数据库
cacti_db_create() {
    blue "=== 步骤9：创建 Cacti 数据库 ==="
    mysql -u root -p"$DB_ROOT_PASS" -e "
CREATE DATABASE IF NOT EXISTS cacti DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'cactiuser'@'localhost' IDENTIFIED BY '$CACTI_DB_PASS';
GRANT ALL PRIVILEGES ON cacti.* TO 'cactiuser'@'localhost';
GRANT SELECT ON mysql.time_zone_name TO 'cactiuser'@'localhost';
FLUSH PRIVILEGES;
"
    green "✅ Cacti 数据库创建完成"
}

# 10. 编译安装 Cacti + Spine
cacti_install() {
    blue "=== 步骤10：源码安装 Cacti ${CACTI_VERSION} + Spine ${SPINE_VERSION} ==="
    dnf install -y gcc make autoconf automake libtool dos2unix wget \
        mysql-devel net-snmp-devel rrdtool-devel help2man openssl-devel composer

    # 下载解压 Cacti
    cd /tmp
    wget -q ${CACTI_SOURCE_URL} -O cacti-${CACTI_VERSION}.tar.gz || { red "下载 Cacti 失败"; exit 1; }
    tar xzf cacti-${CACTI_VERSION}.tar.gz
    EXTRACT_DIR=$(tar -tf cacti-${CACTI_VERSION}.tar.gz | head -1 | cut -d'/' -f1)
    [ "$EXTRACT_DIR" != "cacti-${CACTI_VERSION}" ] && mv "$EXTRACT_DIR" "cacti-${CACTI_VERSION}" 2>/dev/null

    [ -d /usr/share/cacti ] && mv /usr/share/cacti /usr/share/cacti.bak.$(date +%Y%m%d%H%M%S)
    mkdir -p /usr/share/cacti
    cp -r cacti-${CACTI_VERSION}/* /usr/share/cacti/
    chown -R ${WEB_USER}:${WEB_USER} /usr/share/cacti

    # Composer 安装依赖
    blue "=== Composer 安装 PHP 依赖 ==="
    cd /usr/share/cacti
    command -v composer &>/dev/null || {
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
        php composer-setup.php --install-dir=/usr/bin --filename=composer
        php -r "unlink('composer-setup.php');"
    }
    composer config --no-interaction policy.advisories.block false
    COMPOSER_LOG="/tmp/cacti_composer.log"
    if ! COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction --no-ansi > "$COMPOSER_LOG" 2>&1; then
        red "❌ Composer 安装失败，日志如下："
        cat "$COMPOSER_LOG"
        rm -f "$COMPOSER_LOG"
        exit 1
    fi
    rm -f "$COMPOSER_LOG"
    green "✅ Composer 依赖安装完成"

    # 导入数据库
    mysql -u cactiuser -p"${CACTI_DB_PASS}" --default-character-set=utf8mb4 cacti < /usr/share/cacti/cacti.sql || { red "数据库导入失败"; exit 1; }

    # 编译安装 Spine
    cd /tmp
    wget -q ${SPINE_SOURCE_URL} -O cacti-spine-${SPINE_VERSION}.tar.gz || { red "下载 Spine 失败"; exit 1; }
    tar xzf cacti-spine-${SPINE_VERSION}.tar.gz
    cd cacti-spine-${SPINE_VERSION}
    dos2unix bootstrap configure.ac *.m4 2>/dev/null
    sed -i 's/usmDESPrivProtocol/usmAESPrivProtocol/g' snmp.c
    ./bootstrap
    ./configure --with-mysql=/usr --with-snmp=/usr
    make && make install

    ln -sf /usr/local/spine/bin/spine /usr/bin/spine
    cp spine.conf.dist /etc/spine.conf
    sed -i "s/DB_Pass=/DB_Pass=${CACTI_DB_PASS}/g" /etc/spine.conf
    sed -i "s/DB_PreG=0/DB_PreG=1/g" /etc/spine.conf

    # 权限适配
    chown root:${WEB_USER} /etc/spine.conf
    chmod 640 /etc/spine.conf

    # 确保必要目录可写
    mkdir -p /usr/share/cacti/{log,rra}
    chown -R ${WEB_USER}:${WEB_USER} /usr/share/cacti/{log,rra}
    green "✅ Cacti + Spine 源码安装完成"
}

# 11. 配置 Cacti 数据库连接 + URL 路径
cacti_db_config() {
    blue "=== 步骤11：配置 Cacti 数据库连接及 URL 路径 ==="
    cp /usr/share/cacti/include/config.php.dist /usr/share/cacti/include/config.php
    sed -i \
        -e "s/\$database_password = '';/\$database_password = '$CACTI_DB_PASS';/g" \
        -e "s/\$database_username = 'cactiuser';/\$database_username = 'cactiuser';/g" \
        -e "s/\$database_default = 'cacti';/\$database_default = 'cacti';/g" \
        /usr/share/cacti/include/config.php

    # 关键：设置 Cacti 的 URL 路径为 /cacti/，与 Nginx 配置保持一致
    if grep -q '\$url_path' /usr/share/cacti/include/config.php; then
        sed -i "s|^\$url_path.*|\$url_path = '/cacti/';|" /usr/share/cacti/include/config.php
    else
        echo "\$url_path = '/cacti/';" >> /usr/share/cacti/include/config.php
    fi
    green "✅ 数据库连接及 URL 路径配置完成"
}

# 12. Cron 任务与收尾
final_config() {
    blue "=== 步骤12：配置 Cron 任务 ==="
    cat > /etc/cron.d/cacti << EOF
# Cacti poller 每5分钟执行一次
*/5 * * * * ${WEB_USER} /usr/bin/php /usr/share/cacti/poller.php > /dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/cacti
    green "✅ Cron 任务已添加"
}

# 13. 中文字体修复
font_config() {
    blue "=== 步骤13：中文乱码修复 ==="
    dnf install -y fontconfig ttmkfdir
    mkdir -p /usr/share/fonts/chinese
    cp "$FONT_FILE" /usr/share/fonts/chinese/
    fc-cache -fv
    green "✅ 字体安装完成"
}

# 完成提示
final_tips() {
    blue "=================================================="
    green "🎉 Cacti $CACTI_VERSION + Spine $SPINE_VERSION 安装完成 (Nginx)"
    blue "=================================================="
    echo "访问地址：http://$SERVER_IP"
    echo "初始账号：admin / admin（登录后强制修改密码）"
    echo "数据库 root 密码：$DB_ROOT_PASS"
    echo "Cacti 数据库密码：$CACTI_DB_PASS"
    echo "系统时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
    green "登录后 → 配置 → 设置 → 轮询器 → 选择「Spine」"
    blue "=================================================="
}

# 主流程
main() {
    pre_check
    system_update
    time_sync_config
    basic_config
    repo_config
    nginx_install
    nginx_config
    php_config
    snmp_install
    mariadb_config
    cacti_db_create
    cacti_install
    cacti_db_config
    final_config
    font_config
    final_tips
}

main
