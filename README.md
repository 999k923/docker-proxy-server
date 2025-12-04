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
  -v /opt/stacks/proxy_server/data:/proxy_files \
  999k923/docker-proxy:latest
```

## docker-compose
```bash
services:
  proxy:
    image: 999k923/docker-proxy:latest
    container_name: proxy_server
    restart: always
    network_mode: host
    environment:
      SERVICE_TYPE: 1
      SERVICE_PORT: 30000
    volumes:
      - /opt/stacks/proxy_server/data:/proxy_files
```
## 如果你想用 Docker 卷而不是宿主机目录
```bash
version: "3.9"

services:
  proxy:
    image: 999k923/docker-proxy:latest
    container_name: proxy_server
    restart: always
    network_mode: host
    environment:
      SERVICE_TYPE: 1
      SERVICE_PORT: 30000
    volumes:
      - proxy_data:/proxy_files

volumes:
  proxy_data:
```

### 挂载目录下有一个hy2_link.txt文件，节点信息就在这里面查看。
