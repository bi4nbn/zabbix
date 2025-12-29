#!/bin/bash
##############################################################################
# Cacti 一站式管理脚本 (安装/备份/恢复/终极卸载)
# 功能:
#   1. 【集成安装】通过官方脚本一键安装 Cacti。
#   2. 【全量备份】自动检测依赖，备份数据库、RRD文件、程序和配置。
#   3. 【安全恢复】恢复前停止服务，恢复后重启，确保数据一致性。
#   4. 【终极卸载】智能识别并清理安装脚本带来的所有包、配置、服务和数据目录。
#   5. 【持久化菜单】操作完成后返回主菜单，方便连续管理。
#   6. 【详细日志】所有操作记录在 /backup/cacti/cacti_backup_restore.log。
#   7. 【简洁输出】屏幕只显示关键信息，过程细节记录在日志中。
#   8. 【自动快捷方式】首次运行后，自动创建 'cacti' 命令，方便后续调用。
#   9. 【自我更新】新增菜单选项，可一键更新脚本至最新版本。
#
# ⚠️  安全警告:
#   - 脚本包含数据库密码明文，且执行 root 权限操作。
#   - 请严格限制此脚本的访问权限。
#   - 建议权限: chmod 700 cacti_manager.sh
##############################################################################

# ======================== 【配置区】 ========================
DB_NAME="cacti"
DB_USER="cactiuser"
DB_PASS="cactiuser"
DB_SERVICE="mariadb"
BACKUP_DIR="/backup/cacti"
LOG_FILE="${BACKUP_DIR}/cacti_backup_restore.log"
SCRIPT_URL="https://raw.githubusercontent.com/bi4nbn/zabbix/refs/heads/main/cacti/cacti.sh"
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

