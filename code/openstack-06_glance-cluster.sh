#!/bin/bash

# 镜像存储路径
ImgDir='/data/glance'

# 安装 Glance 镜像服务

# 创建 glance 数据库,授权
source ~/PASS      # 读取数据库密码
mysql -u root -p$DBPass -te "
create database glance;
grant all privileges on glance.* to 'glance'@'localhost' identified by 'glance';
grant all privileges on glance.* to 'glance'@'%' identified by 'glance';"

# 创建 glance 角色,授权
source ~/admin-openstack.sh      # 加载凭证
openstack user create --domain default --password=glance glance
openstack role add --project service --user glance admin

# 创建glance服务实体
openstack service create --name glance --description "OpenStack Image" image

# 创建服务 API
openstack endpoint create --region RegionOne image public http://controller:9292
openstack endpoint create --region RegionOne image internal http://controller:9292
openstack endpoint create --region RegionOne image admin http://controller:9292

# 安装 NFS 服务

# 配置免密码登录,初始化环境
source ~/SSH_KEY
SSH_KEY nfs
#ssh -T nfs "curl http://home.onlycloud.xin/code/openstack-01_init.sh | sh"
#scp /etc/hosts nfs:/etc/

# NFS 服务端 (centos7)
ssh -T nfs <<EOF
yum install nfs-utils rpcbind -y
mkdir -p $ImgDir
echo "$ImgDir 192.168.0.0/24(rw,no_root_squash,sync)">>/etc/exports
exportfs -r
systemctl enable rpcbind nfs-server
systemctl restart rpcbind nfs-server
showmount -e localhost
EOF

# 所有控制节点 作为 NFS 客户端(controller1节点执行)
for HOST in controller1 controller2 controller3; do
    echo "---------- $HOST ----------"
    ssh -T $HOST  <<EOF
    # 启用 rpcbind
    systemctl enable rpcbind
    systemctl start rpcbind

    # 创建挂载目录
    mkdir -p $ImgDir

    # 手动挂载
    mount -t nfs nfs:$ImgDir $ImgDir

    # 写入开机执行shell
    echo -e '\n# mount nfs glance' >>/etc/rc.local
    echo "/usr/bin/mount -t nfs nfs:$ImgDir $ImgDir">>/etc/rc.local
    chmod +x /etc/rc.d/rc.local

    # 验证挂载
    df -h
EOF
done

# 安装 Glance
yum install -y openstack-glance python-glance

# 备份默认配置
[ -f /etc/glance/glance-api.conf.bak ] || cp /etc/glance/glance-api.conf{,.bak}
[ -f /etc/glance/glance-registry.conf.bak ] || cp /etc/glance/glance-registry.conf{,.bak}

# Glance 配置

# 创建 glance-api 配置文件
cat <<EOF >/etc/glance/glance-api.conf
[DEFAULT]
debug = False
verbose = True
bind_host = controller1
bind_port = 9292
auth_region = RegionOne
registry_client_protocol = http

[database]
connection = mysql+pymysql://glance:glance@controller/glance

[keystone_authtoken]
auth_uri = http://controller:5000/v3
auth_url = http://controller:35357/v3
memcached_servers = controller1:11211,controller2:11211,controller3:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = glance

[paste_deploy]
flavor = keystone

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = $ImgDir

[oslo_messaging_rabbit]
rabbit_userid = openstack
rabbit_password = openstack
rabbit_durable_queues=true
rabbit_ha_queues = True
rabbit_max_retries= 0
rabbit_port = 5672  
rabbit_hosts = controller1:5672,controller2:5672,controller3:5672
EOF

# 创建 glance-registry 配置文件
cat <<EOF >/etc/glance/glance-registry.conf
[DEFAULT]
debug = False
verbose = True
bind_host = controller1
bind_port = 9191
workers = 2

[database]
connection = mysql+pymysql://glance:glance@controller/glance

[keystone_authtoken]
auth_uri = http://controller:5000/v3
auth_url = http://controller:35357/v3
memcached_servers = controller1:11211,controller2:11211,controller3:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = glance

[paste_deploy]
flavor = keystone

