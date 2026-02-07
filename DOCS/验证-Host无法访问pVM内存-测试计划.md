# 验证计划：Host 不能直接读到 pVM 明文内存（crosvm 版，简单步骤）

你要做的事只有一句话：
**在 Guest 里把一个“Host 已知的 secret”写进大量内存，然后在 Host 上用 gdb 去 crosvm 进程的 `/memfd:crosvm_guest` 映射里搜索这个 secret。**

对照结果：
- 普通 VM：能搜到（说明 Host/VMM 可直接读到 guest RAM 明文）
- pVM：搜不到（说明 Host/VMM 读不到 pVM 明文 RAM）

> 为什么不用 `gcore`：crosvm 的 mmap 会 `MADV_DONTDUMP`，core dump 常常不包含 guest RAM，所以普通 VM 也会“搜不到”。这里统一用 gdb 直接读进程内存。

---

## 0) 你需要两个窗口

- 窗口 A：Guest 终端（Ubuntu guest 里执行 Python）
- 窗口 B：Host 终端（Ubuntu host 上执行 ps/rg/gdb）

---

## 1) 选一个 nonce（你手工指定，Host/Guest 都要用同一个）

例子（你可以换成别的）：

```text
NONCE=2026-02-06-01
```

---

## 2) Guest（窗口 A）：运行“占内存但不泄露 secret”的脚本

把 `NONCE=...` 替换成你选的值：

```bash
NONCE="2026-02-06-01" python3 - <<'PY'
import hashlib, os, sys, time

nonce = os.environ["NONCE"].encode()
secret = hashlib.sha256(b"PKVMTEST:" + nonce).hexdigest().encode()  # 64 hex bytes

sz = 256 * 1024 * 1024  # 256MB（想更稳就调大，但别把 guest 撑爆）
buf = bytearray(sz)
pat = secret + b"|"
for i in range(0, len(buf), len(pat)):
    buf[i:i+len(pat)] = pat[:min(len(pat), len(buf)-i)]

print("READY (secret is NOT printed). Now run host-side gdb find, then press Enter here.", file=sys.stderr, flush=True)
open("/dev/tty","r").readline()
print("DONE", flush=True)
time.sleep(1)
PY
```

看到 `READY...` 后，**先别按回车**。

---

## 3) Host（窗口 B）：找到 crosvm PID

```bash
ps -ef | rg -n "crosvm.*run" | head
```

把你要测试的那一条 PID 记下来（通常是 parent 那个）。

为了减少“选错进程”的概率，你也可以用 RSS 最大的那个：

```bash
PID="<替换成 parent pid>"
ps -o pid,ppid,rss,cmd -p "$PID" $(pgrep -P "$PID" 2>/dev/null) --sort=-rss | head
```

---

## 4) Host：确认 guest RAM 的映射区间（关键）

```bash
PID="<替换成 crosvm pid>"
sudo rg -n "memfd:crosvm_guest" /proc/"$PID"/maps
```

你会看到类似几行：

```text
70fe2b660000-70fe5b660000 rw-s ... /memfd:crosvm_guest (deleted)
...
```

挑一段“最大的那段”（通常几百 MB 或几 GB），记下它的 `START-END`。

---

## 5) Host：计算 secret（Host 端可直接算出来，不需要 Guest 打印）

把 `NONCE` 替换成你第 1 步选的值：

```bash
NONCE="2026-02-06-01"
SECRET="$(python3 - <<PY
import hashlib
print(hashlib.sha256(b"PKVMTEST:" + b"$NONCE").hexdigest())
PY
)"
echo "$SECRET"
```

---

## 6) Host：gdb 在 guest RAM 映射里搜索 secret

把 `PID/START/END` 替换成你的值：

```bash
PID="<crosvm pid>"
START="0x<start>"
END="0x<end>"

sudo gdb -q -p "$PID" \
  -ex "set pagination off" \
  -ex "find $START, $END, \\\"$SECRET\\\"" \
  -ex "detach" -ex "quit"
```

判读：
- 输出里有地址（例如 `0x70fe...` / `N patterns found.`）=> **能搜到**
- 输出 `Pattern not found.` => **搜不到**

---

## 7) 现在可以回到 Guest（窗口 A）按回车结束脚本

这一步只是清理流程，不影响结论。

---

## 8) 做对照：普通 VM vs pVM

你要跑两次（步骤 2~7 完全一样）：

1) 普通 VM（不带 `--protected-vm*`）
   - 预期：第 6 步 **能搜到**
2) pVM（带 `--protected-vm-without-firmware` 或你的 protected 参数）
   - 预期：第 6 步 **搜不到**

---

## 9) 最小记录模板（你把结果贴回给我就行）

```text
Baseline(普通 VM):
- PID:
- memfd:crosvm_guest 映射(START-END):
- SECRET:
- gdb find 结果: found / not found (found 地址或 "Pattern not found.")

pVM:
- PID:
- memfd:crosvm_guest 映射(START-END):
- SECRET(同一个 NONCE 算出来的):
- gdb find 结果: found / not found
```

