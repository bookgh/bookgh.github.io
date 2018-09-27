#!/bin/bash

# 初始化环境
#curl http://home.onlycloud.xin/openstack-01_init.sh -o 01openstack-init.sh ;sh 01openstack-init.sh

# 安装OpenStack客户端,工具
yum install -y python-openstackclient openstack-selinux python2-PyMySQL openstack-utils

# 安装 Nova
yum install -y openstack-nova-compute

# 安装 Neutron
yum install -y openstack-neutron-linuxbridge ebtables ipset

# 备份默认配置
[ -f /etc/nova/nova.conf.bak ] || cp /etc/nova/nova.conf{,.bak}
[ -f /etc/neutron/neutron.conf.bak ] || cp /etc/neutron/neutron.conf{,.bak}
[ -f /etc/neutron/plugins/ml2/linuxbridge_agent.ini.bak ] || cp /etc/neutron/plugins/ml2/linuxbridge_agent.ini{,.bak}

# 设置 Nova 实例路径(磁盘镜像文件)
Vdir=/date/nova
VHD=$Vdir/instances
mkdir -p $VHD
chown -R nova:nova $Vdir

# 使用QEMU或KVM ,KVM硬件加速需要硬件支持,虚拟机使用 qemu
#[[ `egrep -c '(vmx|svm)' /proc/cpuinfo` = 0 ]] && { Kvm=qemu; } || { Kvm=kvm; }
Kvm=qemu

# nova 配置
# 获取第一块网卡名
Netname=$(ip add|egrep global|awk '{ print $NF }'|head -n 1)

# 获取第一块网卡 ip地址
MyIP=$(ip add|grep global|awk -F'[ /]+' '{ print $3 }'|head -n 1)

# VNC代理地址vip
VncProxy=10.0.0.10

# 创建 nova 配置文件
cat <<EOF  >/etc/nova/nova.conf
[DEFAULT]
instances_path= $VHD
enabled_apis = osapi_compute,metadata
transport_url = rabbit://openstack:openstack@controller:5673
use_neutron = True
firewall_driver = nova.virt.firewall.NoopFirewallDriver
cpu_allocation_ratio = 4

[api_database]
connection = mysql+pymysql://nova:nova@controller/nova_api

[database]
connection = mysql+pymysql://nova:nova@controller/nova

[api]
auth_strategy = keystone

[keystone_authtoken]
auth_uri = http://controller:5000
auth_url = http://controller:35357
memcached_servers = controller:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = nova

[vnc]
enabled = true
vncserver_listen = 0.0.0.0
vncserver_proxyclient_address = $MyIP
novncproxy_base_url = http://${VncProxy}:6080/vnc_auto.html

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

[libvirt]
virt_type = $Kvm

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
EOF

# 创建 neutron 配置文件
cat <<'EOF'  >/etc/neutron/neutron.conf
[DEFAULT]
auth_strategy = keystone
transport_url = rabbit://openstack:openstack@controller:5673

[keystone_authtoken]
auth_uri = http://controller:5000
auth_url = http://controller:35357
memcached_servers = controller:11211
auth_type = password
project_domain_id = default
user_domain_id = default
project_name = service
username = neutron
password = neutron

[oslo_concurrency]
lock_path = /var/lib/neutron/tmp
EOF

# 创建 linuxbridge-agent 配置文件
cat <<EOF >/etc/neutron/plugins/ml2/linuxbridge_agent.ini
[linux_bridge]
physical_interface_mappings = provider:$Netname

[securitygroup]
enable_security_group = true
firewall_driver = neutron.agent.linux.iptables_firewall.IptablesFirewallDriver

[vxlan]
enable_vxlan = false
# local_ip = 10.0.0.21
# l2_population = true
EOF

# 配置服务跟随系统启动, 启动服务
systemctl enable libvirtd openstack-nova-compute neutron-linuxbridge-agent
systemctl start libvirtd openstack-nova-compute neutron-linuxbridge-agent
