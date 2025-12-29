#!/bin/bash
##############################################################################
# Cacti + Spine 一键安装脚本 (AlmaLinux 9.x 专用 - 最终优化版)
# 功能: 集成系统优化、动态数据库配置、时间同步、中文乱码修复、Apache根目录重定向。
##############################################################################

# ======================== 配置项（仅需修改此处）========================
DB_ROOT_PASS="Huawei12#$"  # 替换为你的MariaDB root强密码
FONT_FILE="/root/DejaVuSans.ttf"        # 中文乱码修复所需字体文件路径
SET_MYSQL_TIMEZONE="yes"                # 是否显式设置MySQL时区为+08:00（推荐yes）
# 阿里NTP服务器列表（无需修改）
ALI_NTP_SERVERS=(
    "ntp.aliyun.com"
    "ntp1.aliyun.com"
    "ntp2.aliyun.com"
    "ntp3.aliyun.com"
    "ntp4.aliyun.com"
)
# ======================================================================

# 固定配置（无需修改）
CACTI_DB_PASS="cactiuser"
TIMEZONE="Asia/Shanghai"

# 颜色输出函数（增强可读性）
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }

# 自动获取服务器IP
get_server_ip() {
    SERVER_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
    if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "127.0.0.1" ]; then
        SERVER_IP=$(hostname -I | awk '{print $1}')
    fi
    if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "127.0.0.1" ]; then
        SERVER_IP=$(ip addr | grep 'inet ' | grep -v '127.0.0.1' | grep -v 'docker' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    fi
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="127.0.0.1"
        yellow "⚠️  自动获取IP失败，默认使用127.0.0.1"
    else
        green "✅ 自动获取服务器IP：$SERVER_IP"
    fi
}

# 前置检查
pre_check() {
    # 检查root权限
    if [ "$(id -u)" -ne 0 ]; then
        red "❌ 错误：请以root用户运行此脚本！"
        exit 1
    fi

    # 检查字体文件
    if [ ! -f "$FONT_FILE" ]; then
        yellow "⚠️  警告：未找到字体文件 $FONT_FILE（中文乱码修复会失败）！"
        read -p "是否继续安装（Y/N）？" -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # 获取服务器IP
    get_server_ip

    # 确认配置
    blue "=================================================="
    blue "即将开始安装 Cacti + Spine（AlmaLinux 9 + PHP 8.3）"
    blue "配置信息："
    echo "  - MariaDB root密码：$DB_ROOT_PASS"
    echo "  - Cacti数据库密码：$CACTI_DB_PASS"
    echo "  - 服务器访问IP：$SERVER_IP"
    echo "  - 时区配置：$TIMEZONE"
    echo "  - 显式设置MySQL时区：$SET_MYSQL_TIMEZONE"
    echo "  - NTP服务器：${ALI_NTP_SERVERS[*]}"
    blue "=================================================="
    sleep 1
}

# 步骤1：系统全量更新
system_update() {
    blue "=== 步骤1：系统全量更新 ==="
    if ! dnf update -y; then
        red "❌ 系统更新失败！请手动执行 dnf update -y 后重试"
        exit 1
    fi
    green "✅ 系统更新完成"
}

# 步骤2：设置系统时区 + 配置阿里NTP同步时间
time_sync_config() {
    blue "=== 步骤2：系统时区设置 + 阿里NTP时间同步 ==="
    
    # 1. 强制设置系统时区为上海
    if ! timedatectl set-timezone "$TIMEZONE"; then
        red "❌ 系统时区设置失败！请手动执行：timedatectl set-timezone Asia/Shanghai"
        exit 1
    fi
    green "✅ 系统时区已强制设置为：$TIMEZONE（$(timedatectl | grep "Time zone" | awk -F': ' '{print $2}')）"

    # 2. 安装chrony
    if ! dnf install -y chrony >/dev/null 2>&1; then
        red "❌ chrony安装失败！"
        exit 1
    fi

    # 3. 备份原有chrony配置
    cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null

    # 4. 配置阿里NTP服务器
    sed -i '/^server/d' /etc/chrony.conf
    for ntp_server in "${ALI_NTP_SERVERS[@]}"; do
        echo "server $ntp_server iburst" >> /etc/chrony.conf
    done
    echo "local stratum 10" >> /etc/chrony.conf

    # 5. 重启chronyd服务并设置开机自启
    systemctl enable --now chronyd >/dev/null 2>&1
    if [ "$(systemctl is-active chronyd)" != "active" ]; then
        red "❌ chronyd服务启动失败！"
        exit 1
    fi
    green "✅ chronyd服务已启动，NTP服务器配置为：${ALI_NTP_SERVERS[*]}"

    # 6. 强制同步时间
    if ! chronyc -a makestep >/dev/null 2>&1; then
        yellow "⚠️  时间同步警告：首次同步可能延迟，已重试..."
        sleep 5
        chronyc -a makestep >/dev/null 2>&1
    fi

    # 7. 验证时间同步结果
    sync_result=$(chronyc sources -v | grep -E "^\*|^\+" | head -n1)
    if [ -n "$sync_result" ]; then
        green "✅ 阿里NTP时间同步成功！同步源：$(echo "$sync_result" | awk '{print $2}')"
        green "✅ 当前系统时间：$(date "+%Y-%m-%d %H:%M:%S %Z")"
    else
        yellow "⚠️  时间同步验证警告（可能网络延迟），当前时间：$(date "+%Y-%m-%d %H:%M:%S %Z")"
    fi
}

