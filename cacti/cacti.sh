#!/bin/bash
##############################################################################
# Cacti 一站式管理脚本 (最终版)
# 功能:
#   1. 【集成安装】通过官方脚本一键安装 Cacti。
#   2. 【最简化备份】备份数据库、RRD文件、程序和核心配置。
#   3. 【精准恢复】在全新环境上恢复 Cacti 数据和配置。
#      - 恢复逻辑：删除旧库，直接导入备份。
#   4. 【精准卸载】仅卸载 Cacti 及其 LAMP 运行环境，不影响系统其他部分。
#      - 安全卸载：不会禁用系统级 crond 服务。
#      - 彻底清理：删除 MariaDB/MySQL、PHP、Apache 等相关程序和配置。
#   5. 【静默更新】输入选项 '5' 后直接从指定 URL 下载并更新脚本。
#   6. 【持久化菜单】操作完成后返回主菜单，方便连续管理。
#   7. 【详细日志】所有操作记录在 /backup/cacti/cacti_backup_restore.log。
#   8. 【简洁输出】屏幕只显示关键信息，过程细节记录在日志中。
#   9. 【自动快捷方式】首次运行后，自动创建 'cacti' 命令，方便后续调用。
#
# ⚠️  安全警告:
#   - 脚本包含数据库密码明文，且执行 root 权限操作。
#   - 请严格限制此脚本的访问权限。
#   - 建议权限: chmod 700 cacti_tool.sh
##############################################################################

# ======================== 【配置区】 ========================
DB_NAME="cacti"
DB_USER="cactiuser"
DB_PASS="cactiuser"
DB_SERVICE="mariadb"
BACKUP_DIR="/backup/cacti"
LOG_FILE="${BACKUP_DIR}/cacti_backup_restore.log"
SCRIPT_URL="https://raw.githubusercontent.com/bi4nbn/zabbix/refs/heads/main/cacti/cacti.sh"
SCRIPT_VERSION="0.1.1"
# =================================================================

# --- 颜色和日志函数 ---
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }
purple() { echo -e "\033[35m$1\033[0m"; }
cyan() { echo -e "\033[36m$1\033[0m"; }
gray() { echo -e "\033[90m$1\033[0m"; }
bold() { echo -e "\033[1m$1\033[0m"; }

log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local message="[$timestamp] $1"
    echo -e "$message" | tee -a "$LOG_FILE"
}

log_quiet() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" >> "$LOG_FILE"
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
    log_quiet "正在停止相关服务 (httpd, crond)..."
    systemctl stop httpd crond >/dev/null 2>&1
    log_quiet "服务已停止。"
}

start_services() {
    log_quiet "正在启动相关服务 (httpd, crond)..."
    systemctl start httpd crond >/dev/null 2>&1
    log_quiet "服务已启动。"
}

