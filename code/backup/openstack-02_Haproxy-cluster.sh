#!/bin/bash

vip=10.0.0.10

# 输出颜色
check() {
     [ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m"
}


# 所有节点 安装 配置 corosync, pacemaker, pcs
for HOST in controller1 controller2 controller3; do
    echo "--------------- $HOST ---------------"
    ssh -T $HOST <<'EOF'
    check() ([ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m")
    # 安装 corosync, pacemaker, pcs
    yum -y install corosync pacemaker pcs fence-agents resource-agents >/dev/null 2>&1; check 'Corosync, Pacemaker, Pcsd Install'

    # 服务并配置其随系统启动
    systemctl enable pcsd >/dev/null 2>&1; check 'Enable pcsd'
    systemctl start pcsd >/dev/null 2>&1; check 'Start pcsd'

    # 配置群集账户密码
    echo centos | passwd --stdin hacluster >/dev/null 2>&1; check "Account <hacluster> password change"
    echo -e '\n\n'
EOF
done


# controller1节点 创建集群 初始化集群
echo "--------------- $(hostname) ---------------"
# 创建集群
pcs cluster auth -u hacluster -p centos controller1 controller2 controller3 >/dev/null 2>&1; check 'Account <hacluster> Password Change'
pcs cluster setup --start --name my_cluster controller1 controller2 controller3 >/dev/null 2>&1; check 'Cluster Setup'

# 启动集群, 集群随系统启动
pcs cluster start --all >/dev/null 2>&1; check 'Cluster Start'
pcs cluster enable --all >/dev/null 2>&1; check 'Cluster Enabled'

# 禁用STONITH, 无仲裁时选择忽略
pcs property set stonith-enabled=false
pcs property set no-quorum-policy=ignore

# 创建 VIP 资源
pcs resource create vip ocf:heartbeat:IPaddr2 ip=$vip cidr_netmask=24 op monitor interval=28s  >/dev/null 2>&1; check 'Create VIP Resource'

echo -e '\n\n'

# 所有节点 安装 配置 http haproxy
for HOST in controller1 controller2 controller3; do
    echo "--------------- $HOST ---------------"
    ssh -T $HOST <<'EOF'
    check() ([ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m")
    # 安装httpd
    yum -y install httpd haproxy >/dev/null 2>&1; check 'Httpd, Haproxy Install'

    # 配置 http
    [ -f /etc/httpd/conf/httpd.conf.bak ] || cp /etc/httpd/conf/httpd.conf{,.bak}    # 备份默认配置文件
    sed -i 's#^Listen.*#Listen 8080#'  /etc/httpd/conf/httpd.conf    # 修改监听端口

    # 配置 haproxy
    [ -f /etc/haproxy/haproxy.cfg.bak ] || cp /etc/haproxy/haproxy.cfg{,.bak}    # 备份默认配置
    echo "net.ipv4.ip_nonlocal_bind = 1" >>/etc/sysctl.conf    # 允许没VIP时启动
    sysctl -p >/dev/null    # 应用配置

    # 配置服务随系统启动
    systemctl enable httpd >/dev/null 2>&1; check 'Enable Httpd'
    systemctl enable haproxy >/dev/null 2>&1; check 'Enable Haproxy'
    echo -e '\n\n'
EOF
done

# 替换 http 站点域名主机 测试页面
ssh controller1 "sed -i 's/#ServerName.*/ServerName controller1/' /etc/httpd/conf/httpd.conf"
ssh controller2 "sed -i 's/#ServerName.*/ServerName controller2/' /etc/httpd/conf/httpd.conf"
ssh controller3 "sed -i 's/#ServerName.*/ServerName controller3/' /etc/httpd/conf/httpd.conf"
ssh controller1 "echo 'controller1' >/var/www/html/index.html"
ssh controller2 "echo 'controller2' >/var/www/html/index.html"
ssh controller3 "echo 'controller3' >/var/www/html/index.html"

# ontroller1节点 Haproxy 配置文件
cat <<'EOF' >/etc/haproxy/haproxy.cfg
############ 全局配置 ############
global
log 127.0.0.1 local0
log 127.0.0.1 local1 notice
daemon
nbproc 1       # 进程数量
maxconn 4096   # 最大连接数
user haproxy   # 运行用户
group haproxy  # 运行组
chroot /var/lib/haproxy
pidfile /var/run/haproxy.pid

############ 默认配置 ############
defaults
log global
mode http            # 默认模式{ tcp|http|health }
option httplog       # 日志类别,采用httplog
option dontlognull   # 不记录健康检查日志信息
retries 2            # 2次连接失败不可用
option forwardfor    # 后端服务获得真实ip
option httpclose     # 请求完毕后主动关闭http通道
option abortonclose  # 服务器负载很高，自动结束比较久的链接
maxconn 4096         # 最大连接数
timeout connect 5m   # 连接超时
timeout client 1m    # 客户端超时
timeout server 31m   # 服务器超时
timeout check 10s    # 心跳检测超时
balance roundrobin   # 负载均衡方式，轮询

########## 统计页面配置 ##########
listen stats
  bind 0.0.0.0:1080
  mode http
  option httplog
  log 127.0.0.1 local0 err
  maxconn 10               # 最大连接数
  stats refresh 30s
  stats uri /admin         #状态页面 http//ip:1080/admin 访问
  stats realm Haproxy\ Statistics
  stats auth admin:admin   # 用户和密码:admin
  stats hide-version       # 隐藏版本信息  
  stats admin if TRUE      # 设置手工启动/禁用

# haproxy web 代理配置
############ WEB ############
listen dashboard_cluster  
  bind controller:80
  balance  roundrobin  
  option  tcpka  
  option  httpchk  
  option  tcplog  
  server controller1 controller1:8080 check port 8080 inter 2000 rise 2 fall 5
  server controller2 controller2:8080 check port 8080 inter 2000 rise 2 fall 5
  server controller3 controller3:8080 check port 8080 inter 2000 rise 2 fall 5
EOF

# controller1节点 配置 haproxy 日志
echo <<'EOF' >/etc/rsyslog.d/haproxy.conf
$ModLoad imudp
$UDPServerRun 514
$template Haproxy,"%rawmsg% \n"
local0.=info -/var/log/haproxy.log;Haproxy
local0.notice -/var/log/haproxy-status.log;Haproxy
EOF



# 同步配置到 controller2, controller3
echo "--- scp haproxy.cfg haproxy.conf -> controller2, 3 ---"
scp /etc/haproxy/haproxy.cfg controller2:/etc/haproxy/haproxy.cfg
scp /etc/haproxy/haproxy.cfg controller3:/etc/haproxy/haproxy.cfg
scp /etc/rsyslog.d/haproxy.conf controller2:/etc/rsyslog.d/haproxy.conf
scp /etc/rsyslog.d/haproxy.conf controller3:/etc/rsyslog.d/haproxy.conf
echo -e '\n\n'

# 启动服务
for HOST in controller1 controller2 controller3; do
    echo "--------------- $HOST ---------------"
    ssh -T  $HOST <<'EOF'
    check() ([ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m")
    systemctl restart rsyslog >/dev/null 2>&1; check 'Restart Rsyslog'
    systemctl start httpd >/dev/null 2>&1; check 'Start Httpd'
    systemctl start haproxy>/dev/null 2>&1; check 'Start Haproxy'
    echo -e '\n\n'
EOF
done


echo -e "
----- 浏览器打开以下URL验证 Haproxy节点状态 -----

    http://192.168.0.11:1080/admin 
    http://192.168.0.11:1080/admin 
    http://192.168.0.11:1080/admin

     用户名:密码 / admin:admin

http://10.0.0.10/ 浏览器打开此URL刷新可以看到服务器轮询切换
"