# 步骤3：基础系统配置（防火墙/SELinux/rc.local）
basic_config() {
    blue "=== 步骤3：基础系统配置 ==="
    # 关闭防火墙
    systemctl stop firewalld && systemctl disable firewalld >/dev/null 2>&1
    green "✅ 防火墙（firewalld）已关闭并禁用，状态：$(systemctl is-active firewalld)"

    # 关闭SELinux
    setenforce 0 >/dev/null 2>&1
    sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
    green "✅ SELinux已临时关闭，当前状态：$(getenforce)（已设置永久禁用，重启生效）"

    # 设置rc.local可执行权限
    if ! chmod +x /etc/rc.d/rc.local; then
        red "❌ chmod +x /etc/rc.d/rc.local 执行失败！"
        exit 1
    fi
    if ls -l /etc/rc.d/rc.local | grep -q 'x'; then
        green "✅ /etc/rc.d/rc.local 已添加可执行权限"
    else
        yellow "⚠️  rc.local权限设置警告，请手动执行：chmod +x /etc/rc.d/rc.local"
    fi
}


# 步骤4：配置EPEL + Remi仓库
repo_config() {
    blue "=== 步骤4：配置EPEL + Remi仓库 ==="
    if ! dnf install -y https://mirrors.aliyun.com/epel/epel-release-latest-9.noarch.rpm; then
        red "❌ EPEL仓库安装失败！"
        exit 1
    fi
    if ! dnf install -y https://mirrors.aliyun.com/remi/enterprise/remi-release-9.2.rpm; then
        red "❌ Remi仓库安装失败！"
        exit 1
    fi
    dnf clean all && dnf makecache -y >/dev/null 2>&1
    green "✅ 仓库配置完成"
}

# 步骤5：安装并配置HTTPD
httpd_install() {
    blue "=== 步骤5：安装HTTP服务 ==="
    if ! dnf install -y httpd; then
        red "❌ httpd安装失败！"
        exit 1
    fi
    systemctl enable --now httpd >/dev/null 2>&1
    if [ "$(systemctl is-active httpd)" = "active" ]; then
        green "✅ httpd已安装并启动，状态：active"
    else
        red "❌ httpd启动失败！"
        exit 1
    fi
}

# 步骤5.5：配置Apache根目录重定向到Cacti
httpd_redirect_config() {
    blue "=== 步骤5.5：配置Apache根目录重定向到Cacti ==="
    local redirect_file="/etc/httpd/conf.d/redirects.conf"

    # 检查文件是否已存在，如果存在则备份
    if [ -f "$redirect_file" ]; then
        cp "$redirect_file" "${redirect_file}.bak"
        yellow "⚠️  已存在的 $redirect_file 文件已备份为 ${redirect_file}.bak"
    fi

    # 写入301重定向规则
    echo "RedirectMatch 301 ^/$ /cacti/" > "$redirect_file"
    
    # 重启Apache使配置生效
    systemctl restart httpd >/dev/null 2>&1

    # 验证配置是否生效
    if [ "$(systemctl is-active httpd)" = "active" ]; then
        green "✅ Apache根目录重定向配置完成！"
        green "   现在访问 http://$SERVER_IP 将会自动跳转到 http://$SERVER_IP/cacti/"
    else
        red "❌ Apache重启失败！请检查 $redirect_file 文件内容是否有误。"
        exit 1
    fi
}