# --- 功能1: 安装 Cacti ---
install_cacti() {
    clear
    blue "=================================================="
    echo "              Cacti 一键安装"
    blue "=================================================="
    yellow "⚠️  警告：此操作将从网络下载脚本并以 root 权限执行。"
    echo "安装脚本地址: https://raw.githubusercontent.com/bi4nbn/zabbix/refs/heads/main/cacti/install.sh"
    echo ""
    
    read -p "是否继续安装? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "===== 开始执行 Cacti 安装脚本 ====="
        if curl -sL https://raw.githubusercontent.com/bi4nbn/zabbix/refs/heads/main/cacti/install.sh | bash; then
            green "🎉 Cacti 安装脚本执行完毕！"
            log "Cacti 安装脚本执行成功。"
        else
            red "❌ Cacti 安装脚本执行失败！请检查日志或网络连接。"
            log "Cacti 安装脚本执行失败。"
        fi
    else
        log "用户取消了 Cacti 安装操作。"
        echo "安装已取消。"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# --- 功能2: Cacti 最简化备份 ---
perform_backup() {
    clear
    blue "=================================================="
    echo "           Cacti 最简化备份"
    blue "=================================================="
    
    if ! check_dependencies; then
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    if [ ! -d "$BACKUP_DIR" ]; then
        log "备份目录 $BACKUP_DIR 不存在，正在创建..."
        mkdir -p "$BACKUP_DIR"
    fi

    log "===== 开始执行 Cacti 最简化备份 ====="
    local timestamp=$(date "+%Y%m%d_%H%M%S")
    local backup_filename="cacti_minimal_backup_${timestamp}.tar.gz"
    local full_backup_path="${BACKUP_DIR}/${backup_filename}"
    local temp_dir=$(mktemp -d)

    # 1. 备份数据库
    log "正在备份 Cacti 数据库..."
    if ! mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "${temp_dir}/cacti_database.sql" 2>> "$LOG_FILE"; then
        red "❌ 数据库备份失败！请检查数据库凭据和服务状态。"
        rm -rf "$temp_dir"
        log "备份失败，已清理临时文件。"
    else
        # 2. 备份 RRD 数据文件
        log "正在备份 RRD 数据文件..."
        rsync -a --delete "/var/lib/cacti/rra/" "${temp_dir}/rra/" >> "$LOG_FILE" 2>&1
        
        # 3. 备份 Cacti 程序文件
        log "正在备份 Cacti 程序文件..."
        rsync -a --delete "/usr/share/cacti/" "${temp_dir}/cacti_web/" >> "$LOG_FILE" 2>&1
        
        # 4. 备份 Cacti 配置文件
        log "正在备份 Cacti 配置文件..."
        mkdir -p "${temp_dir}/configs"
        [ -f "/etc/cacti/db.php" ] && cp "/etc/cacti/db.php" "${temp_dir}/configs/"
        [ -f "/etc/spine.conf" ] && cp "/etc/spine.conf" "${temp_dir}/configs/"

        # 5. 打包所有备份内容
        log "正在打包备份文件..."
        if tar -czf "$full_backup_path" -C "$temp_dir" . >> "$LOG_FILE" 2>&1; then
            green "🎉 最简化备份成功！文件已保存至: ${full_backup_path}"
            log "Cacti 最简化备份成功。"
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

# --- 功能3: Cacti 精准恢复 (最终简化版) ---
perform_restore() {
    clear
    blue "=================================================="
    echo "              Cacti 精准恢复"
    blue "=================================================="
    yellow "⚠️  重要提示：此操作将覆盖当前 Cacti 环境！"
    yellow "   请确保目标服务器已通过官方脚本安装了一个全新的 Cacti。"
    echo ""

    if ! check_dependencies; then
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    mapfile -t BACKUP_FILES < <(ls -tp "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | grep -v '/$' | sort -r)
    if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
        red "❌ 错误：在 $BACKUP_DIR 目录中未找到任何备份文件。"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    echo "请选择要恢复的备份文件："
    select selected_file in "${BACKUP_FILES[@]}" "取消"; do
        if [ -n "$selected_file" ]; then
            if [ "$selected_file" = "取消" ]; then
                log "用户取消了恢复操作。"
                main_menu
                return
            fi
            break
        else
            red "无效的选择，请重试。"
        fi
    done

    read -p "您确定要使用 '$selected_file' 恢复 Cacti 吗？此操作不可逆转！(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "用户取消了恢复操作。"
        echo "恢复已取消。"
        main_menu
        return
    fi

    log "===== 开始执行 Cacti 精准恢复 ====="
    log "选择恢复的文件: $selected_file"
    local temp_dir=$(mktemp -d)

    stop_services

    log "正在解压备份文件..."
    if ! tar -xzf "$selected_file" -C "$temp_dir" >> "$LOG_FILE" 2>&1; then
        red "❌ 解压备份文件失败！文件可能已损坏。"
        log "解压备份文件失败。"
        start_services
        rm -rf "$temp_dir"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    # 【核心逻辑】恢复数据库
    log "正在恢复数据库 '$DB_NAME'..."
    if mysql -u"$DB_USER" -p"$DB_PASS" -e "DROP DATABASE IF EXISTS $DB_NAME; SOURCE ${temp_dir}/cacti_database.sql;" >> "$LOG_FILE" 2>&1; then
        log "数据库恢复成功。"
        
        log "正在恢复 RRD 数据文件..."
        rsync -a --delete "${temp_dir}/rra/" "/var/lib/cacti/rra/" >> "$LOG_FILE" 2>&1
        
        log "正在恢复 Cacti 程序文件..."
        rsync -a --delete "${temp_dir}/cacti_web/" "/usr/share/cacti/" >> "$LOG_FILE" 2>&1

        log "正在恢复 Cacti 配置文件..."
        [ -f "${temp_dir}/configs/db.php" ] && cp "${temp_dir}/configs/db.php" "/etc/cacti/"
        [ -f "${temp_dir}/configs/spine.conf" ] && cp "${temp_dir}/configs/spine.conf" "/etc/"

        log "正在修复文件权限..."
        chown -R apache:apache /var/lib/cacti/rra
        chown -R apache:apache /usr/share/cacti
        chown -R apache:apache /etc/cacti

        green "🎉 Cacti 精准恢复成功！"
        log "Cacti 精准恢复成功。"
    else
        red "❌ 数据库恢复失败！请检查日志或脚本配置区的数据库凭据。"
        log "数据库恢复失败。"
    fi
    rm -rf "$temp_dir"
    
    start_services
    
    echo ""
    yellow "=================================================="
    yellow "  恢复完成！请在浏览器中访问 Cacti 确认恢复结果。"
    yellow "=================================================="
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}


# --- 功能4: Cacti 精准卸载 (安全版) ---
uninstall_cacti() {
    clear
    red "=================================================="
    echo "           !!! DANGER: Cacti 精准卸载 !!!"
    red "=================================================="
    red "此操作将彻底删除 Cacti 及其 LAMP 运行环境！"
    red "包括：数据库、RRD文件、程序文件、PHP、Apache、MariaDB 及其配置。"
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

    log "===== 开始执行卸载前的最后一次备份 ====="
    if check_dependencies; then
        local timestamp=$(date "+%Y%m%d_%H%M%S")
        local backup_filename="cacti_uninstall_backup_${timestamp}.tar.gz"
        local full_backup_path="${BACKUP_DIR}/${backup_filename}"
        local temp_dir=$(mktemp -d)
        
        if mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "${temp_dir}/cacti_database.sql" 2>> "$LOG_FILE"; then
            rsync -a --delete "/var/lib/cacti/rra/" "${temp_dir}/rra/" >> "$LOG_FILE" 2>&1
            rsync -a --delete "/usr/share/cacti/" "${temp_dir}/cacti_web/" >> "$LOG_FILE" 2>&1
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
    red "您确定要永久删除 Cacti 及其 LAMP 环境吗？此操作不可逆转！"
    read -p "请输入 'UNINSTALL' 以确认卸载: " final_confirm
    if [ "$final_confirm" != "UNINSTALL" ]; then
        log "用户未能正确确认，卸载操作已中止。"
        echo "卸载已中止。"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    log "===== 开始执行 Cacti 精准卸载 ====="
    
    # 【安全修复】不再操作 crond 服务
    log "正在停止并禁用核心服务 (httpd, mariadb)..."
    systemctl stop httpd mariadb >/dev/null 2>&1
    systemctl disable httpd mariadb >/dev/null 2>&1
    log "核心服务已停止并禁用。"

    log "正在卸载 Cacti 及其 LAMP 环境软件包..."
    dnf remove -y cacti cacti-spine httpd mariadb-server php php-common php-cli php-mysqlnd php-gd php-ldap php-odbc php-pdo php-pecl-zip php-snmp php-xml php-mbstring net-snmp net-snmp-utils rrdtool epel-release remi-release >/dev/null 2>&1
    log "主要软件包卸载完成。"

    log "正在自动清理不再需要的依赖包..."
    dnf autoremove -y >/dev/null 2>&1
    log "依赖包清理完成。"

    log "正在清理 Cacti 和 LAMP 环境的残留文件和目录..."
    rm -rf /var/lib/cacti
    rm -rf /usr/share/cacti
    rm -rf /etc/cacti
    rm -rf /etc/spine.conf
    rm -rf /etc/httpd/conf.d/cacti.conf
    rm -rf /etc/cron.d/cacti # 只删除 Cacti 的定时任务
    rm -rf /var/log/cacti
    rm -rf /var/lib/mysql
    rm -rf /etc/my.cnf
    rm -rf /etc/my.cnf.d
    rm -rf /etc/php.ini
    rm -rf /etc/php.d
    log "残留文件清理完成。"

    green "🎉 Cacti 精准卸载完成！"
    log "Cacti 精准卸载完成。"
    
    echo ""
    yellow "⚠️  重要提示：SELinux 状态需要重启服务器才能从 'disabled' 恢复到 'enforcing'。"
    yellow "   您可以使用 'getenforce' 命令检查当前状态，使用 'reboot' 命令重启。"
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# --- 功能5: 自动安装快捷方式 ---
install_alias() {
    local script_dest="/usr/local/sbin/cacti-manager.sh"
    local alias_dest="/usr/local/bin/cacti"

    if [ -L "$alias_dest" ] && [ -f "$script_dest" ]; then
        log_quiet "快捷方式 'cacti' 已存在，跳过安装。"
        return 0
    fi

    blue "=== 正在为脚本创建系统快捷方式... ==="
    
    local current_script_path=$(realpath "$0")
    
    if ! cp "$current_script_path" "$script_dest"; then
        red "❌ 复制脚本到 $script_dest 失败！"
        return 1
    fi
    
    chmod 700 "$script_dest"
    
    if ! ln -s "$script_dest" "$alias_dest"; then
        red "❌ 创建软链接 $alias_dest 失败！"
        return 1
    fi
    
    green "✅ 快捷方式安装成功！"
    green "   现在您可以在任何目录下直接输入 'cacti' 来运行此管理脚本。"
    log "快捷方式 'cacti' 已成功安装。"
}

# --- 功能6: 静默更新 (无缝重启最终版) ---
self_update() {
    clear
    cyan "=================================================="
    echo "              脚本静默更新"
    cyan "=================================================="
    
    # 使用 BASH_SOURCE[0] 来获取当前脚本的真实路径，这比写死路径更可靠
    local script_path="${BASH_SOURCE[0]}"
    # 快捷方式的路径，用于最后执行
    local alias_path="/usr/local/bin/cacti"

    log "===== 开始执行脚本静默更新 ====="
    echo "正在从 $SCRIPT_URL 下载最新版本..."

    local temp_file
    temp_file=$(mktemp)

    if ! curl -sSL "$SCRIPT_URL" -o "$temp_file"; then
        red "❌ 下载脚本失败！请检查网络连接或 URL。"
        log "脚本更新失败：下载失败。"
        rm -f "$temp_file"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    if ! head -n 1 "$temp_file" | grep -q "^#!/bin/bash"; then
        red "❌ 错误：下载的文件不是一个有效的 Bash 脚本。"
        log "脚本更新失败：文件无效或已损坏。"
        rm -f "$temp_file"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    log "下载成功，正在用新版本直接替换当前脚本..."
    if ! mv "$temp_file" "$script_path"; then
        red "❌ 替换脚本文件失败！请检查文件系统权限。"
        log "脚本更新失败：替换文件 '$script_path' 失败。"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    chmod 700 "$script_path"
    log "新脚本权限已设置为 700。"

    green "🎉 脚本已成功更新！"
    log "脚本已成功更新到最新版本。"
    
    echo ""
    bold "=================================================="
    bold "  正在无缝重启最新版本的脚本..."
    bold "=================================================="
    echo ""
    
    # --- 核心改动：使用 exec 命令进行无缝重启 ---
    # 1. exec 会用后面的命令替换掉当前的 Shell 进程。
    # 2. 我们执行快捷方式 'cacti'，它会调用刚刚被更新的脚本。
    # 3. 因为是替换进程，所以用户看起来就像是脚本刷新了一下，直接进入了新版本的菜单。
    exec "$alias_path"
}

# --- 主菜单 ---
main_menu() {
    clear
    blue "=================================================="
    green "           Cacti 一站式管理工具箱 v${SCRIPT_VERSION}"
    blue "=================================================="
    echo " (1) 安装 Cacti"
    echo " (2) 备份 Cacti "
    echo " (3) 恢复 Cacti "
    echo " (4) 卸载 Cacti "
    echo " (5) 更新脚本 "  
    echo " (6) 退出"      
    blue "=================================================="
    read -p "请输入您的选择 [1-6]: " choice

    case $choice in
        1) install_cacti ;;
        2) perform_backup ;;
        3) perform_restore ;;
        4) uninstall_cacti ;;
        5) self_update ;;
        6)
            log "用户选择退出脚本。"
            green "感谢使用，再见！"
            exit 0
            ;;
        *)
            red "无效的选项，请输入 1-6 之间的数字。"
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

mkdir -p "$BACKUP_DIR"

install_alias

main_menu
