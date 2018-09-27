#!/bin/bash

# site: https://bookgh.github.io/posts/openstack-01.html

# 关闭, 禁用 NetworkManager(此时关闭服务会导致不能上网)
# systemctl stop NetworkManager
# systemctl disable NetworkManager

# 关闭, 禁用 firewalld
systemctl stop firewalld
systemctl disable firewalld

# 关闭, 禁用 selinux
setenforce 0
sed -i '/^SELINUX=.*/c SELINUX=disabled' /etc/selinux/config

# 删除默认yum 源
rm -f /etc/yum.repos.d/*

# 下载阿里云 yum 源
curl -so /etc/yum.repos.d/Centos-7.repo http://mirrors.aliyun.com/repo/Centos-7.repo

# 删除阿里云内网地址
sed -i '/aliyuncs.com/d' /etc/yum.repos.d/Centos-7.repo


# 安装 epel-release
yum -y install epel-release

# 删除默认 epel 源
rm -rf /etc/yum.repos.d/epel*

# 下载阿里云 epel 源
curl -so /etc/yum.repos.d/epel-7.repo http://mirrors.aliyun.com/repo/epel-7.repo

# 删除阿里云内网地址
sed -i '/aliyuncs.com/d' /etc/yum.repos.d/epel-7.repo

# 手动配置阿里云openstack源(关闭GPG验证 否则软件安装时会报错)
cat <<'EOF' >/etc/yum.repos.d/centos-openstack.repo
[centos-openstack-pike]
name=CentOS-$releasever-openstack-pike
enabled=1
failovermethod=priority
baseurl=http://mirrors.aliyun.com/centos/$releasever/cloud/$basearch/openstack-pike
gpgcheck=0
#gpgkey=http://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[centos-virt-kvm-common]
name=CentOS-$releasever-virt-kvm-common
enabled=1
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/$releasever/virt/$basearch/kvm-common/
gpgcheck=0
#gpgkey=http://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
EOF

# 更新yum 缓存
yum clean all
yum makecache

# 常用工具
yum -y install wget vim ntpdate net-tools lsof

# 时间同步
/usr/sbin/ntpdate ntp6.aliyun.com 
echo "*/3 * * * * /usr/sbin/ntpdate ntp6.aliyun.com  &> /dev/null" > /tmp/crontab
crontab /tmp/crontab

# 配置内核参数
cat <<EOF >>/etc/security/limits.conf
* soft nofile 65536  
* hard nofile 65536 
EOF

cat <<EOF >>/etc/sysctl.conf
fs.file-max=655350  
net.ipv4.ip_local_port_range = 1025 65000  
net.ipv4.tcp_tw_recycle = 1 
EOF

clear

echo "
Firewalld : $(systemctl status firewalld | grep Active | awk '{print $2,$3}')
Selinux   : $(getenforce)   $(echo `grep --color=auto '^SELINUX' /etc/selinux/config` | tr '/n' '/t')
Kernel    : $(echo `sysctl -p`)
"