# 步骤6：安装并配置PHP 8.3
php_config() {
    blue "=== 步骤6：安装PHP 8.3并配置 ==="
    if ! dnf module reset php -y; then red "❌ PHP模块重置失败！"; exit 1; fi
    if ! dnf module enable php:remi-8.3 -y; then red "❌ 启用PHP 8.3失败！"; exit 1; fi
    if ! dnf install -y php php-xml php-session php-sockets php-ldap php-gd php-json \
        php-mysqlnd php-gmp php-mbstring php-posix php-pecl-rrd php-rrd php-snmp php-intl php-cli; then
        red "❌ PHP 8.3安装失败！"
        exit 1
    fi

    blue "=== 开始修改PHP.ini配置..."
    sed -i '/^memory_limit/ c\memory_limit = 512M' /etc/php.ini
    sed -i '/^max_execution_time/ c\max_execution_time = 60' /etc/php.ini
    sed -i '/;*date.timezone/d' /etc/php.ini
    echo 'date.timezone = "Asia/Shanghai"' >> /etc/php.ini

    blue "=== 验证PHP配置 ==="
    grep -E 'memory_limit|max_execution_time|date.timezone' /etc/php.ini | grep -v ';'
    PHP_TIMEZONE=$(php -r 'echo date_default_timezone_get()."\n";')
    if [ "$PHP_TIMEZONE" = "Asia/Shanghai" ]; then
        green "✅ PHP时区已成功设置为：$PHP_TIMEZONE"
    else
        red "❌ PHP时区设置失败，当前为：$PHP_TIMEZONE"
        exit 1
    fi

    systemctl restart httpd >/dev/null 2>&1
    green "✅ PHP 8.3安装完成，版本：$(php -v | head -n1 | awk '{print $2}')"
}

# 步骤7：安装SNMP + rrdtool
snmp_install() {
    blue "=== 步骤7：安装SNMP/rrdtool ==="
    if ! dnf install -y net-snmp net-snmp-utils net-snmp-libs rrdtool; then
        red "❌ SNMP/rrdtool安装失败！"
        exit 1
    fi
    systemctl enable --now snmpd >/dev/null 2>&1
    if [ "$(systemctl is-active snmpd)" = "active" ]; then
        green "✅ snmpd已安装并启动，状态：active"
    else
        red "❌ snmpd启动失败！"
        exit 1
    fi
}

