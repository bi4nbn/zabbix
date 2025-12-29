# AlmaLinux 9.7-Cacti一键安装脚本


```
curl -sL https://raw.githubusercontent.com/bi4nbn/zabbix/refs/heads/main/cacti/install.sh | bash
```



### 支持操作系统
1. **zabbix6.sh** 已支持 **centos 7(编译安装) / centos 8 / centos 9 / rocky linux 8 / rocky linux 9 / ubuntu 20.04 / ubuntu 22.04 / ubuntu 24.04 / debian 11 / debian 12**
2. **zabbix7.sh** 已支持 **centos 8(强烈不推荐) / centos 9 / centos 10 / rocky linux 8 / rocky linux 9 / rocky linux 10 / ubuntu 22.04 / ubuntu 24.04 / debian 12 / almaLinux 8 / almaLinux 9 / almaLinux 10**
3. **zabbix7.4.sh** 已支持 **centos 8(强烈不推荐) / centos 9 / centos 10 / rocky linux 8 / rocky linux 9 / rocky linux 10 / ubuntu 22.04 / ubuntu 24.04 / debian 12 / almaLinux 8 / almaLinux 9 / almaLinux 10**
4. docker 部署已完成测试系统 **rocky linux 9 / ubuntu 24.04**
5. **openeuler.sh** 已支持 **openeuler 22.03 / openeuler 24.03**


### zabbix 7.4 食用方法
1. centos 8（强烈不推荐） / centos 9 / centos 10 / rocky linux 8 / rocky linux 9 / rocky linux 10 / ubuntu 22.04 / ubuntu 24.04 / debian 12 / almaLinux 8 / almaLinux 9 / almaLinux 10
```shell
git clone https://github.com/X-Mars/Quick-Installation-ZABBIX.git
cd Quick-Installation-ZABBIX
bash zabbix7.4.sh
```

### zabbix 7.0 食用方法
1. centos 8（强烈不推荐） / centos 9 / centos 10 / rocky linux 8 / rocky linux 9 / rocky linux 10 / ubuntu 22.04 / ubuntu 24.04 / debian 12 / almaLinux 8 / almaLinux 9 / almaLinux 10
```shell
git clone https://github.com/X-Mars/Quick-Installation-ZABBIX.git
cd Quick-Installation-ZABBIX
bash zabbix7.sh
```

### openeuler 22 / 24 安装zabbix 7.0 食用方法
```shell
git clone https://github.com/X-Mars/Quick-Installation-ZABBIX.git
cd Quick-Installation-ZABBIX
bash openeuler.sh
```

### zabbix 7.0 docker 部署 食用方法
1. rocky linux 9 / ubuntu 24.04
```shell
git clone https://github.com/X-Mars/Quick-Installation-ZABBIX.git
cd Quick-Installation-ZABBIX/docker
bash zabbix7_docker.sh
```

### zabbix 6.0 食用方法
1. centos 8 / centos 9 / rocky linux 8 / rocky linux 9 / ubuntu 20.04 / ubuntu 22.04 / ubuntu 24.04 / debian 11 / debian 12
```shell
git clone https://github.com/X-Mars/Quick-Installation-ZABBIX.git
cd Quick-Installation-ZABBIX
bash zabbix6.sh
```
2. centos 7(编译安装，**极其非常不推荐！！！**)
```shell
git clone https://github.com/X-Mars/Quick-Installation-ZABBIX.git
cd Quick-Installation-ZABBIX/zabbix6
bash centos-7.sh
```

