#!/bin/bash

# 初始化环境
#curl http://home.onlycloud.xin/code/openstack-01_init.sh | sh

# /dev/sdb 快速分区,新建2个30G分区(确保存在第二块硬盘空间大于60G)
echo -e 'n\np\n1\n\n+30G\nw' | fdisk /dev/sdb
echo -e 'n\np\n2\n\n+30G\nw' | fdisk /dev/sdb

# 格式化分区
mkfs.ext4 /dev/sdb1
mkfs.ext4 /dev/sdb2

# 挂载
# 创建数据目录,挂载
mkdir -p /data

# 开机挂载磁盘
echo '/dev/sdb1       /data   ext4    defaults        0 0' >>/etc/fstab
mount -a

# 安装 openstack 客户端, 工具, cinder, lvm2
yum install -y python-openstackclient openstack-selinux openstack-utils
yum install -y openstack-cinder targetcli python-keystone lvm2 nfs-utils rpcbind

# # 备份默认配置文件
[ -f /etc/cinder/cinder.conf.bak ] || cp /etc/cinder/cinder.conf{,.bak}

# 获取第一块网卡 ip地址
MyIP=$(ip add|grep global|awk -F'[ /]+' '{ print $3 }'|head -n 1)

# 创建 cinder 配置文件
cat <<'EOF' >/etc/cinder/cinder.conf
[DEFAULT]
auth_strategy = keystone
log_dir = /var/log/cinder
state_path = /var/lib/cinder
glance_api_servers = http://controller:9292
transport_url = rabbit://openstack:openstack@controller
enabled_backends = lvm,nfs

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

[lvm]
volume_driver = cinder.volume.drivers.lvm.LVMVolumeDriver
iscsi_helper = lioadm
iscsi_protocol = iscsi
volume_group = cinder_lvm01
iscsi_ip_address = cinder_ip
volumes_dir = $state_path/volumes
volume_backend_name = lvm01

[nfs]
volume_driver = cinder.volume.drivers.nfs.NfsDriver
nfs_shares_config = /etc/cinder/nfs_shares
nfs_mount_point_base = $state_path/mnt
volume_backend_name = nfs01
EOF

# 替换 lvm 配置监听主机
sed -i "s/cinder_ip/$MyIP/" /etc/cinder/cinder.conf

# 设置 cinder 配置文件权限
chmod 640 /etc/cinder/cinder.conf
chgrp cinder /etc/cinder/cinder.conf

# 配置 lvm 后端存储
# 创建 LVM 物理卷 pv 与卷组 vg
echo -e 'y\n' | pvcreate /dev/sdb2
vgcreate cinder_lvm01 /dev/sdb2
vgdisplay

# 备份默认配置文件
[ -f /etc/cinder/cinder.conf.bak ] || cp /etc/cinder/cinder.conf{,.bak}
[ -f /etc/lvm/lvm.conf.bak ] || cp /etc/lvm/lvm.conf{,.bak}

# 配置 NFS 后端存储

# 获取第一块网卡 ip地址
# MyIP=$(ip add|grep global|awk -F'[ /]+' '{ print $3 }'|head -n 1)

# 创建数据目录,设置目录权限(NFS Server端)
mkdir -p /data/cinder_nfs1
chown cinder:cinder /data/cinder_nfs1
chmod 777 /data/cinder_nfs1
echo "/data/cinder_nfs1 *(rw,root_squash,sync,anonuid=165,anongid=165)">/etc/exports
exportfs -r

# 配置 NFS 权限 (NFS 客户端)
# echo "$MyIP:/data/cinder_nfs1" >/etc/cinder/nfs_shares
echo "cinder1:/data/cinder_nfs1" >/etc/cinder/nfs_shares
chmod 640 /etc/cinder/nfs_shares
chown root:cinder /etc/cinder/nfs_shares

# 启动服务,设置开机启动, 验证 NFS
systemctl restart rpcbind nfs-server
systemctl enable rpcbind nfs-server
showmount -e localhost

# 服务管理
systemctl enable openstack-cinder-api openstack-cinder-scheduler
systemctl start openstack-cinder-api openstack-cinder-scheduler
systemctl enable openstack-cinder-volume target
systemctl start openstack-cinder-volume target

# 验证
sleep 6
source ~/admin-openstack.sh
cinder service-list
openstack volume service list     # 能看到存储节点@lvm, @nfs 且up状态说明配置成功


# 创建云硬盘
# 创建云硬盘类型,关联volum
# LVM 
# (backend_name与配置文件名对应)
cinder type-create lvm
cinder type-key lvm set volume_backend_name=lvm01

# NFS
cinder type-create nfs
cinder type-key nfs set volume_backend_name=nfs01

# check
cinder extra-specs-list
cinder type-list

# delete
# cinder type-delete nfs
# cinder type-delete lvm

# 创建云盘(容量单位G)
openstack volume create --size 10 --type lvm disk01        # lvm类型
openstack volume create --size 10 --type nfs disk02        # nfs类型
openstack volume list
