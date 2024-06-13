#!/bin/bash
source /etc/os-release
RELEASE=$ID
if [ "$RELEASE" == "centos" ]; then
    systemPackage="yum"
else
    systemPackage="apt-get"
fi

function install_trojan() {
    mkdir /usr/local/ssl  >/dev/null 2>&1
    curl https://get.acme.sh | sh >/dev/null 2>&1
    ~/.acme.sh/acme.sh --register-account -m test@$domain >/dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d $domain --standalone
    ~/.acme.sh/acme.sh --install-cert -d $domain \
        --key-file /usr/local/ssl/server.key \
        --fullchain-file /usr/local/ssl/server.crt
    if [ ! -e "/usr/local/ssl/server.crt" ]; then
        echo "ssl 证书获取失败"
        return
    fi
    echo "ssl 证书申请成功"

    echo "正在安装 trojan"
    wget https://github.com/trojan-gfw/trojan/releases/download/v1.16.0/trojan-1.16.0-linux-amd64.tar.xz >/dev/null 2>&1
    tar xf trojan-1.16.0-linux-amd64.tar.xz -C /usr/local/
    rm -f trojan-1.16.0-linux-amd64.tar.xz

    read -p "请设置trojan密码，建议不要出现特殊字符：" trojan_passwd
    sed -e '/password1/,+1d' \
        -e 's/password": \[/&\n        "'${trojan_passwd}'"/' \
        -i.bak /usr/local/trojan/config.json
    sed -e 's|"cert": "/path.*|"cert": "/usr/local/ssl/server.crt",|' \
        -e 's|"key": "/path.*|"key": "/usr/local/ssl/server.key",|' \
        -i /usr/local/trojan/config.json
    cat >/etc/systemd/system/trojan.service <<-EOF
[Unit]
Description=trojan
After=network.target

[Service]
Type=simple
PIDFile=/usr/local/trojan/trojan/trojan.pid
ExecStart=/usr/local/trojan/trojan -c "/usr/local/trojan/config.json"
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=1s

[Install]
WantedBy=multi-user.target
EOF
    chmod +x /etc/systemd/system/trojan.service
    systemctl enable trojan
    systemctl start trojan
    rm -f /etc/nginx/nginx.conf
    cat >/etc/nginx/nginx.conf <<-EOF
user root;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    server {
        listen       80;
        listen       [::]:80;
        server_name  _;
        root         /usr/share/nginx/html;
    }
}
EOF
    systemctl enable nginx
    systemctl start nginx
    echo "trojan 安装成功"
}

function preinstall_check() {
    if [ "$RELEASE" == "centos" ]; then
        if [ "$(systemctl status firewalld | grep "Active: active")" ]; then
            firewall-cmd --zone=public --add-port=80/tcp --permanent >/dev/null 2>&1
            firewall-cmd --zone=public --add-port=443/tcp --permanent >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        fi
    else
        if [ -n "$(systemctl status ufw | grep "Active: active")" ]; then
            ufw allow 80/tcp >/dev/null 2>&1
            ufw allow 443/tcp >/dev/null 2>&1
            ufw reload >/dev/null 2>&1
        fi
        apt-get update >/dev/null 2>&1
    fi

    echo "安装依赖包"
    $systemPackage -y install net-tools socat wget unzip zip curl tar vnstat nginx >/dev/null 2>&1
    systemctl stop nginx >/dev/null 2>&1

    port80=$(netstat -tunlp | grep :80 | awk '{print $7}')
    port443=$(netstat -tunlp | grep :443 | awk '{print $7}')
    if [ "$port80" ] || [ $port443 ]; then
        echo "检测到端口占用"
        echo "80 端口占用程序："$port80
        echo "443 端口占用程序："$port443
        return
    fi

    read -p "请输入已绑定的域名：" domain
    real_addr=$(ping ${domain} -c 1 | sed '1{s/[^(]*(//;s/).*//;q}' >/dev/null 2>&1)
    local_addr=$(curl ipv4.icanhazip.com >/dev/null 2>&1)
    if [ $real_addr == $local_addr ]; then
        echo "解析正常，开始安装trojan"
        install_trojan
    else
        echo "域名解析地址与本机 IP 不一致"
        return
    fi
}

function remove_trojan() {
    systemctl stop trojan
    systemctl disable trojan
    systemctl stop nginx
    systemctl disable nginx
    rm -f /etc/systemd/system/trojan.service
    if [ "$RELEASE" == "centos" ]; then
        yum autoremove -y nginx >/dev/null 2>&1
    else
        apt-get -y autoremove nginx
        apt-get -y --purge remove nginx
        apt-get -y autoremove && apt-get -y autoclean
        find / | grep nginx | sudo xargs rm -rf
    fi
    rm -rf /usr/local/trojan/
    rm -rf /usr/local/ssl/
    rm -rf /usr/share/nginx/
    rm -rf /etc/nginx/
    rm -rf ~/.acme.sh/
    echo '卸载完成'
}

start_menu() {
    echo " 1. 安装trojan"
    echo " 2. 卸载trojan"
    echo
    read -p "请选择 :" num
    case "$num" in
    1)
        preinstall_check
        ;;
    2)
        remove_trojan
        ;;
    *)
        echo "请输错误"
        ;;
    esac
}

start_menu
