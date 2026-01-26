# Docker 数据盘挂载需求

## 需求描述

将 NVMe 磁盘分区（如 `nvme0n1p4`）配置为 Docker 的数据存储盘。

### 挂载配置

- **挂载点**：`/mnt/data`
- **Docker 数据目录**：`/mnt/data/docker-data`（作为 `/mnt/data` 的子目录）

### 配置要求

1. **磁盘分区格式化**
   - 将目标分区格式化为 ext4 文件系统

2. **挂载配置**
   - 将分区挂载到 `/mnt/data`
   - 在 `/mnt/data` 下创建 `docker-data` 子目录
   - 配置 `/etc/fstab` 实现开机自动挂载（使用 UUID 方式）

3. **Docker 配置**
   - 配置 Docker daemon 使用 `/mnt/data/docker-data` 作为数据根目录
   - 需要修改 `/etc/docker/daemon.json` 配置文件

### 注意事项

- 挂载点是 `/mnt/data`，而不是 `/mnt/data/docker-data`
- `docker-data` 是挂载点下的子目录，用于存放 Docker 的数据
- 使用 UUID 方式配置 fstab，避免设备名称变化导致的问题
