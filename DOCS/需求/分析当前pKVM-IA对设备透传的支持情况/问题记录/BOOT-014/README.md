# BOOT-014 辅助脚本

- 推荐矩阵入口：
  - `auto-repro-boot014-t4a-matrix.py`
- 默认计划：
  - `Case A`：`0s / 1s / 3s / 10s` 四个 kill 时机各 `5` 轮，共 `20` 轮
  - `Case B`：默认 `5` 轮
  - `Case C`：默认 `5` 轮
- 直接运行：

```bash
sudo ./DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-014/auto-repro-boot014-t4a-matrix.py matrix
```

- 如需把 `B/C` 也拉回 `10` 轮：

```bash
sudo ./DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-014/auto-repro-boot014-t4a-matrix.py matrix --iterations-b 10 --iterations-c 10
```

- 单独重跑一轮 `Case A`：

```bash
sudo ./DOCS/需求/分析当前pKVM-IA对设备透传的支持情况/问题记录/BOOT-014/auto-repro-boot014-t4a-matrix.py once --case A --kill-delay-secs 3
```
