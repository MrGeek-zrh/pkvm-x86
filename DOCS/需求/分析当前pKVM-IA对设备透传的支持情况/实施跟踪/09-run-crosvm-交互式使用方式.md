# run-crosvm.sh 的交互式使用方式

## 目的

- 固化一个可复用的小技巧：直接用 `scripts/run-crosvm.sh` 启动 crosvm，并在当前终端里直接和 guest 串口交互。
- 适用于需要“guest 内发命令 + host 侧同步观察/控制”的场景，尤其是 T4A 这类 teardown 验证。

## 结论

- 当前 `scripts/run-crosvm.sh` 已经把 guest console 绑到了当前终端的 `stdin/stdout`，因此不需要额外串口代理，也不需要先写脚本，手工就能完成：
  - 启动 VM
  - 登录 guest
  - 向 guest 发送命令
  - 观察 guest 输出
- 当前镜像的登录用户名是 `ubuntu`。
- 对需要 host/guest 联动的 case，推荐固定成“两终端工作法”：
  - 终端 A：跑 `scripts/run-crosvm.sh`，负责 guest 交互
  - 终端 B：负责 host 侧 `pgrep`、`kill`、`dmesg`、驱动恢复等动作

## 前提

- `scripts/run-crosvm.sh` 当前使用的是：

```sh
--serial "type=stdout,hardware=virtio-console,console,stdin"
```

- 这意味着 guest 串口会直接接到你当前运行脚本的那个终端。
- 因此前面 `Case A/B/C` 能被脚本化，本质上不是额外做了什么特殊串口接线，而只是把“向当前串口终端输入命令”这件事自动化了。

## 最小用法

先在 host 终端 A 启动 VM：

```sh
sudo -n env PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

看到 `localhost login:` 后，直接在当前终端输入：

```text
ubuntu
```

登录后就可以继续直接输入 guest 命令，例如：

```sh
uname -a
lsblk
readlink -f /sys/block/nvme0n1/device
```

如果希望后续观察输出更稳、也更方便做自动化匹配，可以先把提示符改成固定值：

```sh
export PS1='PROMPT# '
```

## 常见交互模式

### 模式 1：单终端做 guest 内验证

- 适合确认 guest 是否起来、透传设备是否枚举、单次 I/O 是否成功。

示例：

```sh
ls -l /dev/nvme0n1
printf '\n' | sudo -S sh -c 'dd if=/dev/nvme0n1 of=/dev/null bs=4M count=8 iflag=direct status=none; echo DD_RC=$?'
```

### 模式 2：终端 A 跑 guest，终端 B 做 host 控制

- 适合 teardown、异常注入、强杀 VMM、同步抓 `dmesg` 这类场景。
- 终端 A 保持在 guest 串口，不要切走。
- 终端 B 单独执行 host 命令，例如：

```sh
pgrep -a crosvm
sudo -n dmesg -T | tail -n 50
sudo -n kill -9 <crosvm-pid>
```

## 实际例子：T4A 的 Case A

这个例子对应“活跃 DMA + host 强制销毁”。

### 终端 A：启动 VM 并在 guest 内挂起持续 DMA

先启动：

```sh
sudo -n env -u DEBUG PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
```

登录并准备环境：

```text
ubuntu
```

```sh
export PS1='PROMPT# '
ls -l /dev/nvme0n1 && echo READY_NVME
```

然后在 guest 内启动持续 direct I/O：

```sh
printf '\n' | sudo -S sh -c 'while :; do dd if=/dev/nvme0n1 of=/dev/null bs=4M count=256 iflag=direct status=none; done >/tmp/t4-dd-loop.log 2>&1 & echo T4_BG=$!'
```

- 如果看到 `T4_BG=<pid>`，就说明 guest 内的后台 DMA 循环已经挂起来了。

### 终端 B：host 侧做强杀和观测

先找到 `crosvm` 进程：

```sh
pgrep -a crosvm
```

然后直接强杀：

```sh
sudo -n kill -9 <crosvm-pid>
```

随后抓 host 侧日志：

```sh
sudo -n dmesg -T | tail -n 80
```

如果想只看这轮新增日志，可以在启动前先记一个时间点，再用：

```sh
date -u '+%F %T'
sudo -n dmesg -T --since '<上一步时间戳>'
```

### 观察点

- 终端 A 这时通常会因为 `crosvm` 被杀而直接 EOF/退出。
- 终端 B 重点看 host `dmesg` 是否出现新的：
  - `DMAR`
  - `IOMMU`
  - `pkvm: exception`
  - `soft lockup`
  - `stall`

## 另外两个直接可复用的例子

### Case B：小流量 I/O 后 guest 直接 `poweroff -f`

```sh
printf '\n' | sudo -S sh -c 'dd if=/dev/nvme0n1 of=/dev/null bs=4M count=8 iflag=direct status=none && echo SMALL_IO_DONE'
printf '\n' | sudo -S poweroff -f
```

### Case C：活跃 DMA 时 guest 直接 `poweroff -f`

```sh
printf '\n' | sudo -S sh -c 'while :; do dd if=/dev/nvme0n1 of=/dev/null bs=4M count=256 iflag=direct status=none; done >/tmp/t4-dd-loop.log 2>&1 & echo T4_BG=$!'
printf '\n' | sudo -S poweroff -f
```

## 适用场景

- 快速确认 protected pVM 是否已启动到 `login:`
- 快速确认 guest 是否已看到透传盘，例如 `/dev/nvme0n1`
- 在 guest 内跑短 I/O、持续 I/O、`poweroff -f`
- 在 host 侧同步做 `kill -9 crosvm`、抓 `dmesg`、抓进程状态
- 后续若要写自动化，通常也只是把同样一组串口输入步骤自动化掉

## 注意事项

- `scripts/run-crosvm.sh` 占用的是当前终端，所以 host 侧控制动作最好放到第二个终端或 `tmux` 分屏。
- 这里的命令示例默认沿用当前镜像的实际使用习惯：guest 登录用户为 `ubuntu`，示例中的 `sudo` 写法也按当前镜像验证记录整理。
- `kill -9 crosvm` 只适合 teardown 风险验证，不适合作为日常退出方式。
- 若强杀后需要把透传设备恢复给 host 驱动，应按对应问题记录/验证文档里的恢复步骤执行，不要把“交互式使用方式”与“设备恢复流程”混在一起。

## 相关文档

- teardown 验证样例：`04A-P0-teardown-DMA生命周期风险验证与触发样例.md`
- 当前 T4 主任务：`04-P0-VM销毁前quiesce-ptdev-DMA.md`
- 单次正例问题记录：`../问题记录/BOOT-014/BOOT-014-protected-pVM-活跃DMA时host强杀crosvm后单次出现DMAR-NO_PASID-fault.md`
