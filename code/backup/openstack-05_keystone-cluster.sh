#!/bin/bash

check() {
     [ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m"
}


# 所有节点安装 Keystone 配置Memcached
for HOST in controller1 controller2 controller3; do
    echo "--------------- $HOST ---------------"
    ssh -T $HOST <<'EOF'
    check() ([ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m")
    # 安装 mod_wsgi, memcache, keystone
    yum install -y openstack-keystone httpd mod_wsgi memcached python-memcached >/dev/null 2>&1; check 'Keystone, Mod_wsgi, Memcache Install'

    # 配置Memcached
    [ -f /etc/sysconfig/memcached.bak ] || cp /etc/sysconfig/memcached{,.bak}
    sed -i 's/127.0.0.1/0.0.0.0/' /etc/sysconfig/memcached
    systemctl enable memcached >/dev/null 2>&1; check 'Enable Memcached'
    systemctl start memcached >/dev/null 2>&1; check 'Start Memcached'
    netstat -antp | grep 11211
EOF
done


# 配置Keystone

# 备份默认配置
[ -f /etc/keystone/keystone.conf.bak ] || cp /etc/keystone/keystone.conf{,.bak}

# 生成随机密码
Keys=$(openssl rand -hex 10)
echo $Keys
echo "kestone  $Keys" >~/openstack.log

# 创建 keystone 配置文件
cat <<EOF  >/etc/keystone/keystone.conf
[DEFAULT]
admin_token = $Keys
verbose = true
[database]
connection = mysql+pymysql://keystone:keystone@controller/keystone
[memcache]
servers = controller1:11211,controller2:11211,controller3:11211
[token]
provider = fernet
driver = memcache
# expiration = 86400
# caching = true
# cache_time = 86400
[cache]
enabled = true
backend = oslo_cache.memcache_pool
memcache_servers = controller1:11211,controller2:11211,controller3:11211
EOF

# 初始化Fernet密匙
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

# 创建keystone http配置文件
\cp /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/wsgi-keystone.conf

# 修改默认端口5000,35357
[ -f /etc/httpd/conf.d/wsgi-keystone.conf.bak ] || cp /etc/httpd/conf.d/wsgi-keystone.conf{,.bak}
sed -i 's/5000/4999/' /etc/httpd/conf.d/wsgi-keystone.conf
sed -i 's/35357/35356/' /etc/httpd/conf.d/wsgi-keystone.conf

# 同步配置到其它节点(用scp会改变文件权限)
echo "---------- rsync keystone config -> controller2,3 ----------"
rsync -avzP -e 'ssh -p 22' /etc/keystone/* controller2:/etc/keystone/
rsync -avzP -e 'ssh -p 22' /etc/keystone/* controller3:/etc/keystone/
echo -e '\n'
echo "---------- rsync wsgi-keystone.conf -> controller2,3 ----------"
rsync -avzP -e 'ssh -p 22' /etc/httpd/conf.d/wsgi-keystone.conf controller2:/etc/httpd/conf.d/
rsync -avzP -e 'ssh -p 22' /etc/httpd/conf.d/wsgi-keystone.conf controller3:/etc/httpd/conf.d/


# 初始化Keystone

# 初始化keystone数据库
su -s /bin/sh -c "keystone-manage db_sync" keystone

# 检查表是否创建成功
echo "---------- show database keystone tables ----------"
mysql -h controller -ukeystone -pkeystone -te "use keystone;show tables;"

# 配置Haproxy

# 添加 Keystone 代理
if [ -z "$(grep 'Keystone' /etc/haproxy/haproxy.cfg)" ];then
cat <<EOF >>/etc/haproxy/haproxy.cfg

############ Keystone ############
listen keystone_admin_cluster
  bind controller:35357
  #balance source
  option tcpka
  option httpchk 
  option tcplog
  server controller1 controller1:35356 check inter 2000 rise 2 fall 5
  server controller2 controller2:35356 check inter 2000 rise 2 fall 5
  server controller3 controller3:35356 check inter 2000 rise 2 fall 5

listen keystone_public_cluster
  bind controller:5000
  #balance source
  option tcpka
  option httpchk 
  option tcplog
  server controller1 controller1:4999 check inter 2000 rise 2 fall 5
  server controller2 controller2:4999 check inter 2000 rise 2 fall 5
  server controller3 controller3:4999 check inter 2000 rise 2 fall 5
EOF
fi

# 同步 Haproxy 配置
echo "---------- rsync keystone config -> controller2,3 ----------"
rsync -avzP -e 'ssh -p 22' /etc/haproxy/haproxy.cfg  controller2:/etc/haproxy/
rsync -avzP -e 'ssh -p 22' /etc/haproxy/haproxy.cfg  controller3:/etc/haproxy/

# 重启 httpd服务
systemctl restart httpd >/dev/null 2>&1; check 'controller1 Restart Httpd'
ssh controller2 "systemctl restart httpd" >/dev/null 2>&1; check 'controller2 Restart Httpd'
ssh controller3 "systemctl restart httpd" >/dev/null 2>&1; check 'controller3 Restart Httpd'
systemctl restart haproxy >/dev/null 2>&1; check 'controller1 Restart Haproxy'
ssh controller2 "systemctl restart haproxy" >/dev/null 2>&1; check 'controller2 Restart Haproxy'
ssh controller3 "systemctl restart haproxy" >/dev/null 2>&1; check 'controller3 Restart Haproxy'
echo -e "\n\n"

# 检验节点状态
echo '------------ check node:35356/v3 status ------------'
curl http://controller1:35356/v3
curl http://controller2:35356/v3
curl http://controller3:35356/v3
echo -e '\n'

echo '------------ check controller:35357/v3 status ------------'
curl http://controller:35357/v3
echo -e '\n\n'

# 创建服务实体和API端点

# 设置admin用户（管理用户）和密码,服务实体和API端点

keystone-manage bootstrap --bootstrap-password admin \
  --bootstrap-admin-url http://controller:35357/v3/ \
  --bootstrap-internal-url http://controller:5000/v3/ \
  --bootstrap-public-url http://controller:5000/v3/ \
  --bootstrap-region-id RegionOne

# 创建 OpenStack 客户端环境脚本
cat <<EOF  >~/admin-openstack.sh
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default 
export OS_PROJECT_NAME=admin 
export OS_USERNAME=admin
export OS_PASSWORD=admin
export OS_AUTH_URL=http://controller:35357/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

# 测试脚本是否生效
echo '---------- check user:admin scritps variables ----------'
source ~/admin-openstack.sh
openstack token issue
echo -e '\n'

# 创建service项目,创建glance,nova,neutron用户，并授权
openstack project create --domain default --description "Service Project" service
openstack user create --domain default --password=glance glance
openstack role add --project service --user glance admin
openstack user create --domain default --password=nova nova
openstack role add --project service --user nova admin
openstack user create --domain default --password=neutron neutron
openstack role add --project service --user neutron admin


# 创建demo项目(普通用户密码及角色)
openstack project create --domain default --description "Demo Project" demo
openstack user create --domain default --password=demo demo
openstack role create user
openstack role add --project demo --user demo user

# 创建demo环境脚本
cat <<EOF >~/demo-openstack.sh
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=demo
export OS_USERNAME=demo
export OS_PASSWORD=demo
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

# 测试脚本是否生效
echo '---------- check user:demo scritps variables ----------'
source ~/demo-openstack.sh
openstack token issue

echo '
        浏览器打开 http://192.168.0.11:1080/admin 查看  keystone_admin_cluster,keystone_public_cluster 状态
        检测是否能获取节点信息
        curl http://controller1:35356/v3
        curl http://controller2:35356/v3
        curl http://controller3:35356/v3
        curl http://controller:35357/v3'
