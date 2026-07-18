#!/bin/bash
##############################################################################
# Cacti 一站式管理脚本 (安装/备份/恢复/卸载)
# 功能:
#   1. 【集成安装】通过官方脚本一键安装 Cacti。
#   2. 【全量备份】备份数据库、Cacti 核心配置文件、RRD 绘图数据。
#   3. 【安全恢复】恢复数据库、配置文件和 RRD 数据，兼容 Apache/Nginx。
#       - 恢复前可修改数据库配置（库名/用户/密码）。
#       - 恢复前可清理超过指定天数的旧备份。
#   4. 【终极卸载】智能清理所有组件。
#   5. 【持久化菜单】操作完成后返回主菜单。
#   6. 【详细日志】记录所有操作。
##############################################################################

set -e
set -o pipefail

# ======================== 【配置区】 ========================
DB_NAME="cacti"
DB_USER="cactiuser"
DB_PASS="cactiuser"
DB_SERVICE="mariadb"
BACKUP_DIR="/backup/cacti"
LOG_FILE="${BACKUP_DIR}/cacti_backup_restore.log"

BACKUP_RRD=true
BACKUP_RETENTION_DAYS=30

CACTI_CONFIG_FILES=(
    "/usr/share/cacti/include/config.php"
    "/etc/spine.conf"
)
RRD_DIR="/usr/share/cacti/rra"
# =================================================================

# --- 颜色和日志函数 ---
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }

log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "[$timestamp] $1" | tee -a "$LOG_FILE"
}

log_quiet() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# --- Web 服务器检测 ---
detect_web_server() {
    if systemctl is-active --quiet nginx 2>/dev/null || command -v nginx &>/dev/null; then
        echo "nginx"
    elif systemctl is-active --quiet httpd 2>/dev/null || command -v httpd &>/dev/null; then
        echo "apache"
    else
        echo "unknown"
    fi
}

# --- 依赖检查 ---
check_dependencies() {
    log_quiet "===== 检查依赖 ====="
    local dependencies=("rsync" "tar" "mktemp" "systemctl" "curl" "mysql" "mysqldump")
    local package_manager=""
    command -v dnf &>/dev/null && package_manager="dnf"
    command -v yum &>/dev/null && package_manager="yum"
    [ -z "$package_manager" ] && { red "❌ 未找到包管理器。"; return 1; }
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            log "安装依赖 '$dep'..."
            $package_manager install -y "$dep" >/dev/null 2>&1 || { red "❌ 安装失败"; return 1; }
            green "✅ 安装成功。"
        fi
    done
    return 0
}

# --- 测试数据库连接 ---
test_db_connection() {
    log_quiet "测试数据库连接..."
    mysql -u"$DB_USER" -p"$DB_PASS" -e "SELECT 1" &>/dev/null || { red "❌ 数据库连接失败。"; return 1; }
    return 0
}

# --- 服务控制 ---
stop_services() {
    log_quiet "停止服务..."
    local web=$(detect_web_server)
    case "$web" in
        nginx) systemctl stop nginx 2>/dev/null || true ;;
        apache) systemctl stop httpd 2>/dev/null || true ;;
    esac
    systemctl stop crond "$DB_SERVICE" 2>/dev/null || true
}

start_services() {
    log_quiet "启动服务..."
    systemctl start "$DB_SERVICE" 2>/dev/null || true
    local web=$(detect_web_server)
    case "$web" in
        nginx) systemctl start nginx 2>/dev/null || true ;;
        apache) systemctl start httpd 2>/dev/null || true ;;
    esac
    systemctl start crond 2>/dev/null || true
}