# --- 功能2: 备份 Cacti ---
perform_backup() {
    clear
    blue "=================================================="
    echo "              Cacti 全量备份"
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

    log "===== 开始执行全量备份 ====="
    local timestamp=$(date "+%Y%m%d_%H%M%S")
    local backup_filename="cacti_full_backup_${timestamp}.tar.gz"
    local full_backup_path="${BACKUP_DIR}/${backup_filename}"
    local temp_dir=$(mktemp -d)

    log "正在备份数据库 '$DB_NAME'..."
    if ! mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "${temp_dir}/database.sql" 2>> "$LOG_FILE"; then
        red "❌ 数据库备份失败！请检查数据库凭据和服务状态。"
        rm -rf "$temp_dir"
        log "备份失败，已清理临时文件。"
    else
        log "正在备份 RRD 数据文件..."
        rsync -a --delete "/var/lib/cacti/rra/" "${temp_dir}/rra/" >> "$LOG_FILE" 2>&1
        
        log "正在备份 Cacti Web 目录..."
        rsync -a --delete "/usr/share/cacti/" "${temp_dir}/web/" >> "$LOG_FILE" 2>&1
        
        log "正在备份相关配置文件..."
        mkdir -p "${temp_dir}/configs"
        cp -r /etc/httpd/conf.d "${temp_dir}/configs/" 2>> "$LOG_FILE"
        cp /etc/php.ini "${temp_dir}/configs/" 2>> "$LOG_FILE"
        cp /etc/my.cnf "${temp_dir}/configs/" 2>> "$LOG_FILE"

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

# --- 功能3: 恢复 Cacti ---
perform_restore() {
    clear
    blue "=================================================="
    echo "              Cacti 全量恢复"
    blue "=================================================="

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

    log "===== 开始执行全量恢复 ====="
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
        log "正在恢复数据库..."
        systemctl start $DB_SERVICE >/dev/null 2>&1
        mysql -u"$DB_USER" -p"$DB_PASS" -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >> "$LOG_FILE" 2>&1
        if mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "${temp_dir}/database.sql" >> "$LOG_FILE" 2>&1; then
            log "正在恢复 RRD 数据文件..."
            rsync -a --delete "${temp_dir}/rra/" "/var/lib/cacti/rra/" >> "$LOG_FILE" 2>&1
            
            log "正在恢复 Cacti Web 目录..."
            rsync -a --delete "${temp_dir}/web/" "/usr/share/cacti/" >> "$LOG_FILE" 2>&1

            log "正在恢复相关配置文件..."
            cp -r "${temp_dir}/configs/httpd/conf.d/"* "/etc/httpd/conf.d/" 2>> "$LOG_FILE"
            cp "${temp_dir}/configs/php.ini" "/etc/" 2>> "$LOG_FILE"
            cp "${temp_dir}/configs/my.cnf" "/etc/" 2>> "$LOG_FILE"
            
            green "🎉 全量恢复成功！"
            log "全量恢复成功。"
        else
            red "❌ 数据库恢复失败！"
            log "数据库恢复失败。"
        fi
        rm -rf "$temp_dir"
    fi
    
    start_services
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# --- 功能4: 终极卸载 Cacti ---
uninstall_cacti() {
    clear
    red "=================================================="
    echo "           !!! DANGER: Cacti 终极卸载 !!!"
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
    systemctl stop httpd mariadb snmpd chronyd crond >/dev/null 2>&1
    systemctl disable httpd mariadb snmpd chronyd crond >/dev/null 2>&1

    # 卸载所有相关的包
    log "正在卸载所有相关软件包..."
    dnf remove -y cacti cacti-spine httpd mariadb-server php\* net-snmp\* rrdtool\* epel-release remi-release\* chrony >/dev/null 2>&1
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

    # 恢复防火墙
    log "正在恢复防火墙设置..."
    systemctl enable --now firewalld >/dev/null 2>&1
    firewall-cmd --permanent --add-service=http >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1

    green "🎉 Cacti 终极卸载完成！"
    log "Cacti 终极卸载完成。"
    
    echo ""
    yellow "⚠️  重要提示：SELinux 状态需要重启服务器才能从 'disabled' 恢复到 'enforcing'。"
    yellow "   您可以使用 'getenforce' 命令检查当前状态，使用 'reboot' 命令重启。"
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# --- 功能5: 自动安装快捷方式 ---
install_alias() {
    # 定义目标路径
    local script_dest="/usr/local/sbin/cacti-manager.sh"
    local alias_dest="/usr/local/bin/cacti"

    # 检查是否已经安装
    if [ -L "$alias_dest" ] && [ -f "$script_dest" ]; then
        log_quiet "快捷方式 'cacti' 已存在，跳过安装。"
        return 0
    fi

    blue "=== 正在为脚本创建系统快捷方式... ==="
    
    # 获取当前脚本的绝对路径
    local current_script_path=$(realpath "$0")
    
    # 复制脚本到标准位置
    if ! cp "$current_script_path" "$script_dest"; then
        red "❌ 复制脚本到 $script_dest 失败！"
        return 1
    fi
    
    # 确保脚本有执行权限
    chmod 700 "$script_dest"
    
    # 创建软链接作为快捷方式
    if ! ln -s "$script_dest" "$alias_dest"; then
        red "❌ 创建软链接 $alias_dest 失败！"
        return 1
    fi
    
    green "✅ 快捷方式安装成功！"
    green "   现在您可以在任何目录下直接输入 'cacti' 来运行此管理脚本。"
    log "快捷方式 'cacti' 已成功安装。"
}

# --- 功能6: 自我更新 ---
self_update() {
    clear
    cyan "=================================================="
    echo "              脚本自我更新"
    cyan "=================================================="
    
    # 定义脚本的安装路径
    local script_path="/usr/local/sbin/cacti-manager.sh"

    # 检查脚本是否已安装到标准位置
    if [ ! -f "$script_path" ]; then
        red "❌ 错误：未在 $script_path 找到已安装的脚本。"
        yellow "请先通过快捷方式安装脚本，或使用以下命令安装后再尝试更新："
        echo "  curl -sSL -o cacti.sh $SCRIPT_URL && chmod +x cacti.sh && ./cacti.sh"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    read -p "是否确认从 $SCRIPT_URL 更新脚本? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "用户取消了脚本更新操作。"
        echo "更新已取消。"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    log "===== 开始执行脚本自我更新 ====="
    echo "正在从 $SCRIPT_URL 下载最新版本..."

    # 使用 curl 下载新版本并直接覆盖旧版本
    if ! curl -sSL "$SCRIPT_URL" -o "$script_path"; then
        red "❌ 下载脚本失败！请检查网络连接或 URL 是否正确。"
        log "脚本更新失败：下载失败。"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        main_menu
        return
    fi

    # 确保新脚本仍然有执行权限
    chmod 700 "$script_path"

    green "🎉 脚本更新成功！"
    log "脚本已成功更新到最新版本。"
    
    echo ""
    bold "=================================================="
    bold "  请在终端中重新输入 'cacti' 命令以运行新版本。"
    bold "=================================================="
    echo ""
    
    # 退出当前脚本，让用户手动重启
    exit 0
}


# --- 主菜单 ---
main_menu() {
    clear
    blue "=================================================="
    green "           Cacti 一站式管理工具箱"
    blue "=================================================="
    echo " (1) 安装 Cacti"
    echo " (2) 备份 Cacti"
    echo " (3) 恢复 Cacti"
    echo " (4) 卸载 Cacti"
    echo " (5) 更新脚本"  
    echo " (6) 退出"      
    blue "=================================================="
    read -p "请输入您的选择 [1-6]: " choice # <-- 选项范围更新

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
            red "无效的选项，请输入 1-6 之间的数字。" # <-- 提示信息更新
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

# 自动安装快捷方式
install_alias

# 启动主菜单
main_menu
