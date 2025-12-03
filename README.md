## docker部署docker-compose
```bash
services:
  proxy:
    image: 999k923/docker-proxy:latest
    container_name: proxy_server
    restart: always
    network_mode: host        # host 网络模式保证 UDP/IPv6 正常
    environment:
      SERVICE_TYPE: 1         # 1=hy2, 2=tuic
    volumes:
      - /opt/stacks/proxy_server/data:/proxy_files
```
## 如果你想用 Docker 卷而不是宿主机目录
```bash
volumes:
  proxy_data:
    driver: local

services:
  proxy:
    image: 999k923/docker-proxy:latest
    container_name: proxy_server
    restart: always
    network_mode: host
    environment:
      SERVICE_TYPE: 1
    volumes:
      - proxy_data:/proxy_files

volumes:
  proxy_data:
```

### 挂载目录下有一个hy2_link.txt文件，节点信息就在这里面查看。

```bash
version: "3.9"
services:
  proxy:
    build: .
    container_name: proxy_server
    restart: always
    environment:
      SERVICE_TYPE: 3  # 1=hy2, 2=tuic, 3=argo
      ARGO_TOKEN: ""   # 运行 Argo 时填写
      ARGO_DOMAIN: ""  # 运行 Argo 时填写
      ARGO_PORT: 28888
    ports:
      - "28888:28888/udp"
      - "28888:28888/tcp"
    volumes:
      - /opt/stacks/proxy_server/proxy_files/:/proxy_files
```