[oslo_messaging_rabbit]
rabbit_userid = openstack
rabbit_password = openstack
rabbit_durable_queues= true
rabbit_ha_queues = True
rabbit_max_retries= 0
rabbit_port = 5672  
rabbit_hosts = controller1:5672,controller2:5672,controller3:5672
EOF


# 设置镜像路径权限
chown glance:nobody $ImgDir
ssh controller2 "chown glance:nobody $ImgDir"
ssh controller3 "chown glance:nobody $ImgDir"

# 初始化

# 初始化 glance数据库,检查数据库
su -s /bin/sh -c "glance-manage db_sync" glance
mysql -h controller -u glance -pglance -te "use glance;show tables;"


# 配置 glance_api_cluster 代理
if [ -z "$(grep 'Glance' /etc/haproxy/haproxy.cfg)" ];then
cat <<EOF >>/etc/haproxy/haproxy.cfg

########## Glance_api_cluster ##########
listen glance_api_cluster
  bind controller:9292
  #balance source
  option tcpka
  option httpchk
  option tcplog
  server controller1 controller1:9292 check inter 2000 rise 2 fall 5
  server controller2 controller2:9292 check inter 2000 rise 2 fall 5
  server controller3 controller3:9292 check inter 2000 rise 2 fall 5
EOF
fi

# controller2,3 节点安装配置 Glance

# 安装Glance
ssh controller2 "yum install -y openstack-glance python-glance"
ssh controller3 "yum install -y openstack-glance python-glance"

# 同步 controller1 上的配置文件到 controller2,3 节点
rsync -avzP -e 'ssh -p 22' /etc/glance/* controller2:/etc/glance/
rsync -avzP -e 'ssh -p 22' /etc/glance/* controller3:/etc/glance/
rsync -avzP -e 'ssh -p 22' /etc/haproxy/haproxy.cfg controller2:/etc/haproxy/
rsync -avzP -e 'ssh -p 22' /etc/haproxy/haproxy.cfg controller3:/etc/haproxy/

# 更改controller2,3 监听主机 bind_host
ssh controller2 "sed -i 's/bind_host =.*/bind_host = controller2/' /etc/glance/glance-api.conf /etc/glance/glance-registry.conf"
ssh controller3 "sed -i 's/bind_host =.*/bind_host = controller3/' /etc/glance/glance-api.conf /etc/glance/glance-registry.conf"

# 启动服务,配置服务跟随系统启动
systemctl enable openstack-glance-api openstack-glance-registry
systemctl restart openstack-glance-api openstack-glance-registry haproxy
ssh controller2 "systemctl enable openstack-glance-api openstack-glance-registry"
ssh controller2 "systemctl restart openstack-glance-api openstack-glance-registry haproxy;"
ssh controller3 "systemctl enable openstack-glance-api openstack-glance-registry"
ssh controller3 "systemctl restart openstack-glance-api openstack-glance-registry haproxy;"

# 上传镜像测试
wget http://download.cirros-cloud.net/0.3.5/cirros-0.3.5-x86_64-disk.img
wget http://download.cirros-cloud.net/0.4.0/cirros-0.4.0-x86_64-disk.img

# 上传镜像,使用qcow2磁盘格式，bare容器格式,上传镜像到镜像服务并设置公共可见
source ~/admin-openstack.sh
openstack image create "cirros-0.3.5" --file cirros-0.3.5-x86_64-disk.img --disk-format qcow2 --container-format bare --public
openstack image create "cirros-0.4.0" --file cirros-0.4.0-x86_64-disk.img --disk-format qcow2 --container-format bare --public

# 检查是否上传成功

# 发送凭证到其他控制节点
scp ~/admin-openstack.sh controller2:~/admin-openstack.sh
scp ~/admin-openstack.sh controller3:~/admin-openstack.sh

# 查看镜像列表(三台节点相同)
openstack image list
ssh controller2 "source ~/admin-openstack.sh;openstack image list"
ssh controller3 "source ~/admin-openstack.sh;openstack image list"

ls /data/glance             # 查看本地镜像路径
ssh nfs "ls /data/glance"   # 查看 nfs 服务器镜像路径

