#!/bin/bash
##############################################################################
# Cacti 一站式管理脚本 (安装/备份/恢复/卸载)
# 功能:
#   1. 【集成安装】通过官方脚本一键安装 Cacti。
#   2. 【全量备份】备份数据库、Cacti 核心配置文件、RRD 绘图数据（不包含 Web 服务器配置）。
#   3. 【安全恢复】恢复数据库、配置文件和 RRD 数据，兼容 Apache/Nginx。
#   4. 【终极卸载】智能清理所有组件。
#   5. 【持久化菜单】操作完成后返回主菜单。
#   6. 【详细日志】记录所有操作。
##############################################################################

# ======================== 【配置区】 ========================
DB_NAME="cacti"
DB_USER="cactiuser"
DB_PASS="cactiuser"
DB_SERVICE="mariadb"
BACKUP_DIR="/backup/cacti"
LOG_FILE="${BACKUP_DIR}/cacti_backup_restore.log"

# 备份开关（默认备份 RRD，若空间不足可改为 false）
BACKUP_RRD=true          # 是否备份 RRD 绘图数据（默认 true）
CACTI_CONFIG_FILES=(      # 需要备份的核心配置文件（根据实际路径调整）
    "/usr/share/cacti/include/config.php"
    "/etc/cacti/spine.conf"
)
# =================================================================

# --- 颜色和日志函数 ---
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }

log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local message="[$timestamp] $1"
    echo -e "$message" | tee -a "$LOG_FILE"
}

log_quiet() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# --- Web 服务器检测（仅用于提示） ---
detect_web_server() {
    if systemctl is-active --quiet nginx 2>/dev/null || command -v nginx &>/dev/null; then
        echo "nginx"
    elif systemctl is-active --quiet httpd 2>/dev/null || command -v httpd &>/dev/null; then
        echo "apache"
    else
        echo "unknown"
    fi
}

# --- 依赖检查函数 ---
check_dependencies() {
    log_quiet "===== 开始检查依赖 ====="
    local dependencies=("rsync" "tar" "mktemp" "systemctl" "curl")
    local package_manager=""

    if command -v dnf &> /dev/null; then package_manager="dnf"; fi
    if command -v yum &> /dev/null; then package_manager="yum"; fi
    
    if [ -z "$package_manager" ]; then
        red "❌ 错误：未找到包管理器 (yum/dnf)，无法自动安装依赖。"
        return 1
    fi
    log_quiet "检测到包管理器: $package_manager"

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log "依赖 '$dep' 未安装，正在使用 $package_manager 进行安装..."
            if ! $package_manager install -y "$dep"; then
                red "❌ 错误：安装依赖 '$dep' 失败！"
                return 1
            fi
            green "✅ 依赖 '$dep' 安装成功。"
        else
            log_quiet "依赖 '$dep' 已安装。"
        fi
    done
    log_quiet "===== 依赖检查完成 ====="
    return 0
}

# --- 服务控制函数 ---
stop_services() {
    log_quiet "正在停止相关服务 (httpd, crond, $DB_SERVICE)..."
    systemctl stop httpd crond $DB_SERVICE >/dev/null 2>&1
    log_quiet "服务已停止。"
}

start_services() {
    log_quiet "正在启动相关服务 ($DB_SERVICE, httpd, crond)..."
    systemctl start $DB_SERVICE httpd crond >/dev/null 2>&1
    log_quiet "服务已启动。"
}

