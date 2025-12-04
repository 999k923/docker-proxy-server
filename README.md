docker部署hy2或者TUIC 2选1
==

## docker run

```bash
docker run -d \
  --name proxy_server \
  --restart always \
  --network host \
  -e SERVICE_TYPE=1 \
  -e SERVICE_PORT=30000 \
  -e IP_VERSION=6 \
  -v /opt/stacks/proxy_server/data:/proxy_files \
  999k923/docker-proxy:latest
```

## docker-compose
```bash
version: "3.9"
services:
  proxy:
    image: 999k923/docker-proxy:latest
    container_name: proxy_server
    restart: always
    network_mode: host # 保留 host 模式，这样容器直接使用宿主机网络
    environment:
      SERVICE_TYPE: 1 # 1=HY2, 2=TUIC
      SERVICE_PORT: 30000
      IP_VERSION: "6" # ""=留空双栈VPS, "4"=IPv4 only, "6"=IPv6 only
    volumes:
      - /opt/stacks/proxy_server/data:/proxy_files
networks: {}
```
## 如果你想用 Docker 卷而不是宿主机目录
```bash
version: "3.9"
services:
  proxy:
    image: 999k923/docker-proxy:latest
    container_name: proxy_server
    restart: always
    network_mode: host  # 保留 host 模式，这样容器直接使用宿主机网络
    environment:
      SERVICE_TYPE: 1    # 1=HY2, 2=TUIC
      SERVICE_PORT: 30000
      IP_VERSION: "6"    # ""=dual-stack, "4"=IPv4 only, "6"=IPv6 only
    volumes:
      - proxy_data:/proxy_files  # 使用 Docker 卷

volumes:
  proxy_data:
```

### 挂载目录下有一个hy2_link.txt文件，节点信息就在这里面查看。
