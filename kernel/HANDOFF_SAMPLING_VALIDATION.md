# EECBS gem5 采样验证 — 交接文档

> **2026-10-02** · 交接内容：验证 11 张地图的 kernel trace 采样代表性，调整不合格的采样参数

## 1. 背景（你需要知道的最少信息）

我们在做 EECBS（一个多 agent 路径规划求解器）的**体系结构层面优化研究**：用 gem5 模拟器测试不同分支预测器 / cache 配置对性能的影响。

EECBS 98% 的运行时间花在低层 A* 搜索函数 `SpaceTimeAStar::findSuboptimalPath` 上。我们的方法是：

1. **录制**：在真机上跑一次完整的 EECBS，用 `-DKERNEL_TRACE` 编译钩子把每次低层搜索调用的输入参数记录到 trace 文件
2. **采样**：从全量 trace 中按大小均匀抽样（`--by-size --every 32`），得到一个保持原始时间顺序的子集
3. **验证（你的任务）**：在真机上回放采样 trace，用 `perf` 对比硬件计数器（CPI / 分支误预测率 / MPKI），确认采样子集能代表全量
4. 验证通过后，把采样 trace 喂给 gem5 做架构参数 sweep

第 1、2 步已完成（11 张地图）。**你只需要做第 3 步。**

## 2. 环境

| 项目 | 详情 |
|---|---|
| Linux 机器 | hostname `viplab-gem5`，Fedora Linux 43，Intel Raptor Lake-DT（P+E 混合核） |
| 仓库路径 | `~/EECBS Workload/EECBS`（路径带空格，命令行要用引号） |
| Native kernel 二进制 | `kernel/build/lowlevel_kernel`（如果不存在见下方编译命令） |
| Trace 文件目录 | `kernel/traces/` |
| 验证脚本 | `kernel/sample_perf.py`（调用 `strata_perf.py`） |
| 批量验证脚本 | `kernel/validate_all_samples.sh` |
| perf 权限 | 需要 `sudo sysctl -w kernel.perf_event_paranoid=0` |

> **注意混合核 CPU**：这台机器是 P-core + E-core 架构。`sample_perf.py` 默认用 `taskset -c 2` 绑定到 CPU 2（P-core），perf 事件默认用 `cpu_core/` 前缀。如果 CPU 编号有变，用 `--cpu` 参数调整。

## 3. 要验证的 11 张地图

| 别名 | 地图文件 | 实验组 | 总调用 | ROI 调用 | 缩放 | 备注 |
|---|---|---|---|---|---|---|
| maze2 | maze-32-32-2.map | Cache | 1760 | 53 | 31× | 已验证过，CPI +3.3%，作为基准参考 |
| random | random-32-32-20.map | **BP sweep** | 5620 | 174 | 31× | |
| warehouse | warehouse-10-20-10-2-1.map | **BP sweep** | 770 | 22 | 39× | 调用偏少 |
| empty | empty-32-32.map | **BP sweep** | 3649 | 112 | 33× | |
| room32 | room-32-32-4.map | **BP sweep** | 13941 | 434 | 32× | |
| den312d | den312d.map | **BP sweep** | 12928 | 402 | 32× | |
| maze4 | maze-32-32-4.map | **BP sweep** | 1698 | 51 | 35× | |
| room64 | room-64-64-8.map | **BP sweep** | 5341 | 165 | 34× | |
| brc202d | brc202d.map | Cache | 408 | 11 | 39× | **样本少**，可能需降低 every |
| berlin | Berlin_1_256.map | 对照组 | 225 | 5 | 62× | **样本很少**，可能需降低 every |
| boston | Boston_0_256.map | 对照组 | 236 | 6 | 89× | **样本很少**，可能需降低 every |
| paris | Paris_1_256.map | 对照组 | 241 | 6 | 34× | **样本很少**，可能需降低 every |

> **已放弃：maze-128-128-2** — 4 分钟全耗在 WDG 启发式计算（CBS 2-agent 子问题）上，`ECBS::findPathForSingleAgent` 从未被调用，trace 文件无法生成。该地图的极端内存瓶颈（CPI 7.79）来自 WDG，不是 A* 主搜索。

## 4. 验证步骤

### 4.1 准备工作

```bash
cd ~/EECBS\ Workload/EECBS
git pull

# 确认 native kernel 已编译
ls kernel/build/lowlevel_kernel

# 如果不存在，编译（不需要 gem5，不需要 static）
cd kernel && mkdir -p build && cd build && cmake .. && make -j8 && cd ../..

# 确保 perf 可用
sudo sysctl -w kernel.perf_event_paranoid=0
perf stat ls > /dev/null  # 应该没有报错
```

### 4.2 跑验证

```bash
bash kernel/validate_all_samples.sh 2>&1 | tee kernel/traces/validation.log
```

每张图会输出类似这样的对比（以 maze-32-32-2 为参考）：

```
==========================================
[maze2] full=m2_full.trace  sample=bs32_o7.trace
==========================================
                                      CPI    miss%     MPKI   instr (measured)
full replay                          0.605    2.41     5.28   5.2e+10
bs32_o7.trace                        0.625    2.42     5.35   1.63e+09   (CPI +3.3%, miss rate +0.5%, MPKI +1.3%)
```

