#!/bin/bash

vip=10.0.0.10

# 所有节点 安装 配置 corosync, pacemaker, pcs
for HOST in controller1 controller2 controller3; do
    echo "--------------- $HOST ---------------"
    ssh -T $HOST <<'EOF'
    # 安装 corosync, pacemaker, pcs
    yum -y install corosync pacemaker pcs fence-agents resource-agents  

    # 服务并配置其随系统启动
    systemctl enable pcsd  
    systemctl start pcsd  

    # 配置群集账户密码
    echo centos | passwd --stdin hacluster  
EOF
done


# controller1节点 创建集群 初始化集群
echo "--------------- $(hostname) ---------------"
# 创建集群
pcs cluster auth -u hacluster -p centos controller1 controller2 controller3  
pcs cluster setup --start --name my_cluster controller1 controller2 controller3  

# 启动集群, 集群随系统启动
pcs cluster start --all  
pcs cluster enable --all  

# 禁用STONITH, 无仲裁时选择忽略
pcs property set stonith-enabled=false
pcs property set no-quorum-policy=ignore

# 创建 VIP 资源
pcs resource create vip ocf:heartbeat:IPaddr2 ip=$vip cidr_netmask=24 op monitor interval=28s   

# 所有节点 安装 配置 http haproxy
for HOST in controller1 controller2 controller3; do
    echo "--------------- $HOST ---------------"
    ssh -T $HOST <<EOF
    # 安装httpd
    yum -y install httpd haproxy  

    # 配置 http
    [ -f /etc/httpd/conf/httpd.conf.bak ] || cp /etc/httpd/conf/httpd.conf{,.bak}    # 备份默认配置文件
    sed -i 's#^Listen.*#Listen 8080#'  /etc/httpd/conf/httpd.conf    # 修改监听端口
    sed -i 's/#ServerName.*/ServerName $HOST/' /etc/httpd/conf/httpd.conf    # 修改监听主机名

    # 配置 haproxy
    [ -f /etc/haproxy/haproxy.cfg.bak ] || cp /etc/haproxy/haproxy.cfg{,.bak}    # 备份默认配置
    echo "net.ipv4.ip_nonlocal_bind = 1" >>/etc/sysctl.conf    # 允许没VIP时启动
    sysctl -p >/dev/null    # 应用配置
    
    # 创建测试页面
    echo $HOST >/var/www/html/index.html
EOF
done
    

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

# 配置 haproxy 日志
echo <<'EOF' >/etc/rsyslog.d/haproxy.conf
$ModLoad imudp
$UDPServerRun 514
$template Haproxy,"%rawmsg% \n"
local0.=info -/var/log/haproxy.log;Haproxy
local0.notice -/var/log/haproxy-status.log;Haproxy
EOF

# 同步配置到 controller2, controller3
echo "--------- scp haproxy config -> controller2, 3 -----------"
scp /etc/haproxy/haproxy.cfg controller2:/etc/haproxy/haproxy.cfg
scp /etc/haproxy/haproxy.cfg controller3:/etc/haproxy/haproxy.cfg
scp /etc/rsyslog.d/haproxy.conf controller2:/etc/rsyslog.d/haproxy.conf
scp /etc/rsyslog.d/haproxy.conf controller3:/etc/rsyslog.d/haproxy.conf
echo -e '\n\n'

# 启动服务
for HOST in controller1 controller2 controller3; do
    echo "--------------- $HOST ---------------"
    ssh -T  $HOST <<'EOF'
    # 配置服务随系统启动
    systemctl enable httpd  
    systemctl enable haproxy

    # 重启日志服务,启动httpd,haproxy
    systemctl restart rsyslog  
    systemctl start httpd  
    systemctl start haproxy 
    echo -e '\n\n'
EOF
done


echo -e "
----- 浏览器打开以下URL验证 Haproxy节点状态 -----

    http://192.168.0.11:1080/admin 
    http://192.168.0.11:1080/admin 
    http://192.168.0.11:1080/admin

     用户名:密码 / admin:admin

http://10.0.0.10/ 浏览器打开此URL刷新可以看到服务器轮询切换"
