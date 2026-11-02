# 单BAT建工程验证
日期：2026-11-01。范围：独立RF/HIL开源候选。状态：HOST TESTED。

## 使用
安装Vivado 2023.1和对应器件支持，将整个仓库解压到短英文无空格路径，例如E:\DOA，双击根create_project.bat。
无需Python、Pillow或手工添加源文件。此入口只创建工程及必要IP输出。
生成发送端transmitter/vivado/transmitter.xpr、接收端receiver/vivado/receiver.xpr。

## 实际验证
- 原生BAT从不同调用目录运行，收发端工程创建成功，完整结束标记CREATE_PROJECTS_OK存在。
- 单独Vivado会话重新打开两个XPR，核对器件、顶层、显式源集、8个测试平台、IP锁定状态、约束使能及原有Hook。
- 综合和实现所有run均为Not started；本轮没有启动综合/实现、BIT、BOOT或板卡测试。
- 重复执行保留两个XPR，前后SHA一致；工具不存在、中文路径、源清单SHA漂移均被明确阻断。
- 193份候选复制源及267份受保护原始输入重新计算SHA均一致。RTL/BD/XDC/PS/Profile未改。

## 配置一致性与工具行为
PLL仅在生成副本调整gen_directory；其他JSON参数完全一致。
原始BD字节不变。Vivado对生成BD副本补充xci_path、inst_hier_path并更新部分xci_name；
仅排除这三类工具生成位置/名称字段后，完整BD结构、连接及参数一致。没有改变IP或时序约束。
原disabled CDC约束继续disabled，guard保持implementation-only/LATE及opt_design PRE；
发送端原synth_1后处理Hook保留。

## 校验与进程边界
BAT先使用Windows自带PowerShell/.NET对202项输入做SHA256核验，记录INPUTS_VERIFIED.txt；
Vivado会话不再逐文件启动certutil进程，专门负责创建工程；收发端使用各自独立Vivado进程，避免切换器件时共享会话状态。
PowerShell执行策略仅对这一次子进程指定，不修改系统或用户的全局设置。
前期出现过Vivado标准通道及内部axi_noc规则文件读取异常；原始失败日志在仓库外维护目录保留。
未通过单因素实验确认其底层原因，不将其描述成已确认的RTL或工具根因。

## 真实限制
中文及空格路径未通过完整PS IP生成，错误原始证据保留在仓库外maintenance/bat_entry_20261101。
入口明确提前拒绝此类路径，不宣称工具支持。不要单独移动XPR；在最终源码位置运行BAT。
部分厂商生成警告及Hook归档提示仍存在，分类见RESULT_SUMMARY.json，未通过降级或忽略隐藏。
Hook文件已在本源码包且XPR配置读回正确；Vivado自带archive功能仍可能提示其不在utils_1。
之前完整构建证据仍见上级evidence/current及REPRODUCTION_STATUS.json；本轮不冒充重新跑过硬件构建或板测。
来源许可问题独立保留，不自动发布GitHub。

## 文件索引
native_create_r13_console.log：本轮成功创建原始控制台日志。
PROJECT_READBACK.tsv / readback_console.log：XPR独立读回。
repeat_console.log：重复执行，保留已有工程。
missing_tool / unsupported_path / source_hash_guard日志：预期失败保护测试，不是硬件功能失败。
RESULT_SUMMARY.json / NATIVE_BAT_VALIDATION.json：范围、校验与警告分类。
transmitter/receiver_ip_status.rpt：实际创建时IP状态。

## 保留的BD复位Critical提示
原始BD重建时保留两项BD 41-1347：
fine_doa_translate/aresetn、fine_doa_sqrt/aresetn均来自fine_production_system_0/cordic_aresetn。
这是实际工具提示，不是零告警。未修改复位拓扑，也未忽略、降级或放宽约束。
本轮源SHA和配置一致性、建工程与读回通过；没有对新BAT生成XPR重新运行物理CDC/STA签核。
不得从HOST TESTED推导这两条复位路径已由本轮完成硬件安全签核。完整原始提示见native_create_r13_console.log。
