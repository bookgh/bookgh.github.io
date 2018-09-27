#!/bin/bash

# Nova-控制节点集群安装

# 创建 nova_api 和 nova 数据库, 授权
source ~/PASS      # 读取数据库密码
mysql -u root -p$DBPass -e "
create database nova;
grant all privileges on nova.* to 'nova'@'localhost' identified by 'nova';
grant all privileges on nova.* to 'nova'@'%' identified by 'nova';
create database nova_api;
grant all privileges on nova_api.* to 'nova'@'localhost' identified by 'nova';
grant all privileges on nova_api.* to 'nova'@'%' identified by 'nova';
create database nova_cell0;
grant all privileges on nova_cell0.* to 'nova'@'localhost' identified by 'nova';
grant all privileges on nova_cell0.* to 'nova'@'%' identified by 'nova';"

# 创建nova用户,添加 admin 角色
source ~/admin-openstack.sh
openstack user create --domain default --password=nova nova
openstack role add --project service --user nova admin

# 创建 compute 服务实体API 端点
openstack service create --name nova --description "OpenStack Compute" compute
openstack endpoint create --region RegionOne compute public http://controller:8774/v2.1
openstack endpoint create --region RegionOne compute internal http://controller:8774/v2.1
openstack endpoint create --region RegionOne compute admin http://controller:8774/v2.1

# 创建placement用户,添加 admin 角色
openstack user create --domain default --password=placement placement
openstack role add --project service --user placement admin

# 创建 placement 服务实体API 端点
openstack service create --name placement --description "Placement API" placement
openstack endpoint create --region RegionOne placement public http://controller:8778
openstack endpoint create --region RegionOne placement internal http://controller:8778
openstack endpoint create --region RegionOne placement admin http://controller:8778

# 安装nova控制节点
for HOST in controller{1..3}; do
    echo "------------ $HOST ------------"
    ssh -T $HOST <<EOF
    # 安装 nova
    yum install -y openstack-nova-api openstack-nova-conductor \
    openstack-nova-console openstack-nova-novncproxy \
    openstack-nova-scheduler openstack-nova-placement-api

    # 备份 nova 默认配置文件, 创建 nova 配置文件
    [ -f /etc/nova/nova.conf.bak ] || cp /etc/nova/nova.conf{,.bak}
EOF
done

# nova配置文件

# 创建配置文件
cat <<'EOF' >/etc/nova/nova.conf
[DEFAULT]
my_ip = controller1
use_neutron = True
osapi_compute_listen = controller1
osapi_compute_listen_port = 8774
metadata_listen = controller1
metadata_listen_port = 8775
firewall_driver = nova.virt.firewall.NoopFirewallDriver
enabled_apis = osapi_compute,metadata
transport_url = rabbit://openstack:openstack@controller:5673

[api_database]
connection = mysql+pymysql://nova:nova@controller/nova_api

[database]
connection = mysql+pymysql://nova:nova@controller/nova

[api]
auth_strategy = keystone

[keystone_authtoken]
auth_uri = http://controller:5000
auth_url = http://controller:35357
memcached_servers = controller1:11211,controller2:11211,controller3:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = nova

[vnc]
enabled = true
vncserver_listen = $my_ip
vncserver_proxyclient_address = $my_ip
novncproxy_host=$my_ip
novncproxy_port=6080

[glance]
api_servers = http://controller:9292

[oslo_concurrency]
lock_path = /var/lib/nova/tmp

[placement]
os_region_name = RegionOne
project_domain_name = Default
project_name = service
auth_type = password
user_domain_name = Default
auth_url = http://controller:35357/v3
username = placement
password = placement

[scheduler]
discover_hosts_in_cells_interval = 300

[cache]
enabled = true
backend = oslo_cache.memcache_pool
memcache_servers = controller1:11211,controller2:11211,controller3:11211
EOF

# 配置nova-alacement-api
cat <<EOF >>/etc/httpd/conf.d/00-nova-placement-api.conf

# Placement API
<Directory /usr/bin>
   <IfVersion >= 2.4>
      Require all granted
   </IfVersion>
   <IfVersion < 2.4>
      Order allow,deny
      Allow from all
   </IfVersion>
</Directory>
EOF

# 重启 httpd
systemctl restart httpd
sleep 4

# 初始化数据库
su -s /bin/sh -c "nova-manage api_db sync" nova
su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova
su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova
sleep 2
su -s /bin/sh -c "nova-manage db sync" nova || { sleep 3; su -s /bin/sh -c "nova-manage db sync" nova; }

