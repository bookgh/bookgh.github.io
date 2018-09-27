#!/bin/bash

# 配置数据库目录
datadir=/data/mysql    # 数据库数据存储目录
basedir=/usr/local/mysql    # 数据库安装目录

# 添加用户,组
groupadd -g 1200 mysql
useradd -r -g mysql -u 1200 -s /sbin/nologin mysql

# 创建数据库存储目录
mkdir -p $datadir

# 配置YUM源
rm -f /etc/yum.repos.d/*
curl -so /etc/yum.repos.d/epel-7.repo http://mirrors.aliyun.com/repo/epel-7.repo
curl -so /etc/yum.repos.d/Centos-7.repo http://mirrors.aliyun.com/repo/Centos-7.repo
sed -i '/aliyuncs.com/d' /etc/yum.repos.d/Centos-7.repo /etc/yum.repos.d/epel-7.repo

# 安装jemalloc(内存管理器减少内存碎片)
yum install -y jemalloc-devel

# 下载软件,解压
curl -OL http://mirrors.ustc.edu.cn/mysql-ftp/Downloads/MySQL-5.7/mysql-5.7.23-linux-glibc2.12-x86_64.tar.gz --progress
tar xvf mysql-5.7.23-linux-glibc2.12-x86_64.tar.gz
mv mysql-5.7.23-linux-glibc2.12-x86_64/ $basedir

# 配置服务,跟随系统启动
cp $basedir/support-files/mysql.server /etc/init.d/mysqld
sed -i "s@^basedir=.*@basedir=$basedir@" /etc/init.d/mysqld
sed -i "s@^datadir=.*@datadir=$datadir@" /etc/init.d/mysqld
chmod +x /etc/init.d/mysqld
chkconfig --add mysqld
chkconfig mysqld on

# mysql配置文件
cat << EOF >/etc/my.cnf
[client]
port = 3306
socket = /tmp/mysql.sock
default-character-set = utf8mb4

[mysql]
prompt="MySQL [\\d]> "
no-auto-rehash

[mysqld]
skip-ssl
port = 3306
user = mysql
server-id = 1
bind-address = 0.0.0.0
log_timestamps = SYSTEM
socket = /tmp/mysql.sock

basedir = $basedir
datadir = $datadir
character-set-server = utf8mb4
pid-file = $datadir/mysql.pid
init-connect = 'SET NAMES utf8mb4'

back_log = 300
#skip-networking
skip-name-resolve

max_connections = 1000
max_connect_errors = 6000
open_files_limit = 65535
table_open_cache = 128
max_allowed_packet = 500M
binlog_cache_size = 1M
max_heap_table_size = 8M
tmp_table_size = 16M

read_buffer_size = 2M
read_rnd_buffer_size = 8M
sort_buffer_size = 8M
join_buffer_size = 8M
key_buffer_size = 4M

thread_cache_size = 8

query_cache_type = 1
query_cache_size = 8M
query_cache_limit = 2M

ft_min_word_len = 4

log_bin = mysql-bin
binlog_format = mixed
expire_logs_days = 7

slow_query_log = 1
long_query_time = 1
log_error = $datadir/mysql-error.log
slow_query_log_file = $datadir/mysql-slow.log

performance_schema = 0
explicit_defaults_for_timestamp

#lower_case_table_names = 1

skip-external-locking

default_storage_engine = InnoDB
#default-storage-engine = MyISAM
innodb_file_per_table = 1
innodb_open_files = 500
innodb_buffer_pool_size = 64M
innodb_write_io_threads = 4
innodb_read_io_threads = 4
innodb_thread_concurrency = 0
innodb_purge_threads = 1
innodb_flush_log_at_trx_commit = 2
innodb_log_buffer_size = 2M
innodb_log_file_size = 32M
innodb_log_files_in_group = 3
innodb_max_dirty_pages_pct = 90
innodb_lock_wait_timeout = 120

bulk_insert_buffer_size = 8M
myisam_sort_buffer_size = 8M
myisam_max_sort_file_size = 10G
myisam_repair_threads = 1

interactive_timeout = 28800
wait_timeout = 28800

[mysqldump]
quick
max_allowed_packet = 500M

[myisamchk]
key_buffer_size = 8M
sort_buffer_size = 8M
read_buffer = 4M
write_buffer = 4M
EOF

# 数据库配置优化
cp /etc/my.cnf{,.bak}
Mem=`free -m | awk '/Mem:/{print $2}'`
sed -i "s@max_connections.*@max_connections = $((${Mem}/3))@" /etc/my.cnf
if [ ${Mem} -gt 1500 -a ${Mem} -le 2500 ]; then
    #  1500MB < 实际内存 <= 2500MB
    sed -i 's@^thread_cache_size.*@thread_cache_size = 16@' /etc/my.cnf
    sed -i 's@^query_cache_size.*@query_cache_size = 16M@' /etc/my.cnf
    sed -i 's@^myisam_sort_buffer_size.*@myisam_sort_buffer_size = 16M@' /etc/my.cnf
    sed -i 's@^key_buffer_size.*@key_buffer_size = 16M@' /etc/my.cnf
    sed -i 's@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = 128M@' /etc/my.cnf
    sed -i 's@^tmp_table_size.*@tmp_table_size = 32M@' /etc/my.cnf
    sed -i 's@^table_open_cache.*@table_open_cache = 256@' /etc/my.cnf
elif [ ${Mem} -gt 2500 -a ${Mem} -le 3500 ]; then
    #  2500MB < 实际内存 <= 3500MB
    sed -i 's@^thread_cache_size.*@thread_cache_size = 32@' /etc/my.cnf
    sed -i 's@^query_cache_size.*@query_cache_size = 32M@' /etc/my.cnf
    sed -i 's@^myisam_sort_buffer_size.*@myisam_sort_buffer_size = 32M@' /etc/my.cnf
    sed -i 's@^key_buffer_size.*@key_buffer_size = 64M@' /etc/my.cnf
    sed -i 's@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = 512M@' /etc/my.cnf
    sed -i 's@^tmp_table_size.*@tmp_table_size = 64M@' /etc/my.cnf
    sed -i 's@^table_open_cache.*@table_open_cache = 512@' /etc/my.cnf
elif [ ${Mem} -gt 3500 ]; then
    #  3500MB < 实际内存
    sed -i 's@^thread_cache_size.*@thread_cache_size = 64@' /etc/my.cnf
    sed -i 's@^query_cache_size.*@query_cache_size = 64M@' /etc/my.cnf
    sed -i 's@^myisam_sort_buffer_size.*@myisam_sort_buffer_size = 64M@' /etc/my.cnf
    sed -i 's@^key_buffer_size.*@key_buffer_size = 256M@' /etc/my.cnf
    sed -i 's@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = 1024M@' /etc/my.cnf
    sed -i 's@^tmp_table_size.*@tmp_table_size = 128M@' /etc/my.cnf
    sed -i 's@^table_open_cache.*@table_open_cache = 1024@' /etc/my.cnf
fi

# 初始化数据库
sed -i 's@executing mysqld_safe@executing mysqld_safe\nexport LD_PRELOAD=/usr/lib64/libjemalloc.so@' $basedir/bin/mysqld_safe
$basedir/bin/mysqld --initialize-insecure --user=mysql --basedir=$basedir --datadir=$datadir
chmod 600 /etc/my.cnf
chown mysql.mysql -R $datadir
systemctl start mysqld

# 添加环境变量
echo "export PATH=$basedir/bin:\$PATH" >> /etc/profile
. /etc/profile

# 初始化root密码, 权限
dbrootpwd=hc123456    # 数据库root密码
mysql -e "grant all privileges on *.* to root@'127.0.0.1' identified by \"${dbrootpwd}\" with grant option;"
mysql -e "grant all privileges on *.* to root@'localhost' identified by \"${dbrootpwd}\" with grant option;"
mysql -uroot -p${dbrootpwd} -e "reset master;"

# 配置mysql库文件
rm -rf /etc/ld.so.conf.d/mariadb-x86_64.conf
echo "$basedir/lib" > /etc/ld.so.conf.d/mysql.conf
ldconfig
systemctl restart mysqld

# 配置防火墙
firewall-cmd --zone=public --add-port=3306/tcp --permanent    # 永久生效允许 3306 端口
firewall-cmd --reload    # 重新载入防火墙配置
firewall-cmd --zone=public --query-port=3306/tcp    # 查看 3306 端口是否允许
firewall-cmd --zone=public --list-ports    # 查看所有允许端口

# 关闭selinux
setenforce 0    # 临时生效，重启失效
sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config    # 重启后生效

cat <<EOF


    mysql 已经安装完成
    数据库root密码：$dbrootpwd
    数据库安装路径：$basedir
    数据库数据路径：$datadir

    默认root用户只允许本机登陆mysql如需远程登陆请执行：
        source /etc/profile
        mysql -uroot -p${dbrootpwd} -e "grant all privileges on *.* to root@'%' identified by \"${dbrootpwd}\" with grant option;"
        mysql -uroot -p${dbrootpwd} -e "SELECT DISTINCT CONCAT('User: ''',user,'''@''',host,''';') AS query FROM mysql.user;"
EOF
