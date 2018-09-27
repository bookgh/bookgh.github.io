#!/bin/bash

# 指定MariaDB 数据库密码
echo "DBPass='redhat'" >>~/PASS
source ~/PASS

# controller1, controller2, controller3 控制节点安装
for HOST in  controller{1..3}; do
    echo "--------------- $HOST ---------------"
    ssh -T $HOST <<EOF

    # 安装 OpenStack 客户端, 工具
    yum -y install python-openstackclient openstack-selinux openstack-utils

    # 安装 MariaDB Galera 集群
    yum -y install mariadb mariadb-server mariadb-galera-server

    # 安装自动交互工具(MariaDB 数据库初始化时用)
    yum -y install expect

    # 启动 MariaDB服务, 禁止跟随系统启动(服务交由Galera管理)
    systemctl start mariadb
    systemctl disable mariadb
    
    echo -e '\n\n'

    # Galera MariaDB 数据库配置文件
    echo "[mysqld]" >/etc/my.cnf.d/openstack.cnf
    echo "bind-address = $HOST" >>/etc/my.cnf.d/openstack.cnf
    echo "default-storage-engine = innodb" >>/etc/my.cnf.d/openstack.cnf
    echo "innodb_file_per_table" >>/etc/my.cnf.d/openstack.cnf
    echo "max_connections = 4096" >>/etc/my.cnf.d/openstack.cnf
    echo "collation-server = utf8_general_ci" >>/etc/my.cnf.d/openstack.cnf
    echo "character-set-server = utf8" >>/etc/my.cnf.d/openstack.cnf

    # 初始化 Mariadb 数据库
    /usr/bin/expect <<EEOOFF
    set timeout 30
    spawn mysql_secure_installation
    expect {
        "enter for none" { send "\r"; exp_continue}
        "Y/n" { send "Y\r" ; exp_continue}
        "password:" { send "$DBPass\r"; exp_continue}
        "new password:" { send "$DBPass\r"; exp_continue}
        "Y/n" { send "Y\r" ; exp_continue}
        eof { exit }
    }
EEOOFF

    # 测试
    echo -e "\033[32m HOST: $HOST show databases \n \033[0m"
    mysql -u root -p$DBPass -te "show databases;"
    if [ $? = 0 ]; then
        echo -e "\033[32m \n HOST: $HOST  MariaDB  初始化成功 \033[0m"
    else
        echo -e "\033[31m \n HOST: $HOST  MariaDB  初始化失败 \033[0m"
        exit
    fi

    # 配置数据库root 远程访问授权(Galera 集群管理用)
    echo -e "\033[32m HOST: $HOST   MariaDB User List \n \033[0m"
    mysql -u root -p$DBPass -te "
    grant all privileges on *.* to 'root'@'%' identified by '$DBPass' with grant option; 
    flush privileges;
    select user,host,password from mysql.user;" 
    echo -e '\n\n'

    # 备份galera 默认配置文件
    [ -f /etc/my.cnf.d/galera.cnf.bak ] || cp /etc/my.cnf.d/galera.cnf{,.bak}

    # 过滤 galera 配置文件中的无效行(注释行,空行)
    egrep -v "#|^$" /etc/my.cnf.d/galera.cnf.bak >/etc/my.cnf.d/galera.cnf

    # 配置 Galera 认证权限, 工作模式
    sed -i 's/wsrep_sst_auth=.*/wsrep_sst_auth=root:'$DBPass'/' /etc/my.cnf.d/galera.cnf
    echo 'wsrep_cluster_address="gcomm://controller1,controller2,controller3"' >>/etc/my.cnf.d/galera.cnf
    echo "wsrep_node_name= $HOST" >>/etc/my.cnf.d/galera.cnf
    echo "wsrep_node_address= $HOST" >>/etc/my.cnf.d/galera.cnf
    sed -i 's/wsrep_on=.*/wsrep_on=ON/' /etc/my.cnf.d/galera.cnf
EOF
done


# 初始化集群

# 关闭 controller1 MariaDB 服务
systemctl stop mariadb

# 在 controller1 初始化集群
galera_new_cluster
sleep 3
echo -e '\n\n'

# 重启 controller2 controller3 MariaDB 服务
for HOST in controller2 controller3; do
    ssh -T root@$HOST <<'EOF' 
    systemctl daemon-reload
    systemctl restart mariadb
EOF
done
sleep 3
# 启动 controller1 mariadb
systemctl daemon-reload
systemctl start mariadb

# 检测部署结果
netstat -antp | grep mysqld; sleep 3; echo -e '\n'
mysql -u root -p$DBPass -te "show status like 'wsrep_cluster_size';"; echo -e '\n'
mysql -u root -p$DBPass -te "show status like 'wsrep_incoming_addresses';"; echo -e '\n'

# 创建用于监控的mariadb 用户haproxy (haproxy代理，监控使用)
mysql -u root -p$DBPass -te "create user 'haproxy'@'%';flush privileges;";

# controller1 作为服务控制节点
if [ -z "$(grep 'Galera' /etc/rc.local)" ]; then
cat <<'EOF' >>/etc/rc.local

# Galera 启动集群
/usr/bin/galera_new_cluster
sleep 5
ssh controller2 "systemctl start mariadb"
ssh controller3 "systemctl start mariadb"
sleep 5
systemctl restart mariadb
EOF
fi
chmod +x /etc/rc.d/rc.local

# Haproxy 配置
if [ -z "$(grep 'MariaDB' /etc/haproxy/haproxy.cfg)" ];then
cat <<'EOF' >>/etc/haproxy/haproxy.cfg

########## MariaDB Cluster ##########
listen mariadb_cluster
  mode tcp
  option  tcplog
  bind controller:3306
  balance leastconn
  option mysql-check user haproxy
  server controller1 controller1:3306 weight 1 check inter 2000 rise 2 fall 5
  server controller2 controller2:3306 weight 1 check inter 2000 rise 2 fall 5
  server controller3 controller3:3306 weight 1 check inter 2000 rise 2 fall 5
EOF
fi

scp /etc/haproxy/haproxy.cfg controller2:/etc/haproxy/haproxy.cfg
scp /etc/haproxy/haproxy.cfg controller3:/etc/haproxy/haproxy.cfg

systemctl restart haproxy
ssh controller2 "systemctl restart haproxy"
ssh controller3 "systemctl restart haproxy"
echo -e '\n\n'


# 验证
mysql -h controller -u root -p$DBPass -e "show databases;"
mysql -h controller1 -u root -p$DBPass -e "show databases;"
mysql -h controller2 -u root -p$DBPass -e "show databases;"
mysql -h controller3 -u root -p$DBPass -e "show databases;"
echo -e '\n\n'

echo "
      浏览器打开 http://192.168.0.11:1080/admin 查看 mariadb_cluster 状态"