# 步骤8：安装并配置MariaDB（智能适应内存大小的最终版）
mariadb_config() {
    blue "=== 步骤8：安装并配置MariaDB（智能适应内存大小的最终版） ==="
    if ! dnf install -y @mariadb; then red "❌ MariaDB安装失败！"; exit 1; fi

    TOTAL_MEM_MB=$(free -m | awk '/^Mem:/ {print $2}')
    if [ -z "$TOTAL_MEM_MB" ] || [ "$TOTAL_MEM_MB" -lt 1024 ]; then
        red "❌ 错误：检测到内存小于1GB。Cacti + Spine 无法在如此低的内存下稳定运行，建议至少4GB内存。"
        exit 1
    fi
    green "✅ 检测到服务器总内存：${TOTAL_MEM_MB}MB"

    # --- 【智能策略】根据总内存大小，自动选择最佳的分配方案 ---
    INNODB_BUFFER_POOL_MB=0
    HEAP_TMP_TABLE_MB=0

    if [ "$TOTAL_MEM_MB" -lt 2048 ]; then
        # 策略A：内存 < 2GB (极小内存，能跑就行)
        yellow "⚠️  检测到极小内存环境 (<2GB)，将采用最保守的生存策略。"
        INNODB_BUFFER_POOL_MB=$((TOTAL_MEM_MB * 40 / 100))
        HEAP_TMP_TABLE_MB=$((TOTAL_MEM_MB * 5 / 100))
    elif [ "$TOTAL_MEM_MB" -lt 4096 ]; then
        # 策略B：内存 2GB - 4GB (小内存，优先稳定)
        yellow "⚠️  检测到小内存环境 (2GB-4GB)，将采用稳定优先的策略。"
        INNODB_BUFFER_POOL_MB=$((TOTAL_MEM_MB * 45 / 100))
        HEAP_TMP_TABLE_MB=$((TOTAL_MEM_MB * 8 / 100))
    else
        # 策略C：内存 >= 4GB (标准内存，平衡策略)
        green "✅ 检测到标准内存环境 (>=4GB)，将采用平衡优化策略。"
        INNODB_BUFFER_POOL_MB=$((TOTAL_MEM_MB * 50 / 100))
        HEAP_TMP_TABLE_MB=$((TOTAL_MEM_MB * 10 / 100))
    fi
    
    # --- 为计算出的值设置合理的上下限 ---
    # innodb_buffer_pool_size 最小为 256MB
    [ "$INNODB_BUFFER_POOL_MB" -lt 256 ] && INNODB_BUFFER_POOL_MB=256
    # max_heap_table_size 最小为 64MB，最大为 512MB (在小内存机器上，上限要低)
    [ "$HEAP_TMP_TABLE_MB" -lt 64 ] && HEAP_TMP_TABLE_MB=64
    [ "$HEAP_TMP_TABLE_MB" -gt 512 ] && HEAP_TMP_TABLE_MB=512
    
    # 保持安全的默认值
    JOIN_BUFFER_SIZE="256K"
    SORT_BUFFER_SIZE="256K"

    green "✅ 动态计算出数据库优化参数："
    echo "   - innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_MB}M"
    echo "   - max_heap_table_size     = ${HEAP_TMP_TABLE_MB}M"
    echo "   - join_buffer_size        = ${JOIN_BUFFER_SIZE}"
    echo "   - sort_buffer_size        = ${SORT_BUFFER_SIZE}"

    # --- 后续配置与之前版本相同 ---
    cp /etc/my.cnf /etc/my.cnf.bak 2>/dev/null
    cat > /etc/my.cnf << EOF
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
character-set-client-handshake = FALSE
init_connect='SET NAMES utf8mb4'

max_connections = 300
max_allowed_packet = 64M

tmp_table_size = ${HEAP_TMP_TABLE_MB}M
max_heap_table_size = ${HEAP_TMP_TABLE_MB}M

join_buffer_size = ${JOIN_BUFFER_SIZE}
sort_buffer_size = ${SORT_BUFFER_SIZE}

innodb_file_per_table = ON
innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_MB}M
innodb_doublewrite = OFF
innodb_use_atomic_writes = ON
innodb_flush_method = O_DIRECT
innodb_lock_wait_timeout = 50
innodb_log_file_size = 128M
innodb_log_buffer_size = 32M
innodb_read_io_threads = 4
innodb_write_io_threads = 4
EOF

    if [ "$SET_MYSQL_TIMEZONE" = "yes" ]; then
        echo "default-time-zone = \"+08:00\"" >> /etc/my.cnf
        green "✅ 已显式设置MySQL全局时区为 '+08:00'"
    fi

    systemctl enable --now mariadb >/dev/null 2>&1
    if [ "$(systemctl is-active mariadb)" != "active" ]; then
        red "❌ MariaDB启动失败！请检查 /etc/my.cnf 配置是否有误。"
        exit 1
    fi

    if ! mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';"; then
        red "❌ MariaDB root密码设置失败！"
        exit 1
    fi

    if ! mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root -p"$DB_ROOT_PASS" mysql >/dev/null 2>&1; then
        yellow "⚠️  MySQL时区表加载警告"
    else
        green "✅ MySQL时区表加载完成"
    fi

    blue "=== 验证MariaDB配置 ==="
    MYSQL_TZ=$(mysql -u root -p"$DB_ROOT_PASS" -e "SELECT @@global.time_zone;" 2>/dev/null | grep -v '@@global.time_zone')
    green "✅ MariaDB全局时区：$MYSQL_TZ"
    green "✅ MariaDB安装并配置完成！"
}

# 步骤9：创建Cacti数据库
cacti_db_create() {
    blue "=== 步骤9：创建Cacti数据库 ==="
    if ! mysql -u root -p"$DB_ROOT_PASS" -e "
CREATE DATABASE IF NOT EXISTS cacti DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'cactiuser'@'localhost' IDENTIFIED BY '$CACTI_DB_PASS';
GRANT ALL PRIVILEGES ON cacti.* TO 'cactiuser'@'localhost';
GRANT SELECT ON mysql.time_zone_name TO 'cactiuser'@'localhost';
FLUSH PRIVILEGES;
" >/dev/null 2>&1; then
        red "❌ Cacti数据库创建失败！"
        exit 1
    fi
    green "✅ Cacti数据库创建完成（用户：cactiuser，密码：$CACTI_DB_PASS）"
}

# 步骤10：安装Cacti + Spine
cacti_install() {
    blue "=== 步骤10：安装Cacti + Spine ==="
    if ! dnf install -y cacti cacti-spine; then
        red "❌ Cacti/Spine安装失败！"
        exit 1
    fi
    if ! mysql -u cactiuser -p"$CACTI_DB_PASS" --default-character-set=utf8mb4 cacti < /usr/share/doc/cacti/cacti.sql >/dev/null 2>&1; then
        red "❌ Cacti数据库导入失败！"
        exit 1
    fi
    green "✅ Cacti + Spine安装完成"
}

