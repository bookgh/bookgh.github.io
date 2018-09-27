#!/bin/bash

# 创建 cinder 数据库,用户,授权
source ~/PASS               # 读取数据库密码
mysql -u root -p$DBPass -e "
create database cinder;
grant all privileges on cinder.* to 'cinder'@'localhost' identified by 'cinder';
grant all privileges on cinder.* to 'cinder'@'%' identified by 'cinder';
flush privileges;
select user,host from mysql.user;
show databases;"

# 创建角色,授权
source ~/admin-openstack.sh              # 加载凭证
openstack user create --domain default --password=cinder cinder
openstack role add --project service --user cinder admin

# 创建服务
openstack service create --name cinderv2   --description "OpenStack Block Storage" volumev2
openstack service create --name cinderv3   --description "OpenStack Block Storage" volumev3
openstack service list        # 查看服务

# 注册 API
openstack endpoint create --region RegionOne volumev2 public http://controller:8776/v2/%\(project_id\)s
openstack endpoint create --region RegionOne volumev2 internal http://controller:8776/v2/%\(project_id\)s
openstack endpoint create --region RegionOne volumev2 admin http://controller:8776/v2/%\(project_id\)s
openstack endpoint create --region RegionOne volumev3 public http://controller:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne volumev3 internal http://controller:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne volumev3 admin http://controller:8776/v3/%\(project_id\)s
openstack endpoint list        # 查看注册的 API

# 安装 Cinder
for HOST in controller{1..3}; do
    echo "------------ $HOST ------------"
    ssh -T $HOST <<'EOF'
    # 安装 Cinder NFS
    yum install -y openstack-cinder nfs-utils

    # 备份默认配置文件
    [ -f /etc/cinder/cinder.conf.bak ] || cp /etc/cinder/cinder.conf{,.bak}

    # Nova 添加 cinder 配置
    if [ -z "$(grep 'Cinder' /etc/nova/nova.conf)" ];then
        echo -e '\n# Cinder' >>/etc/nova/nova.conf
        echo '[cinder]' >>/etc/nova/nova.conf
        echo 'os_region_name = RegionOne' >>/etc/nova/nova.conf
    fi
EOF
done

# 创建 Cinder 配置文件
cat <<'EOF' >/etc/cinder/cinder.conf
[DEFAULT]
osapi_volume_listen = controller1
osapi_volume_listen_port = 8776
auth_strategy = keystone
log_dir = /var/log/cinder
state_path = /var/lib/cinder
glance_api_servers = http://controller:9292
transport_url = rabbit://openstack:openstack@controller

[database]
connection = mysql+pymysql://cinder:cinder@controller/cinder

[keystone_authtoken]
auth_uri = http://controller:5000
auth_url = http://controller:35357
memcached_servers = controller1:11211,controller2:11211,controller3:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = cinder
password = cinder

[oslo_concurrency]
lock_path = /var/lib/cinder/tmp
EOF

# 同步 cinder 配置文件, 修改其他节点监听主机
rsync -avzP -e 'ssh -p 22' /etc/cinder/cinder.conf controller2:/etc/cinder/
rsync -avzP -e 'ssh -p 22' /etc/cinder/cinder.conf controller3:/etc/cinder/
ssh controller2 "sed -i '1,8s/controller1/controller2/' /etc/cinder/cinder.conf"
ssh controller3 "sed -i '1,8s/controller1/controller3/' /etc/cinder/cinder.conf"

# 初始化数据
su -s /bin/sh -c "cinder-manage db sync" cinder

# 检验 cinder 数据库
mysql -h controller -u cinder -pcinder -e "use cinder;show tables;"

# Haproxy 代理 Cinder 配置
if [ -z "$(grep 'Cinder' /etc/haproxy/haproxy.cfg)" ];then
cat <<'EOF' >>/etc/haproxy/haproxy.cfg

##########Cinder_API_cluster##########
listen Cinder_API_cluster
  bind controller:8776
  #balance source
  option tcpka
  option httpchk
  option tcplog
  server controller1 controller1:8776 check inter 2000 rise 2 fall 5
  server controller2 controller2:8776 check inter 2000 rise 2 fall 5
  server controller3 controller3:8776 check inter 2000 rise 2 fall 5
EOF
fi

# 同步配置到其他节点
rsync -avzP -e 'ssh -p 22' /etc/haproxy/haproxy.cfg controller2:/etc/haproxy/
rsync -avzP -e 'ssh -p 22' /etc/haproxy/haproxy.cfg controller3:/etc/haproxy/

# 服务管理
for HOST in controller{1..3}; do
    echo "------------ $HOST ------------"
    ssh -T $HOST <<'EOF'
    # 重启 nova-api, haproxy
    systemctl restart openstack-nova-api haproxy

    # cinder服务跟随系统启动
    systemctl enable openstack-cinder-api openstack-cinder-scheduler

    # 启动 cinder 服务
    systemctl start openstack-cinder-api openstack-cinder-scheduler
EOF
done

# 添加 cinder1 主机免密码登录

source ~/SSH_KEY
SSH_KEY cinder1                        # controller1 免密码登录 cinder1
scp /etc/hosts cinder1:/etc/           # 同步hosts
scp ~/admin-openstack.sh cinder1:~/    # 同步 opentstack 管理员凭证