# --- 清理旧备份（用户确认后执行） ---
cleanup_old_backups() {
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "备份目录不存在，跳过清理。"
        return
    fi
    local count=$(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" -type f -mtime +"$BACKUP_RETENTION_DAYS" 2>/dev/null | wc -l)
    if [ "$count" -eq 0 ]; then
        green "✅ 没有超过 ${BACKUP_RETENTION_DAYS} 天的旧备份文件。"
        return
    fi
    echo ""
    yellow "📋 发现 $count 个超过 ${BACKUP_RETENTION_DAYS} 天的备份文件。"
    read -p "确定要删除这些旧备份吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" -type f -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -f {} \;
        green "✅ 已删除 $count 个旧备份文件。"
        log "手动清理了 $count 个超过 ${BACKUP_RETENTION_DAYS} 天的备份。"
    else
        green "⏭️  跳过清理。"
    fi
}

# --- 显示备份统计 ---
show_backup_stats() {
    if [ -d "$BACKUP_DIR" ]; then
        local count=$(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" -type f 2>/dev/null | wc -l)
        local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        echo ""
        green "📊 备份目录: $count 个文件，总大小 $total_size"
    fi
}

# ========== 功能函数 ==========

install_cacti() {
    clear
    blue "=================================================="
    echo "              Cacti 一键安装"
    blue "=================================================="
    yellow "⚠️  将从网络下载脚本并以 root 执行。"
    echo "地址: https://raw.githubusercontent.com/bi4nbn/zabbix/refs/heads/main/cacti/install.sh"
    echo ""
    log "执行安装脚本..."
    if curl -sL https://raw.githubusercontent.com/bi4nbn/zabbix/refs/heads/main/cacti/install.sh | bash; then
        green "🎉 安装完成！"
        log "安装成功。"
    else
        red "❌ 安装失败！"
        log "安装失败。"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回..."
    main_menu
}

perform_backup() {
    clear
    blue "=================================================="
    echo "              Cacti 全量备份"
    blue "=================================================="

    if ! check_dependencies || ! test_db_connection; then
        echo ""
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return
    fi

    if [ "$BACKUP_RRD" = true ] && [ -d "$RRD_DIR" ]; then
        yellow "📊 RRD 数据可能较大，请确保 $BACKUP_DIR 有足够空间。"
        echo ""
    fi

    mkdir -p "$BACKUP_DIR"
    log "===== 开始全量备份 ====="
    local timestamp=$(date "+%Y%m%d_%H%M%S")
    local backup_filename="cacti_backup_${timestamp}.tar.gz"
    local full_backup_path="${BACKUP_DIR}/${backup_filename}"
    local temp_dir=$(mktemp -d)

    # 备份数据库
    log "备份数据库..."
    if ! mysqldump -u"$DB_USER" -p"$DB_PASS" --single-transaction --routines --triggers "$DB_NAME" > "${temp_dir}/database.sql" 2>> "$LOG_FILE"; then
        red "❌ 数据库备份失败！"
        rm -rf "$temp_dir"
        log "备份失败。"
        echo ""
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return
    fi

    # 备份配置文件
    log "备份配置文件..."
    local config_dir="${temp_dir}/configs"
    mkdir -p "$config_dir"
    for conf in "${CACTI_CONFIG_FILES[@]}"; do
        if [ -f "$conf" ]; then
            cp --parents "$conf" "$config_dir" 2>> "$LOG_FILE"
            log "备份: $conf"
        else
            yellow "⚠️  配置文件不存在: $conf，跳过"
        fi
    done

    # 备份 RRD
    if [ "$BACKUP_RRD" = true ] && [ -d "$RRD_DIR" ]; then
        log "备份 RRD 数据（可能需要较长时间）..."
        rsync -a --delete "$RRD_DIR/" "${temp_dir}/rra/" >> "$LOG_FILE" 2>&1
        green "✅ RRD 备份完成。"
    else
        [ "$BACKUP_RRD" = false ] && log "跳过 RRD 备份" || yellow "⚠️  RRD 目录不存在，跳过。"
    fi

    # 打包
    log "正在打包..."
    if tar -czf "$full_backup_path" -C "$temp_dir" . 2>> "$LOG_FILE"; then
        local backup_size=$(du -h "$full_backup_path" | cut -f1)
        green "🎉 备份成功！文件: ${full_backup_path} (大小: $backup_size)"
        log "备份成功: ${full_backup_path} (大小: $backup_size)"
    else
        red "❌ 打包失败！"
        log "打包失败。"
        rm -rf "$temp_dir"
        echo ""
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return
    fi
    rm -rf "$temp_dir"

    show_backup_stats
    echo ""
    read -n 1 -s -r -p "按任意键返回..."
    main_menu
}

perform_restore() {
    clear
    blue "=================================================="
    echo "              Cacti 全量恢复"
    blue "=================================================="

    if ! check_dependencies; then
        echo ""
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return
    fi

    # ---------- 数据库配置确认（密码明文） ----------
    echo ""
    yellow "当前数据库配置："
    echo "  数据库名: $DB_NAME"
    echo "  用户名: $DB_USER"
    echo "  密码: $DB_PASS"
    echo ""
    read -p "是否使用以上配置继续？(y/N): " use_default
    if [[ ! "$use_default" =~ ^[Yy]$ ]]; then
        echo ""
        read -p "请输入数据库名 (默认: cacti): " new_db
        [ -n "$new_db" ] && DB_NAME="$new_db"
        read -p "请输入数据库用户名 (默认: cactiuser): " new_user
        [ -n "$new_user" ] && DB_USER="$new_user"
        read -p "请输入数据库密码: " new_pass
        echo ""
        [ -n "$new_pass" ] && DB_PASS="$new_pass"
        log "用户修改了数据库配置: DB_NAME=$DB_NAME, DB_USER=$DB_USER"
    fi

    # 测试数据库连接
    if ! test_db_connection; then
        red "❌ 数据库连接失败，请检查配置。"
        echo ""
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return
    fi

    # ---------- 清理询问 ----------
    echo ""
    yellow "🔄 是否清理超过 ${BACKUP_RETENTION_DAYS} 天的旧备份文件？"
    read -p "输入 y 执行清理，其他键跳过: " clean_choice
    if [[ "$clean_choice" =~ ^[Yy]$ ]]; then
        cleanup_old_backups
    else
        green "⏭️  跳过清理。"
    fi
    echo ""

    # 列出备份文件
    mapfile -t BACKUP_FILES < <(ls -tp "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | grep -v '/$')
    if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
        red "❌ 未找到任何备份文件。"
        echo ""
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return
    fi

    # 分页选择备份文件
    local selected_file=""
    local ITEMS_PER_PAGE=10
    local current_page=0
    local total_pages=$(( (${#BACKUP_FILES[@]} + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))

    while true; do
        clear
        blue "=================================================="
        echo "              Cacti 恢复 - 选择备份"
        blue "=================================================="
        echo "📂 共 ${#BACKUP_FILES[@]} 个备份 (第 $((current_page + 1)) / $total_pages 页)"
        echo ""
        local start_index=$(( current_page * ITEMS_PER_PAGE ))
        local end_index=$(( start_index + ITEMS_PER_PAGE - 1 ))
        [ $end_index -ge ${#BACKUP_FILES[@]} ] && end_index=$(( ${#BACKUP_FILES[@]} - 1 ))

        local option_number=1
        for ((i = start_index; i <= end_index; i++)); do
            local file="${BACKUP_FILES[$i]}"
            local file_size=$(du -h "$file" | cut -f1)
            local file_date=$(date -r "$file" +"%Y-%m-%d %H:%M:%S")
            printf "  [%d]  %-60s %8s  %s\n" "$option_number" "$(basename "$file")" "$file_size" "$file_date"
            ((option_number++))
        done

        echo ""
        blue "--------------------------------------------------"
        echo "  输入数字选择 | n下一页 p上一页 q取消"
        blue "--------------------------------------------------"
        read -p "请输入选择: " user_choice

        if [[ "$user_choice" =~ ^[0-9]+$ ]]; then
            if [ "$user_choice" -ge 1 ] && [ "$user_choice" -le $((end_index - start_index + 1)) ]; then
                selected_index=$(( start_index + user_choice - 1 ))
                selected_file="${BACKUP_FILES[$selected_index]}"
                break
            else
                red "无效数字"
                sleep 1.5
            fi
        elif [[ "$user_choice" == "n" || "$user_choice" == "N" ]]; then
            [ $current_page -lt $((total_pages - 1)) ] && ((current_page++)) || { red "已是最后一页"; sleep 1.5; }
        elif [[ "$user_choice" == "p" || "$user_choice" == "P" ]]; then
            [ $current_page -gt 0 ] && ((current_page--)) || { red "已是第一页"; sleep 1.5; }
        elif [[ "$user_choice" == "q" || "$user_choice" == "Q" ]]; then
            log "取消恢复"
            main_menu
            return
        else
            red "无效输入"
            sleep 1.5
        fi
    done

    echo ""
    yellow "选择恢复: $(basename "$selected_file")"

    # 验证完整性
    log "验证备份文件完整性..."
    if ! tar -tzf "$selected_file" >/dev/null 2>&1; then
        red "❌ 备份文件损坏！"
        log "完整性检查失败。"
        echo ""
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return
    fi
    green "✅ 完整性检查通过。"

    read -p "⚠️  恢复将覆盖现有数据，是否继续? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { log "取消恢复"; main_menu; return; }

    log "===== 开始恢复 ====="
    local temp_dir=$(mktemp -d)
    stop_services

    log "解压备份..."
    if ! tar -xzf "$selected_file" -C "$temp_dir" >> "$LOG_FILE" 2>&1; then
        red "❌ 解压失败！"
        start_services
        rm -rf "$temp_dir"
        echo ""
        read -n 1 -s -r -p "按任意键返回..."
        main_menu
        return
    fi

    # 恢复数据库
    log "恢复数据库..."
    systemctl start "$DB_SERVICE" 2>/dev/null || true
    mysql -u"$DB_USER" -p"$DB_PASS" -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >> "$LOG_FILE" 2>&1
    if mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "${temp_dir}/database.sql" >> "$LOG_FILE" 2>&1; then
        green "✅ 数据库恢复成功。"
    else
        red "❌ 数据库恢复失败！"
    fi

    # 恢复配置文件
    if [ -d "${temp_dir}/configs" ]; then
        log "恢复配置文件..."
        cp -a "${temp_dir}/configs/"* / 2>> "$LOG_FILE"
        green "✅ 配置文件恢复完成。"
    else
        yellow "⚠️  备份中无配置文件。"
    fi

    # 恢复 RRD
    if [ -d "${temp_dir}/rra" ]; then
        log "恢复 RRD 数据..."
        mkdir -p "$RRD_DIR"
        rsync -a --delete "${temp_dir}/rra/" "$RRD_DIR/" >> "$LOG_FILE" 2>&1
        green "✅ RRD 恢复完成。"
    else
        yellow "⚠️  备份中无 RRD 数据。"
    fi

    # 权限修复
    chown -R nginx:nginx "$RRD_DIR" 2>/dev/null || chown -R apache:apache "$RRD_DIR" 2>/dev/null || true
    chmod -R 775 "$RRD_DIR" 2>/dev/null || true

    green "🎉 恢复完成！"
    log "恢复完成。"
    echo ""
    local web_server=$(detect_web_server)
    yellow "当前 Web 服务器: $web_server，请检查配置。"

    rm -rf "$temp_dir"
    start_services
    echo ""
    read -n 1 -s -r -p "按任意键返回..."
    main_menu
}

uninstall_cacti() {
    clear
    red "=================================================="
    echo "           !!! DANGER: Cacti 卸载 !!!"
    red "=================================================="
    red "此操作将彻底删除 Cacti 及所有相关组件！"
    echo ""
    yellow "将尝试创建最后的备份。"
    read -p "是否继续? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { log "取消卸载"; main_menu; return; }

    # 最后一次备份
    log "执行卸载前备份..."
    if check_dependencies && test_db_connection; then
        local timestamp=$(date "+%Y%m%d_%H%M%S")
        local backup_filename="cacti_uninstall_backup_${timestamp}.tar.gz"
        local full_backup_path="${BACKUP_DIR}/${backup_filename}"
        local temp_dir=$(mktemp -d)
        if mysqldump -u"$DB_USER" -p"$DB_PASS" --single-transaction "$DB_NAME" > "${temp_dir}/database.sql" 2>> "$LOG_FILE"; then
            [ -d "$RRD_DIR" ] && rsync -a --delete "$RRD_DIR/" "${temp_dir}/rra/" >> "$LOG_FILE" 2>&1
            cp -r /usr/share/cacti "${temp_dir}/web" 2>> "$LOG_FILE" || true
            tar -czf "$full_backup_path" -C "$temp_dir" . >> "$LOG_FILE" 2>&1
            green "✅ 备份成功: ${full_backup_path}"
        else
            yellow "⚠️  数据库备份失败，继续卸载。"
        fi
        rm -rf "$temp_dir"
    else
        yellow "⚠️  无法创建备份，继续卸载。"
    fi

    echo ""
    red "确认卸载：请输入 'UNINSTALL'"
    read -p "> " final_confirm
    [ "$final_confirm" != "UNINSTALL" ] && { log "取消卸载"; main_menu; return; }

    log "开始终极卸载..."
    systemctl stop nginx httpd mariadb snmpd crond 2>/dev/null || true
    systemctl disable nginx httpd mariadb snmpd 2>/dev/null || true

    dnf remove -y cacti cacti-spine httpd mariadb-server php\* net-snmp\* rrdtool\* nginx 2>/dev/null || yum remove -y cacti cacti-spine httpd mariadb-server php\* net-snmp\* rrdtool\* nginx 2>/dev/null || true
    dnf autoremove -y 2>/dev/null || yum autoremove -y 2>/dev/null || true

    rm -rf /usr/share/cacti /etc/cacti /etc/spine.conf /etc/httpd/conf.d/cacti.conf /etc/httpd/conf.d/redirects.conf /etc/cron.d/cacti /var/log/cacti /var/lib/mysql /etc/my.cnf /etc/my.cnf.d /etc/php.ini /etc/php.d
    rm -f /etc/nginx/conf.d/cacti.conf /etc/nginx/sites-enabled/cacti 2>/dev/null || true

    green "🎉 卸载完成！"
    log "卸载完成。"
    echo ""
    read -n 1 -s -r -p "按任意键返回..."
    main_menu
}

main_menu() {
    clear
    blue "=================================================="
    green "           Cacti 一站式管理工具箱"
    blue "=================================================="
    echo "  (1) 安装 Cacti"
    echo "  (2) 备份 Cacti"
    echo "  (3) 恢复 Cacti"
    echo "  (4) 卸载 Cacti"
    echo "  (5) 退出脚本"
    blue "=================================================="
    read -p "请输入选择 [1-5]: " choice
    case $choice in
        1) install_cacti ;;
        2) perform_backup ;;
        3) perform_restore ;;
        4) uninstall_cacti ;;
        5) log "退出脚本。"; green "再见！"; exit 0 ;;
        *) red "无效选项。"; sleep 2; main_menu ;;
    esac
}

# --- 入口 ---
if [ "$(id -u)" -ne 0 ]; then
    red "❌ 需要 root 权限。"
    exit 1
fi
mkdir -p "$BACKUP_DIR"
main_menu
