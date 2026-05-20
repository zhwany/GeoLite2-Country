# ================= 阶段 1: 编译阶段 =================
FROM nginx:alpine AS builder

RUN apk add --no-cache \
        git \
        gcc \
        libc-dev \
        make \
        openssl-dev \
        pcre2-dev \
        zlib-dev \
        linux-headers \
        libtool \
        automake \
        autoconf \
        libmaxminddb-dev

# 1. 下载 ngx_http_geoip2_module 源码
RUN git clone https://github.com/leev/ngx_http_geoip2_module.git /opt/ngx_http_geoip2_module

# 2. 下载当前 Nginx 镜像对应版本的官方源码
RUN NGINX_VERSION=$(nginx -v 2>&1 | cut -d '/' -f 2) && \
    wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz -O nginx.tar.gz && \
    tar -zxf nginx.tar.gz && \
    mv nginx-${NGINX_VERSION} /opt/nginx

# 3. 使用官方 --with-compat 二进制兼容模式安全编译动态模块
RUN cd /opt/nginx && \
    ./configure --with-compat --add-dynamic-module=/opt/ngx_http_geoip2_module && \
    make modules


# ================= 阶段 2: 最终运行镜像 =================
FROM nginx:alpine

# 运行环境安装必备的 libmaxminddb 运行库
RUN apk add --no-cache libmaxminddb wget

# 从编译阶段把编译好的动态模块 (.so) 复制过来
COPY --from=builder /opt/nginx/objs/ngx_http_geoip2_module.so /usr/local/nginx/modules/

# 自动创建 geoip2 目录并将您的 mmdb 数据库文件复制进去（走 raw 裸数据通道）
RUN mkdir -p /etc/nginx/geoip2 && \
    wget https://github.com/zhwany/GeoLite2-Country/raw/refs/heads/main/GeoLite2-Country.mmdb -O /etc/nginx/geoip2/GeoLite2-Country.mmdb

# ================= 自动化脚本：动态修改官方配置（完美缩进版） =================
# 1) 插入动态模块与注释默认日志（第一步）
RUN set -x && \
    sed -i '1i load_module /usr/local/nginx/modules/ngx_http_geoip2_module.so;\n' /etc/nginx/nginx.conf && \
    sed -i -E 's|access_log[[:space:]]+/var/log/nginx/access.log[[:space:]]+main;|# access_log /var/log/nginx/access.log main;|g' /etc/nginx/nginx.conf

# 2) 性能调优：自动解开官方默认配置中的 tcp_nopush 和 gzip 压缩限制（提升网络 I/O 效率与响应速度）
RUN set -x && \
    sed -i 's/#tcp_nopush/tcp_nopush/g' /etc/nginx/nginx.conf && \
    sed -i 's/#gzip  on;/gzip  on;/g' /etc/nginx/nginx.conf

# 3) 【硬核注入】完美缩进的 http 核心块
RUN sed -i '/http {/r /dev/stdin' /etc/nginx/nginx.conf << 'EOF'
    set_real_ip_from  0.0.0.0/0;
    real_ip_header     X-Forwarded-For;
    real_ip_recursive  on;

    geoip2 /etc/nginx/geoip2/GeoLite2-Country.mmdb {
        $geoip2_data_country_code country iso_code;
    }

    map $geoip2_data_country_code $allowed_country {
        default no;
        ""      yes;
        CN      yes;
        HK      yes;
        MO      yes;
        TW      yes;
    }

    log_format main_enhanced "$remote_addr - $remote_user [$time_local] \"$request\" "
                             "$status $body_bytes_sent \"$http_referer\" "
                             "\"$http_user_agent\" \"$http_x_forwarded_for\" "
                             "Country: $geoip2_data_country_code Allowed: $allowed_country";

    access_log /var/log/nginx/access.log main_enhanced;
EOF

# 4) 生成精美的 403 HTML 阻断页面
RUN mkdir -p /usr/share/nginx/html && \
cat << 'EOF' > /usr/share/nginx/html/403_blocked.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>403 Forbidden - Access Denied</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f5f7fa; color: #333; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .container { text-align: center; background: white; padding: 40px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.05); max-width: 500px; width: 90%; }
        .icon { font-size: 64px; color: #e02424; margin-bottom: 20px; }
        h1 { font-size: 24px; margin: 0 0 12px 0; color: #111827; }
        p { font-size: 15px; color: #6b7280; line-height: 1.6; margin: 0 0 24px 0; }
        .footer { font-size: 12px; color: #9ca3af; border-top: 1px solid #e5e7eb; padding-top: 16px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="icon">🚫</div>
        <h1>Access Denied / 访问被拒绝</h1>
        <p>抱歉，由于安全策略限制，系统检测到您的 IP 属地不属于服务开放区域，已被拒绝连接。<br>Your IP region is not allowed to access this service.</p>
        <div class="footer">Security Powered by Cloud Gateway</div>
    </div>
</body>
</html>
EOF

# 5) 精准注入虚拟主机默认站点的 HTML 重定向拦截规则，并安全配置 403 页面放行防死循环
RUN sed -i '/location \/ {/a \
        if ($allowed_country = no) {\n\
            rewrite ^(.*)$ /403_blocked.html break;\n\
        }' /etc/nginx/conf.d/default.conf && \
    sed -i '/location \/ {/i \
    error_page 403 /403_blocked.html;\n\
    location = /403_blocked.html {\n\
        root /usr/share/nginx/html;\n\
        allow all;\n\
    }\n' /etc/nginx/conf.d/default.conf

EXPOSE 80 443