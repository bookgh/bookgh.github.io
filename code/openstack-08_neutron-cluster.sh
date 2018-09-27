#!/bin/bash


# 创建 neutron 数据库,用户, 授权
source ~/PASS                        # 读取数据库密码
mysql -u root -p$DBPass -e "
create database neutron;
grant all privileges on neutron.* to 'neutron'@'localhost' identified by 'neutron';
grant all privileges on neutron.* to 'neutron'@'%' identified by 'neutron';"

# 创建 neutron 用户,添加 admin 角色
source ~/admin-openstack.sh    # 获取管理员凭证
openstack user create --domain default --password=neutron neutron
openstack role add --project service --user neutron admin

# 创建 neutron 服务实体, API 端点
openstack service create --name neutron --description "OpenStack Networking" network
openstack endpoint create --region RegionOne network public http://controller:9696
openstack endpoint create --region RegionOne network internal http://controller:9696
openstack endpoint create --region RegionOne network admin http://controller:9696

# 安装 neutron
for HOST in controller{1..3}; do
    echo "------------ $HOST ------------"
    ssh -T $HOST <<EOF
    yum install -y openstack-neutron openstack-neutron-ml2 \
      openstack-neutron-linuxbridge python-neutronclient ebtables ipset

    # 备份默认配置文件
    [ -f /etc/neutron/neutron.conf.bak2 ] || cp /etc/neutron/neutron.conf{,.bak2}
    [ -f /etc/neutron/plugins/ml2/ml2_conf.ini.bak ] || cp /etc/neutron/plugins/ml2/ml2_conf.ini{,.bak}
    ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
    [ -f /etc/neutron/plugins/ml2/linuxbridge_agent.ini.bak ] || cp /etc/neutron/plugins/ml2/linuxbridge_agent.ini{,.bak}
    [ -f /etc/neutron/dhcp_agent.ini.bak ] || cp /etc/neutron/dhcp_agent.ini{,.bak}
    [ -f /etc/neutron/metadata_agent.ini.bak ] || cp /etc/neutron/metadata_agent.ini{,.bak}
    [ -f /etc/neutron/l3_agent.ini.bak ] || cp /etc/neutron/l3_agent.ini{,.bak}
EOF
done

# 配置 neutron
# 创建 neutron 配置文件

if [ -z "$(grep 'Neutron' /etc/nova/nova.conf)" ];then
cat <<'EOF' >>/etc/nova/nova.conf

# Neutron
[neutron]
url = http://controller:9696
auth_url = http://controller:35357
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = neutron
service_metadata_proxy = true
metadata_proxy_shared_secret = metadata
EOF
fi

cat <<'EOF' >/etc/neutron/metadata_agent.ini
[DEFAULT]
nova_metadata_ip = controller
metadata_proxy_shared_secret = metadata
EOF

cat <<'EOF' >/etc/neutron/plugins/ml2/ml2_conf.ini
[ml2]
tenant_network_types = 
type_drivers = vlan,flat
mechanism_drivers = linuxbridge
extension_drivers = port_security

[ml2_type_flat]
flat_networks = provider

[securitygroup]
enable_ipset = True
#vlan

# [ml2_type_valn]
# network_vlan_ranges = provider:3001:4000
EOF

# 获取第一块网卡名
Netname=$(ip add|egrep global|awk '{ print $NF }'|head -n 1)

# provider:网卡名
cat <<EOF >/etc/neutron/plugins/ml2/linuxbridge_agent.ini
[linux_bridge]
physical_interface_mappings = provider:$Netname

[vxlan]
enable_vxlan = false
#local_ip = 10.0.0.10
#l2_population = true

[agent]
prevent_arp_spoofing = True

[securitygroup]
firewall_driver = neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
enable_security_group = True
EOF

cat <<'EOF' >/etc/neutron/dhcp_agent.ini
[DEFAULT]
interface_driver = linuxbridge
dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq
enable_isolated_metadata = true
EOF

# 创建 neutron 配置文件
cat <<EOF >/etc/neutron/neutron.conf
[DEFAULT]
bind_port = 9696
bind_host = controller1
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = true
transport_url = rabbit://openstack:openstack@controller
auth_strategy = keystone
notify_nova_on_port_status_changes = true
notify_nova_on_port_data_changes = true

[keystone_authtoken]
auth_uri = http://controller:5000
auth_url = http://controller:35357
memcached_servers = controller1:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = neutron

[nova]
auth_url = http://controller:35357
auth_type = password
project_domain_id = default
user_domain_id = default
region_name = RegionOne
project_name = service
username = nova
password = nova

[database]
connection = mysql://neutron:neutron@controller:3306/neutron

[oslo_concurrency]
lock_path = /var/lib/neutron/tmp 
EOF

cat <<'EOF' >/etc/neutron/l3_agent.ini
[DEFAULT]
interface_driver = linuxbridge
EOF

# 初始化数据库
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron

# 验证数据库
mysql -h controller -u neutron -pneutron -te "use neutron;show tables;"

# Haproxy配置
if [ -z "$(grep 'Neutron' /etc/haproxy/haproxy.cfg)" ];then
cat <<EOF >>/etc/haproxy/haproxy.cfg

##########Neutron_API##########
listen Neutron_API_cluster
  bind controller:9696
  balance source
  option tcpka
  option tcplog
  server controller1 controller1:9696 check inter 2000 rise 2 fall 5
  server controller2 controller2:9696 check inter 2000 rise 2 fall 5
  server controller3 controller3:9696 check inter 2000 rise 2 fall 5
EOF
fi

# 同步软件配置文件
rsync -avzP -e 'ssh -p 22' /etc/nova/* controller2:/etc/nova/
rsync -avzP -e 'ssh -p 22' /etc/nova/* controller3:/etc/nova/
rsync -avzP -e 'ssh -p 22' /etc/neutron/* controller2:/etc/neutron/
rsync -avzP -e 'ssh -p 22' /etc/neutron/* controller3:/etc/neutron/
rsync -avzP -e 'ssh -p 22' /etc/haproxy/* controller2:/etc/haproxy/
rsync -avzP -e 'ssh -p 22' /etc/haproxy/* controller3:/etc/haproxy/

# 修改监听主机
ssh controller2 "sed -i '1,7s/controller1/controller2/' /etc/nova/nova.conf"
ssh controller3 "sed -i '1,7s/controller1/controller3/' /etc/nova/nova.conf"
ssh controller2 "sed -i 's/controller1/controller2/' /etc/neutron/neutron.conf"
ssh controller3 "sed -i 's/controller1/controller3/' /etc/neutron/neutron.conf"

# 服务配置
for HOST in controller{1..3}; do
    echo "------------ $HOST ------------"
    ssh -T $HOST <<EOF
    # 重启相关服务
    systemctl restart haproxy openstack-nova-api

    # 配置 neutron-server 相关服务随系统启动
    systemctl enable neutron-server neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent

    # 启动 neutron 相关服务
    systemctl start neutron-server neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent
EOF
done
sleep 10


# 能看到 neutron-dhcp-agent neutron-metadata-agent 各3个
openstack network agent list
openstack service list

echo '执行 openstack network agent list 能看到 neutron-dhcp-agent neutron-metadata-agent 各3个
       浏览器打开 http://192.168.0.11:1080/admin 查看 Neutron_API_cluster 集群状态'