**耗时估算**：每张图跑 3 轮 perf（`--reps 3`）。小图（empty/maze4）秒级，大图（den312d/room32）可能需要几分钟回放全量 trace。总计大约 30-60 分钟。

### 4.3 判定标准

| 指标 | 达标 | 需要调整 |
|---|---|---|
| CPI 误差 | < 10% | ≥ 10% |
| 分支误预测率误差 | < 2 个百分点 | ≥ 2pp |
| MPKI 误差 | < 15% | ≥ 15% |

这个标准来自 maze-32-32-2 的已验证结果（CPI +3.3%，miss rate +0.5%）。BP sweep 和 cache sweep 的地图要求更严格一些；对照组（city maps）因为本身就是负结果验证，可以放宽到 CPI < 15%。

## 5. 如果某张图不达标

最可能的原因是**样本太少**（尤其 brc202d 只有 11 个 ROI 调用，city maps 只有 5-6 个）。解决办法：降低采样间隔，重新生成 sample trace。

```bash
# 例如 berlin：总调用 225，by-size-32 只采到 5 个 ROI 调用
# 降到 every 8，可以采到 ~26 个 ROI 调用
python3 kernel/select_trace.py kernel/traces/berlin_full.trace \
  kernel/traces/berlin_bs8_o3.trace \
  --every 8 --offset 3 --by-size --warm 2

# 重新验证这个新 sample
python3 kernel/sample_perf.py --bin kernel/build/lowlevel_kernel \
  --map Berlin_1_256.map --scen Berlin_1_256-random-1.scen \
  --full-trace kernel/traces/berlin_full.trace \
  --warm 2 kernel/traces/berlin_bs8_o3.trace
```

`--every` 参数的选择逻辑：

- `--every 32`（当前）：总调用的 ~3%，适合 >1000 次调用的图
- `--every 16`：~6%，适合 400-1000 次调用的图
- `--every 8`：~12%，适合 <400 次调用的图
- 注意 `--warm 2` 要保持一致（前 2 个调用做 warmup 不计入测量）

> **关键约束**：采样越密，gem5 跑的时间越长。ROI 调用数 × 平均扩展节点数 ≈ 总模拟指令数，按 ~250 KIPS（gem5 O3 吞吐率）折算模拟时长。目标是**每张图的 gem5 单次跑在 2-4 小时以内**（可并行跑多张图）。

## 6. 采样方法说明（`--by-size --every K`）

这个方法的核心思路：

1. 把全部调用按扩展节点数（搜索规模）排序
2. 每 K 个取 1 个（系统采样），保证大小调用的比例代表性
3. 取出后**恢复原始时间顺序**回放，保留大小调用交错对 cache / 预测器的影响
4. 前 `--warm` 个调用做 warmup（热身 cache/预测器状态），后面的做测量

`--offset` 决定从排序后的第几个元素开始取（避免总是取到边界值）。当前统一用 `--offset 7`，如果需要调整 `--every`，`--offset` 可以按 `every // 4` 来设。

## 7. 文件清单

`kernel/traces/` 目录下，每张图有两个文件：

| 文件 | 内容 | 大小量级 |
|---|---|---|
| `{alias}_full.trace` | 全量 trace（全部低层调用的输入参数） | 几 MB ~ 几百 MB |
| `{alias}_bs32_o7.trace` | by-size-32 采样（ROI + warmup 调用） | 几十 KB ~ 几 MB |

特殊情况：maze-32-32-2 的全量 trace 叫 `m2_full.trace`，采样叫 `bs32_o7.trace`（没有 alias 前缀，历史原因）。

## 8. 验证通过后的下一步

不需要你做，但提供背景信息：

1. **确定最终的采样 trace 文件名和参数**（如果调整过 `--every`）
2. **gem5 分支预测器 sweep**：用同一个 trace，只换 `--bp-type`（LocalBP / TournamentBP / BiModeBP / GshareBP 等）
3. gem5 跑在服务器上（学长会开），用 `kernel/run_gem5.py` 脚本

验证结果请发回来（`validation.log` 和调整过的 trace 文件名/参数），我们会接着做 gem5 sweep。

## 9. 关键脚本参考

### `kernel/sample_perf.py` — 单张图验证

```bash
python3 kernel/sample_perf.py \
  --bin kernel/build/lowlevel_kernel \
  --map <MAP> --scen <SCEN> \
  --full-trace kernel/traces/<alias>_full.trace \
  --warm 2 \
  kernel/traces/<alias>_bs32_o7.trace
```

### `kernel/select_trace.py` — 重新生成采样

```bash
# 查看分布
python3 kernel/select_trace.py kernel/traces/<alias>_full.trace --stats-only

# 生成新采样
python3 kernel/select_trace.py kernel/traces/<alias>_full.trace \
  kernel/traces/<alias>_bs<K>_o<OFF>.trace \
  --every <K> --offset <OFF> --by-size --warm 2
```

### `kernel/validate_all_samples.sh` — 批量验证（一键跑）

```bash
bash kernel/validate_all_samples.sh 2>&1 | tee kernel/traces/validation.log
```

注意：如果调整了某张图的采样参数（比如从 bs32 改成 bs8），需要相应修改这个脚本里的 sample 文件名，或者直接用 `sample_perf.py` 单独验证。
