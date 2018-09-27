#!/bin/bash

check() {
     [ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m"
}


# 安装配置 rabbitmq
for HOST in controller1 controller2 controller3; do
    echo "---------- $HOST ----------"
    ssh -T $HOST <<'EOF'
    check() ([ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m")

    # 安装 rabbitmq
    yum -y install rabbitmq-server erlang socat >/dev/null 2>&1; check 'RabbitMQ Install'

    # 启动服务, 跟随系统启动
    systemctl enable rabbitmq-server >/dev/null 2>&1; check 'Enable RabbitMQ'
    systemctl start rabbitmq-server >/dev/null 2>&1; check 'Start RabbitMQ'
    echo -e '\n'

    # 启动web插件
    rabbitmq-plugins enable rabbitmq_management
    echo -e '\n\n'
    echo -e "\033[32m RabbitMQ Service Status \033[0m"
    netstat -antp | egrep '567'
    echo -e '\n\n'

EOF
done

# 同步认证 Cookie
echo '---------- scp erlang.cookie -> controller2,3 ----------'
scp /var/lib/rabbitmq/.erlang.cookie controller2:/var/lib/rabbitmq/
scp /var/lib/rabbitmq/.erlang.cookie controller3:/var/lib/rabbitmq/
echo -e '\n\n'

# 重启服务
for HOST in controller2 controller3; do
    echo "---------- $HOST ----------"
    ssh $HOST <<'EOF'
    check() ([ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m")
    systemctl restart rabbitmq-server >/dev/null 2>&1; check 'Restart Haproxy'
EOF
done

# 使用Disk模式
systemctl stop rabbitmq-server
pkill beam.smp
rabbitmqctl stop
sleep 3
rabbitmq-server -detached 
rabbitmqctl cluster_status


# 加入到节点controller1

for HOST in  controller2 controller3; do
    echo "---------- $HOST RabbitMQ cluster----------"
    ssh -T $HOST <<'EOF'
    check() ([ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m")
    systemctl stop rabbitmq-server >/dev/null 2>&1; check 'Stop RabbitMQ'
    pkill beam.smp
    rabbitmq-server -detached
    rabbitmqctl stop_app
    rabbitmqctl join_cluster rabbit@controller1
    rabbitmqctl start_app
    rabbitmqctl cluster_status
EOF
done

#重置
#rabbitmqctl stop_app
#rabbitmqctl reset


# 集群设置
rabbitmqctl set_policy ha-all "^" '{"ha-mode":"all"}'  # 设置镜像队列
rabbitmqctl set_cluster_name RabbitMQ-Cluster          # 更改群集名称
rabbitmqctl cluster_status                             # 查看群集状态

# 添加用户及密码
rabbitmqctl add_user admin admin
rabbitmqctl set_user_tags admin administrator
rabbitmqctl add_user openstack openstack
rabbitmqctl set_permissions openstack ".*" ".*" ".*"
rabbitmqctl set_user_tags openstack administrator

### Haproxy 配置
if [ -z "$(grep 'RabbitMQ' /etc/haproxy/haproxy.cfg)" ];then
cat <<'EOF' >>/etc/haproxy/haproxy.cfg

########## RabbitMQ ##########
listen RabbitMQ-Server
  bind controller:5673
  mode tcp
  balance roundrobin
  option tcpka
  timeout client 3h
  timeout server 3h
  option clitcpka
  server controller1 controller1:5672 check inter 5s rise 2 fall 3
  server controller2 controller2:5672 check inter 5s rise 2 fall 3
  server controller3 controller3:5672 check inter 5s rise 2 fall 3

listen RabbitMQ-Web
  bind controller:15673
  mode tcp
  balance roundrobin
  option tcpka
  server controller1 controller1:15672 check inter 5s rise 2 fall 3
  server controller2 controller2:15672 check inter 5s rise 2 fall 3
  server controller3 controller3:15672 check inter 5s rise 2 fall 3
EOF
fi

# 同步配置
echo "---------- scp haproxy.cfg -> controller2, 3 ----------"
scp /etc/haproxy/haproxy.cfg controller2:/etc/haproxy/haproxy.cfg
scp /etc/haproxy/haproxy.cfg controller3:/etc/haproxy/haproxy.cfg
echo -e '\n\n'

# 重启服务
for HOST in controller1 controller2 controller3; do
    echo "---------- $HOST ----------"
    ssh $HOST <<EOF
    check() ([ $? -ne 0 ] && echo -e "\033[31m $1 Failed \033[0m" || echo -e "\033[32m $1 Successfully \033[0m")
    systemctl restart haproxy >/dev/null 2>&1; check 'Restart Haproxy'
EOF
done
echo -e '\n\n'

echo "
           浏览器打开 http://192.168.0.11:1080/admin 查看 RabbitMQ-Server,RabbitMQ-Web 状态
           浏览器打开 http://10.0.0.10:15673 查看数据库WebUI 用户名:密码 / admin:admin"