# 步骤11：配置Cacti/Spine数据库连接
cacti_db_config() {
    blue "=== 步骤11：配置Cacti/Spine数据库连接 ==="
    sed -i \
        -e "s/\$database_password = '';/\$database_password = '$CACTI_DB_PASS';/g" \
        -e "s/\$database_username = 'cactiuser';/\$database_username = 'cactiuser';/g" \
        -e "s/\$database_default = 'cacti';/\$database_default = 'cacti';/g" \
        /usr/share/cacti/include/config.php

    cp /etc/spine.conf /etc/spine.conf.bak 2>/dev/null
    sed -i \
        -e "s/DB_Pass=/DB_Pass=$CACTI_DB_PASS/g" \
        -e "s/DB_PreG=0/DB_PreG=1/g" \
        /etc/spine.conf
    green "✅ Cacti/Spine数据库连接配置完成"
}

# 步骤12：配置HTTPD + Cron任务
final_config() {
    blue "=== 步骤12：最终系统配置 ==="
    sed -i "s/Require host localhost/Require all granted/g" /etc/httpd/conf.d/cacti.conf
    systemctl restart httpd >/dev/null 2>&1

    sed -i '/^#\*\/5 \* \* \* \*.*apache.*poller.php/ s/^#//' /etc/cron.d/cacti

    blue "=== 验证Cacti定时任务 ==="
    if grep -E '^\*\/5 \* \* \* \*.*apache.*poller.php' /etc/cron.d/cacti >/dev/null 2>&1; then
        green "✅ Cron任务已取消注释，每5分钟自动采集数据"
    else
        yellow "⚠️  Cron任务修改警告，请手动检查：/etc/cron.d/cacti"
    fi
    green "✅ httpd和Cron任务配置完成"
}

# 步骤13：修复中文乱码
font_config() {
    blue "=== 步骤13：修复中文乱码 ==="
    if ! dnf install -y fontconfig ttmkfdir; then red "❌ 字体依赖安装失败！"; exit 1; fi
    mkdir -p /usr/share/fonts/chinese >/dev/null 2>&1
    if ! cp $FONT_FILE /usr/share/fonts/chinese/; then red "❌ 字体文件复制失败！"; exit 1; fi
    ttmkfdir -e /usr/share/X11/fonts/encodings/encodings.dir >/dev/null 2>&1
    fc-cache -fv >/dev/null 2>&1
    if fc-list | grep "DejaVuSans" >/dev/null 2>&1; then
        green "✅ 中文乱码修复完成"
    else
        yellow "⚠️  字体验证警告（可忽略，不影响Cacti使用）"
    fi
}

# 最终提示
final_tips() {
    blue "=================================================="
    green "🎉 Cacti + Spine 一键安装完成（AlmaLinux 9 + PHP 8.3）"
    blue "=================================================="
    echo "核心访问/配置信息："
    green "1. Cacti访问地址：http://$SERVER_IP/cacti"
    green "   或直接访问：http://$SERVER_IP (已配置自动重定向)"
    green "2. Cacti初始账号：admin / admin（登录后必须修改密码）"
    echo "3. 数据库信息："
    echo "   - MariaDB root密码：$DB_ROOT_PASS"
    echo "   - Cacti数据库用户：cactiuser"
    echo "   - Cacti数据库密码：$CACTI_DB_PASS"
    echo "4. 时间/时区验证："
    echo "   - 系统时区：$(timedatectl | grep "Time zone" | awk -F': ' '{print $2}')"
    echo "   - 系统时间：$(date "+%Y-%m-%d %H:%M:%S %Z")（阿里NTP同步）"
    echo "   - PHP时区：$(php -r 'echo date_default_timezone_get()."\n";')"
    echo "   - MariaDB时区：$(mysql -u root -p"$DB_ROOT_PASS" -e "SELECT @@global.time_zone;" 2>/dev/null | grep -v '@@global.time_zone')"
    green "5. 最后操作：登录Cacti后 → 配置 → 设置 → 轮询器 → 选择「Spine」"
    blue "=================================================="
}

# 主执行流程
main() {
    pre_check
    system_update
    time_sync_config
    basic_config
    repo_config
    httpd_install
    httpd_redirect_config  # <--- 调用新增的重定向配置步骤
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

# 启动主流程
main
