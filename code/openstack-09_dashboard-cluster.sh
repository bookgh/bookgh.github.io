#!/bin/bash

# 安装Dashboard
for HOST in controller{1..3}; do
    echo "------------ $HOST ------------"
    ssh -T $HOST <<'EOF'
    # 安装 dashboard
    yum -y install openstack-dashboard

    # 网页无法访问 dashboard 服务器内部错误解决方法
    if [ -z "$(grep 'WSGIApplicationGroup' /etc/httpd/conf.d/openstack-dashboard.conf)" ];then
        sed -i '3a WSGIApplicationGroup %{GLOBAL}' /etc/httpd/conf.d/openstack-dashboard.conf
    fi
EOF
done

# 配置Dashboard

# 备份默认配置
[ -f /etc/openstack-dashboard/local_settings.bak ] || cp /etc/openstack-dashboard/local_settings{,.bak}

# 修改配置文件
Setfiles=/etc/openstack-dashboard/local_settings
# egrep -v '#|^$' /etc/openstack-dashboard/local_settings.bak >$Setfiles          # 重新生成配置文件(去除注释,空行)
sed -i 's#_member_#user#g' $Setfiles
sed -i 's#OPENSTACK_HOST = "127.0.0.1"#OPENSTACK_HOST = "controller"#' $Setfiles

# 允许所有主机访问
sed -i "/ALLOWED_HOSTS/cALLOWED_HOSTS = ['*', ]" $Setfiles

# 去掉memcached注释
sed -in '153,158s/#//' $Setfiles 
sed -in '160,164s/.*/#&/' $Setfiles

# 修改时区
sed -i 's#UTC#Asia/Shanghai#g' $Setfiles
sed -i 's#%s:5000/v2.0#%s:5000/v3#' $Setfiles
sed -i '/ULTIDOMAIN_SUPPORT/cOPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True' $Setfiles
sed -i "s@^#OPENSTACK_KEYSTONE_DEFAULT@OPENSTACK_KEYSTONE_DEFAULT@" $Setfiles

echo -e "\n" >>$Setfiles
echo '# set add' >>$Setfiles
echo "OPENSTACK_API_VERSIONS = {" >>$Setfiles
echo -e '    "identity": 3,' >>$Setfiles
echo -e '    "image": 2,' >>$Setfiles
echo -e '    "volume": 2,' >>$Setfiles
echo '}' >>$Setfiles

# 重启 httpd
systemctl restart httpd

# 同步 controller1 配置到其它节点
rsync -avzP  -e 'ssh -p 22'  /etc/openstack-dashboard/local_settings  controller2:/etc/openstack-dashboard/
rsync -avzP  -e 'ssh -p 22'  /etc/openstack-dashboard/local_settings  controller3:/etc/openstack-dashboard/

# 重启http
ssh controller2 "systemctl restart httpd"
ssh controller3 "systemctl restart httpd"

echo "
        #  通过集群 IP 访问Dashboard     http://10.0.0.10/dashboard/
        # 
        #  http://10.0.0.10/dashboard/   http://192.168.16.21:8080/dashboard/
        #  http://192.168.0.11:8080/dashboard
        #  http://192.168.0.12:8080/dashboard
        #  http://192.168.0.13:8080/dashboard
        #
        #  域      :  default
        #  用户名  :  admin
        #  密码    :  admin
"