# 检测数据
nova-manage cell_v2 list_cells
mysql -h controller -u nova -pnova -e "use nova_api;show tables;"
mysql -h controller -u nova -pnova -e "use nova;show tables;" 
mysql -h controller -u nova -pnova -e "use nova_cell0;show tables;"

# 更改默认端口8778给集群VIP使用
sed -i 's/8778/9778/' /etc/httpd/conf.d/00-nova-placement-api.conf
systemctl restart httpd

# Haproxy 配置
if [ -z "$(grep 'Nova' /etc/haproxy/haproxy.cfg)" ];then
cat <<'EOF' >>/etc/haproxy/haproxy.cfg

########## Nova_compute ##########
listen nova_compute_api_cluster
  bind controller:8774
  balance source
  option tcpka
  option httpchk
  option tcplog
  server controller1 controller1:8774 check inter 2000 rise 2 fall 5
  server controller2 controller2:8774 check inter 2000 rise 2 fall 5
  server controller3 controller3:8774 check inter 2000 rise 2 fall 5

########## Nova-api-metadata ##########
listen Nova-api-metadata_cluster
  bind controller:8775
  balance source
  option tcpka
  option httpchk
  option tcplog
  server controller1 controller1:8775 check inter 2000 rise 2 fall 5
  server controller2 controller2:8775 check inter 2000 rise 2 fall 5
  server controller3 controller3:8775 check inter 2000 rise 2 fall 5

########## Nova_placement ##########
listen nova_placement_cluster
  bind controller:8778
  balance source
  option tcpka
  option tcplog
  server controller1 controller1:9778 check inter 2000 rise 2 fall 5
  server controller2 controller2:9778 check inter 2000 rise 2 fall 5
  server controller3 controller3:9778 check inter 2000 rise 2 fall 5

######### Nova_vncproxy #########
listen nova_vncproxy_cluster
  bind controller:6080
  #balance source
  option tcpka
  option tcplog
  server controller1 controller1:6080 check inter 2000 rise 2 fall 5
  server controller2 controller2:6080 check inter 2000 rise 2 fall 5
  server controller3 controller3:6080 check inter 2000 rise 2 fall 5
EOF
fi

# 同步配置到其他节点
rsync -avzP -e 'ssh -p 22' /etc/nova/* controller2:/etc/nova/
rsync -avzP -e 'ssh -p 22' /etc/nova/* controller3:/etc/nova/
rsync -avzP -e 'ssh -p 22' /etc/haproxy/* controller2:/etc/haproxy/
rsync -avzP -e 'ssh -p 22' /etc/haproxy/* controller3:/etc/haproxy/
rsync -avzP -e 'ssh -p 22' /etc/httpd/conf.d/00-nova-placement-api.conf controller2:/etc/httpd/conf.d/
rsync -avzP -e 'ssh -p 22' /etc/httpd/conf.d/00-nova-placement-api.conf controller3:/etc/httpd/conf.d/

# 替换监听主机
ssh controller2 "sed -i '1,7s/controller1/controller2/' /etc/nova/nova.conf"
ssh controller3 "sed -i '1,7s/controller1/controller3/' /etc/nova/nova.conf"



for HOST in controller{1..3}; do
    ssh -T $HOST "systemctl restart openstack-nova-api httpd haproxy"
done


# 配置服务跟随系统启动
for HOST in controller{1..3}; do
    echo "------------ $HOST ------------"
    ssh -T $HOST <<EOF
    # 配置服务跟随系统启动
    systemctl enable openstack-nova-api openstack-nova-consoleauth \
      openstack-nova-scheduler openstack-nova-conductor openstack-nova-novncproxy
    
    # 启动nova服务
    systemctl start openstack-nova-consoleauth \
      openstack-nova-scheduler openstack-nova-conductor openstack-nova-novncproxy
EOF
done

sleep 5

# 查看集群节点
nova service-list
nova-status upgrade check
openstack compute service list

echo '浏览器打开 http://192.168.0.11:1080/admin 查看Nova_compute,Nova-api-metadata,Nova_placement 集群状态
                          命令行执行 nova service-list 能看到服务列表
                          命令行执行 openstack compute service list 能看到服务状态信息
                          如果上面两条命令保错 需重新同步数据库： su -s /bin/sh -c "nova-manage db sync" nova '



