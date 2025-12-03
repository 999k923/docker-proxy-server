# 基础镜像
FROM ubuntu:22.04

# 安装必要依赖
RUN apt-get update && \
    apt-get install -y curl openssl wget ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# 创建工作目录
WORKDIR /proxy_files

# 复制启动脚本
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# 构建参数
ARG SERVICE_TYPE=1
ENV SERVICE_TYPE=${SERVICE_TYPE}

# 暴露端口（固定 28888）
EXPOSE 28888/udp
EXPOSE 28888/tcp

# 容器入口
ENTRYPOINT ["/docker-entrypoint.sh"]