# --- 功能1: 安装 Cacti ---
install_cacti() {
    clear
    blue "=================================================="
    echo "              Cacti 一键安装脚本"
    blue "=================================================="
    yellow "⚠️  警告：此操作将从网络下载脚本并以 root 权限执行。"
    echo "安装脚本地址: https://raw.githubusercontent.com/bi4nbn/zabbix/refs/heads/main/cacti/install.sh"
    echo ""
    
    log "===== 开始执行 Cacti 安装脚本 ====="
    if curl -sL https://raw.githubusercontent.com/bi4nbn/zabbix/refs/heads/main/cacti/install.sh | bash; then
        green "🎉 Cacti 安装脚本执行完毕！"
        log "Cacti 安装脚本执行成功。"
    else
        red "❌ Cacti 安装脚本执行失败！请检查日志或网络连接。"
        log "Cacti 安装脚本执行失败。"
    fi
    
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# --- 功能2: 全量备份（含 RRD） ---
perform_backup() {
    clear
    blue "=================================================="
    echo "              Cacti 全量备份 (DB + Configs + RRD)"
    blue "=================================================="
    
    if ! check_dependencies; then
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    # 提示 RRD 可能很大
    if [ "$BACKUP_RRD" = true ]; then
        yellow "📊 注意：RRD 数据可能占用较大空间，请确保 $BACKUP_DIR 有足够容量。"
        echo ""
    fi

    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
    fi

    log "===== 开始全量备份 ====="
    local timestamp=$(date "+%Y%m%d_%H%M%S")
    local backup_filename="cacti_backup_${timestamp}.tar.gz"
    local full_backup_path="${BACKUP_DIR}/${backup_filename}"
    local temp_dir=$(mktemp -d)

    # 1. 备份数据库
    log "正在备份数据库 '$DB_NAME'..."
    if ! mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "${temp_dir}/database.sql" 2>> "$LOG_FILE"; then
        red "❌ 数据库备份失败！请检查数据库凭据和服务状态。"
        rm -rf "$temp_dir"
        log "备份失败，已清理临时文件。"
    else
        # 2. 备份配置文件
        log "正在备份 Cacti 核心配置文件..."
        local config_dir="${temp_dir}/configs"
        mkdir -p "$config_dir"
        for conf in "${CACTI_CONFIG_FILES[@]}"; do
            if [ -f "$conf" ]; then
                cp --parents "$conf" "$config_dir" 2>> "$LOG_FILE"
                log "备份配置文件: $conf"
            else
                yellow "⚠️  配置文件不存在: $conf，跳过"
            fi
        done

        # 3. 备份 RRD（默认开启）
        if [ "$BACKUP_RRD" = true ] && [ -d "/var/lib/cacti/rra" ]; then
            log "正在备份 RRD 数据（可能较大，请耐心等待）..."
            rsync -a --delete "/var/lib/cacti/rra/" "${temp_dir}/rra/" >> "$LOG_FILE" 2>&1
            green "✅ RRD 数据备份完成。"
        else
            if [ "$BACKUP_RRD" = false ]; then
                log "跳过 RRD 备份 (BACKUP_RRD=false)"
            else
                yellow "⚠️  RRD 目录不存在，跳过。"
            fi
        fi

        # 4. 打包
        log "正在打包备份文件..."
        if tar -czf "$full_backup_path" -C "$temp_dir" . >> "$LOG_FILE" 2>&1; then
            green "🎉 全量备份成功！文件已保存至: ${full_backup_path}"
            log "备份成功: ${full_backup_path}"
        else
            red "❌ 打包备份文件失败！"
            log "打包备份文件失败。"
        fi
        rm -rf "$temp_dir"
    fi
    
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# --- 功能3: 全量恢复 ---
perform_restore() {
    clear
    blue "=================================================="
    echo "              Cacti 全量恢复 (DB + Configs + RRD)"
    blue "=================================================="

    if ! check_dependencies; then
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    # 查找所有备份文件并按时间倒序排序
    mapfile -t BACKUP_FILES < <(ls -tp "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | grep -v '/$')
    
    if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
        red "❌ 错误：在 $BACKUP_DIR 目录中未找到任何备份文件。"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    # --- 分页选择逻辑（保持不变） ---
    local selected_file=""
    local ITEMS_PER_PAGE=10
    local current_page=0
    local total_pages=$(( (${#BACKUP_FILES[@]} + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))

    while true; do
        clear
        blue "=================================================="
        echo "              Cacti 全量恢复 - 选择备份"
        blue "=================================================="
        echo "📂 共找到 ${#BACKUP_FILES[@]} 个备份文件。 (第 $((current_page + 1)) / $total_pages 页)"
        echo ""
        
        local start_index=$(( current_page * ITEMS_PER_PAGE ))
        local end_index=$(( start_index + ITEMS_PER_PAGE - 1 ))
        if [ $end_index -ge ${#BACKUP_FILES[@]} ]; then
            end_index=$(( ${#BACKUP_FILES[@]} - 1 ))
        fi

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
        echo "操作提示:"
        echo "  输入数字选择文件 | 'n' 下一页 | 'p' 上一页 | 'q' 取消"
        blue "--------------------------------------------------"
        
        read -p "请输入您的选择: " user_choice

        if [[ "$user_choice" =~ ^[0-9]+$ ]]; then
            if [ "$user_choice" -ge 1 ] && [ "$user_choice" -le $((end_index - start_index + 1)) ]; then
                local selected_index=$(( start_index + user_choice - 1 ))
                selected_file="${BACKUP_FILES[$selected_index]}"
                break
            else
                red "\n⚠️  无效的数字，请输入当前页列出的选项。"
                sleep 1.5
            fi
        elif [[ "$user_choice" == "n" || "$user_choice" == "N" ]]; then
            if [ $current_page -lt $((total_pages - 1)) ]; then
                ((current_page++))
            else
                red "\n⚠️  已经是最后一页了。"
                sleep 1.5
            fi
        elif [[ "$user_choice" == "p" || "$user_choice" == "P" ]]; then
            if [ $current_page -gt 0 ]; then
                ((current_page--))
            else
                red "\n⚠️  已经是第一页了。"
                sleep 1.5
            fi
        elif [[ "$user_choice" == "q" || "$user_choice" == "Q" ]]; then
            log "用户取消了恢复操作。"
            main_menu
            return
        else
            red "\n⚠️  无效的输入，请重试。"
            sleep 1.5
        fi
    done

    # 确认选择
    echo ""
    yellow "您选择恢复的文件是: $(basename "$selected_file")"
    read -p "是否确认恢复此文件? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "用户确认环节取消了恢复操作。"
        main_menu
        return
    fi

    # --- 开始恢复 ---
    log "===== 开始全量恢复 ====="
    log "选择恢复的文件: $selected_file"
    local temp_dir=$(mktemp -d)

    stop_services

    log "正在解压备份文件..."
    if ! tar -xzf "$selected_file" -C "$temp_dir" >> "$LOG_FILE" 2>&1; then
        red "❌ 解压备份文件失败！文件可能已损坏。"
        log "解压备份文件失败。"
        start_services
        rm -rf "$temp_dir"
    else
        # 1. 恢复数据库
        log "正在恢复数据库..."
        systemctl start $DB_SERVICE >/dev/null 2>&1
        mysql -u"$DB_USER" -p"$DB_PASS" -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >> "$LOG_FILE" 2>&1
        if mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "${temp_dir}/database.sql" >> "$LOG_FILE" 2>&1; then
            green "✅ 数据库恢复成功。"
            log "数据库恢复成功。"
        else
            red "❌ 数据库恢复失败！"
            log "数据库恢复失败。"
        fi

        # 2. 恢复配置文件
        if [ -d "${temp_dir}/configs" ]; then
            log "正在恢复 Cacti 核心配置文件..."
            cp -r "${temp_dir}/configs/"* / 2>> "$LOG_FILE"
            green "✅ 配置文件恢复完成。"
            log "配置文件恢复完成。"
        else
            yellow "⚠️  备份中无配置文件目录，跳过。"
            log "备份中无配置文件目录。"
        fi

        # 3. 恢复 RRD（如有）
        if [ -d "${temp_dir}/rra" ]; then
            log "正在恢复 RRD 数据..."
            rsync -a --delete "${temp_dir}/rra/" "/var/lib/cacti/rra/" >> "$LOG_FILE" 2>&1
            green "✅ RRD 数据恢复完成。"
            log "RRD 数据恢复完成。"
        else
            yellow "⚠️  备份中无 RRD 数据，跳过。"
            log "备份中无 RRD 数据。"
        fi

        green "🎉 全量恢复流程完成！"
        log "全量恢复完成。"
        echo ""
        local web_server=$(detect_web_server)
        yellow "检测到当前 Web 服务器: $web_server"
        echo "请手动检查并配置 Web 服务器（Apache/Nginx）的虚拟主机指向 Cacti 目录，"
        echo "并确保 PHP 扩展和数据库连接信息正确。"
    fi

    rm -rf "$temp_dir"
    start_services
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# --- 功能4: 卸载 Cacti ---
uninstall_cacti() {
    clear
    red "=================================================="
    echo "           !!! DANGER: Cacti 卸载 !!!"
    red "=================================================="
    red "此操作将彻底删除 Cacti 及其所有相关组件！"
    red "包括：数据库、RRD文件、程序文件、依赖包、系统配置和 MariaDB 数据目录。"
    echo ""
    yellow "为保护您的数据，脚本将首先尝试创建一个最后的备份。"
    
    read -p "是否继续? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "用户取消了卸载操作。"
        echo "卸载已取消。"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    # 1. 最后一次备份
    log "===== 开始执行卸载前的最后一次备份 ====="
    if check_dependencies; then
        local timestamp=$(date "+%Y%m%d_%H%M%S")
        local backup_filename="cacti_uninstall_backup_${timestamp}.tar.gz"
        local full_backup_path="${BACKUP_DIR}/${backup_filename}"
        local temp_dir=$(mktemp -d)
        
        if mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "${temp_dir}/database.sql" 2>> "$LOG_FILE"; then
            rsync -a --delete "/var/lib/cacti/rra/" "${temp_dir}/rra/" >> "$LOG_FILE" 2>&1
            rsync -a --delete "/usr/share/cacti/" "${temp_dir}/web/" >> "$LOG_FILE" 2>&1
            tar -czf "$full_backup_path" -C "$temp_dir" . >> "$LOG_FILE" 2>&1
            green "✅ 卸载前备份成功！文件已保存至: ${full_backup_path}"
            log "卸载前备份成功: ${full_backup_path}"
        else
            yellow "⚠️  警告：卸载前备份数据库失败！卸载将继续，但您将失去数据。"
            log "卸载前备份数据库失败！"
        fi
        rm -rf "$temp_dir"
    else
        yellow "⚠️  警告：缺少依赖，无法创建卸载前备份！卸载将继续，但您将失去数据。"
        log "缺少依赖，无法创建卸载前备份。"
    fi
    
    echo ""
    red "=================================================="
    echo "           !!! FINAL WARNING: CONFIRM !!!"
    red "=================================================="
    red "您确定要永久删除 Cacti 及其所有依赖吗？此操作不可逆转！"
    read -p "请输入 'UNINSTALL' 以确认卸载: " final_confirm
    if [ "$final_confirm" != "UNINSTALL" ]; then
        log "用户未能正确确认，卸载操作已中止。"
        echo "卸载已中止。"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    # 2. 执行终极卸载
    log "===== 开始执行 Cacti 终极卸载 ====="
    
    # 停止所有相关服务
    log "正在停止所有相关服务..."
    systemctl stop httpd mariadb snmpd  >/dev/null 2>&1
    systemctl disable httpd mariadb snmpd  >/dev/null 2>&1

    # 卸载所有相关的包
    log "正在卸载所有相关软件包..."
    dnf remove -y cacti cacti-spine httpd mariadb-server php\* net-snmp\* rrdtool\* >/dev/null 2>&1
    # 清理不再需要的依赖
    dnf autoremove -y >/dev/null 2>&1

    # 删除残留的文件和目录 (包含 MariaDB 数据目录)
    log "正在清理残留文件和目录..."
    rm -rf /var/lib/cacti
    rm -rf /usr/share/cacti
    rm -rf /etc/cacti
    rm -rf /etc/spine.conf
    rm -rf /etc/httpd/conf.d/cacti.conf
    rm -rf /etc/httpd/conf.d/redirects.conf
    rm -rf /etc/cron.d/cacti
    rm -rf /var/log/cacti
    rm -rf /var/lib/mysql  
    rm -rf /etc/my.cnf
    rm -rf /etc/my.cnf.d
    rm -rf /etc/php.ini
    rm -rf /etc/php.d

    log "🎉 Cacti 终极卸载完成！"
    green "🎉 Cacti 终极卸载完成！"
    
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# --- 主菜单 ---
main_menu() {
    clear
    blue "=================================================="
    green "           Cacti 一站式管理工具箱"
    blue "=================================================="
    echo "  (1) 安装 Cacti"
    echo "  (2) 备份 Cacti (全量: DB + Configs + RRD)"
    echo "  (3) 恢复 Cacti (全量: DB + Configs + RRD)"
    echo "  (4) 卸载 Cacti"
    echo "  (5) 退出脚本"
    blue "=================================================="
    read -p "请输入您的选择 [1-5]: " choice

    case $choice in
        1) install_cacti ;;
        2) perform_backup ;;
        3) perform_restore ;;
        4) uninstall_cacti ;;
        5)
            log "用户选择退出脚本。"
            green "感谢使用，再见！"
            exit 0
            ;;
        *)
            red "无效的选项，请输入 1-5 之间的数字。"
            sleep 2
            main_menu
            ;;
    esac
}

# --- 脚本入口 ---
if [ "$(id -u)" -ne 0 ]; then
    red "❌ 错误：此脚本需要 root 权限来执行。"
    exit 1
fi

# 确保日志目录存在
mkdir -p "$BACKUP_DIR"

# 启动主菜单
main_menu
