# Zabbix Docker Compose 完整配置
ai生成的文档 懒得编辑 看懂的拿走
## docker-compose.yml
```yaml
version: '3.8'

services:
  zabbix-mysql:
    image: mariadb:10.5
    container_name: zabbix-mysql
    restart: always
    environment:
      MARIADB_ROOT_PASSWORD: root
      MYSQL_DATABASE: zabbix
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix
      TZ: Asia/Shanghai
    volumes:
      - ./mariadb_data:/var/lib/mysql
      - ./mariadb_conf.d:/etc/mysql/mariadb.conf.d
    command: >
      --character-set-server=utf8mb4 --collation-server=utf8mb4_bin --explicit_defaults_for_timestamp=1

  zabbix-server:
    image: zabbix/zabbix-server-mysql:latest
    container_name: zabbix-server
    restart: always
    depends_on:
      - zabbix-mysql
    environment:
      DB_SERVER_HOST: zabbix-mysql
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix
      MYSQL_DATABASE: zabbix
      TZ: Asia/Shanghai
      ZBX_DB_SSLMODE: "disable"
    ports:
      - "10051:10051"

  zabbix-web:
    image: zabbix/zabbix-web-nginx-mysql:latest
    container_name: zabbix-web
    restart: always
    depends_on:
      - zabbix-server
      - zabbix-mysql
    environment:
      ZBX_SERVER_HOST: zabbix-server
      DB_SERVER_HOST: zabbix-mysql
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix
      MYSQL_DATABASE: zabbix
      PHP_TZ: Asia/Shanghai
      ZBX_ENABLE_SSL: "false"
    ports:
      - "80:8080"
      - "443:8443"
```

## 快速部署脚本

### deploy.sh
```bash
#!/bin/bash

echo "创建部署目录..."
mkdir -p zabbix-docker/{mariadb_data,mariadb_conf.d}
cd zabbix-docker

echo "创建 docker-compose.yml..."
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  zabbix-mysql:
    image: mariadb:10.5
    container_name: zabbix-mysql
    restart: always
    environment:
      MARIADB_ROOT_PASSWORD: root
      MYSQL_DATABASE: zabbix
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix
      TZ: Asia/Shanghai
    volumes:
      - ./mariadb_data:/var/lib/mysql
      - ./mariadb_conf.d:/etc/mysql/mariadb.conf.d
    command: >
      --character-set-server=utf8mb4 --collation-server=utf8mb4_bin --explicit_defaults_for_timestamp=1

  zabbix-server:
    image: zabbix/zabbix-server-mysql:latest
    container_name: zabbix-server
    restart: always
    depends_on:
      - zabbix-mysql
    environment:
      DB_SERVER_HOST: zabbix-mysql
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix
      MYSQL_DATABASE: zabbix
      TZ: Asia/Shanghai
      ZBX_DB_SSLMODE: "disable"
    ports:
      - "10051:10051"

  zabbix-web:
    image: zabbix/zabbix-web-nginx-mysql:latest
    container_name: zabbix-web
    restart: always
    depends_on:
      - zabbix-server
      - zabbix-mysql
    environment:
      ZBX_SERVER_HOST: zabbix-server
      DB_SERVER_HOST: zabbix-mysql
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix
      MYSQL_DATABASE: zabbix
      PHP_TZ: Asia/Shanghai
      ZBX_ENABLE_SSL: "false"
    ports:
      - "80:8080"
      - "443:8443"
EOF

echo "启动 Zabbix 服务..."
docker-compose up -d

echo "等待服务启动..."
sleep 30

echo "检查服务状态..."
docker-compose ps

echo "部署完成!"
echo "访问地址: http://your-server-ip"
echo "用户名: Admin"
echo "密码: zabbix"
```

### manage.sh
```bash
#!/bin/bash

case "$1" in
    start)
        echo "启动 Zabbix 服务..."
        docker-compose up -d
        ;;
    stop)
        echo "停止 Zabbix 服务..."
        docker-compose down
        ;;
    restart)
        echo "重启 Zabbix 服务..."
        docker-compose restart
        ;;
    status)
        echo "服务状态:"
        docker-compose ps
        ;;
    logs)
        echo "查看日志:"
        docker-compose logs -f
        ;;
    backup)
        echo "备份数据库..."
        docker-compose exec zabbix-mysql mysqldump -u zabbix -pzabbix zabbix > zabbix_backup_$(date +%Y%m%d_%H%M%S).sql
        echo "备份完成!"
        ;;
    *)
        echo "使用方法: $0 {start|stop|restart|status|logs|backup}"
        exit 1
        ;;
esac
```

## README.md
```markdown
# Zabbix Docker 部署

## 快速开始

1. 下载文件:
```bash
wget https://raw.githubusercontent.com/your-repo/zabbix-docker/main/deploy.sh
chmod +x deploy.sh
./deploy.sh
```

2. 或者手动部署:
```bash
mkdir zabbix-docker && cd zabbix-docker
# 复制 docker-compose.yml 内容
docker-compose up -d
```

## 访问信息
- URL: http://your-server-ip
- 用户: Admin
- 密码: zabbix

## 管理命令
```bash
./manage.sh start      # 启动
./manage.sh stop       # 停止  
./manage.sh restart    # 重启
./manage.sh status     # 状态
./manage.sh logs       # 日志
./manage.sh backup     # 备份
```

## 端口说明
- 80: Zabbix Web 界面
- 10051: Zabbix Server 端口
```

## 使用说明

1. **一键部署**:
   ```bash
   chmod +x deploy.sh && ./deploy.sh
   ```

2. **管理服务**:
   ```bash
   chmod +x manage.sh
   ./manage.sh start    # 启动
   ./manage.sh status   # 查看状态
   ./manage.sh logs     # 查看日志
   ```

3. **访问系统**:
   - 打开浏览器访问 `http://your-server-ip`
   - 使用默认凭证登录: `Admin` / `zabbix`

所有代码都可以直接复制使用！
