# 双FPGA相干信号实时测向与HIL验证系统

## 完整本地候选的历史验证范围
完整本地候选曾独立实跑：8项RTL测试、8项O0/O2宿主测试、收发端综合与布局布线、BIT、匹配XSA、新Platform/BSP/FSBL/PMUFW、A53 ELF和BOOT打包。最终ELF四频Profile与完整BOOT载荷已核验，未改原RTL/BD/XDC、测向算法或校准参数。

**以上是完整本地候选的离线构建记录，不代表本次补传进行了新的构建或板测。** 当前公开源码已发布到GitHub；本次未下载FPGA、未操作SD/QSPI。具体身份、指标与未核实边界见[REPRODUCTION_STATUS.json](REPRODUCTION_STATUS.json)和[evidence/current](evidence/current)。

## 快速开始：双击一个BAT
1. 安装 **Vivado 2023.1**，包含 Artix-7 和 Zynq UltraScale+ 对应器件支持。
2. 将整个源码包解压到短英文无空格目录，例如 E:\DOA。
3. 双击根目录 **create_project.bat**，等待提示“工程已准备好”。
4. 在Vivado中打开：
   - 发送端：transmitter/vivado/transmitter.xpr
   - 接收端：receiver/vivado/receiver.xpr

**创建工程无需安装Python，也无需逐项添加RTL、IP、BD或约束。**
BAT自动寻找Vivado，并使用Windows自带PowerShell校验源码；找不到工具时按提示粘贴其 vivado.bat 完整路径。

~~~bat
create_project.bat
~~~

此入口只创建工程及必要IP输出，不自动综合、布局布线、生成BIT/BOOT或烧录。
重复运行保留已有工程；若发现未完成目录，会停止并保留现场。
日志保存在 build/create_project/。项目创建验证范围见
[evidence/current/bat_create/CREATE_ONLY_REPORT.md](evidence/current/bat_create/CREATE_ONLY_REPORT.md)。

需要重新构建到BIT、XSA、ELF和BOOT时，再按[完整构建说明](docs/BUILD.md)操作。
Python仅用于这些高级构建、测试和维护脚本。

## 按自己电脑修改工具路径和版本

**目前实际验证的版本是 Vivado 2023.1。改安装路径与更换工具版本是两件事。**

| 电脑上的情况 | 应该怎么做 | 当前验证状态 |
| --- | --- | --- |
| 已安装2023.1，位于标准C/D/E盘Xilinx目录 | 直接双击BAT，通常无需修改 | 已验证2023.1创建收发工程 |
| 已安装2023.1，但盘符或安装目录不同 | 按下面方法指定完整路径 | 不改变工程版本；新电脑仍需本地验证 |
| 同时安装2023.1和其他版本 | 明确指定2023.1，避免环境变量或PATH选中其他版本 | 已验证版本仍为2023.1 |
| 只有2020.1、2022.2、2023.2、2024.2等其他版本 | 优先安装2023.1；若要迁移，按后文的迁移要求处理 | 其他版本未验证，不能仅改BAT年份就称兼容 |
| 使用2023.1的其他补丁版本 | 指定该工具完整路径，检查实际版本与日志 | Tcl按2023.1前缀检查，补丁版本未逐一验证 |

### 方法一：改BAT第9行，适合以后一直双击使用

1. 在资源管理器里找到自己安装的 **vivado.bat**，例如：
   D:\AMD\Vivado\2023.1\bin\vivado.bat。
   要填写这个文件的完整路径，不是vivado.exe、vitis.bat或安装目录本身。
2. 右键本仓库根目录的 **create_project.bat**，选择“编辑”（或用记事本打开）。
3. 找到当前第9行。行号以后可能移动，以以下命令原文为准：

~~~bat
set "DOA_VIVADO=%DOA_VIVADO_BAT%"
~~~

将这一整行替换为自己电脑上的真实路径，例如：

~~~bat
set "DOA_VIVADO=D:\AMD\Vivado\2023.1\bin\vivado.bat"
~~~

4. 保留双引号，保存后再双击BAT。只改这行即可固定工具路径。
   紧接着的判断会将它作为明确指定的工具，不再被后面的自动搜索覆盖。
5. 查看窗口里打印的“工具：”路径，确认选择正确。

**不必修改当前第118行的Vivado调用命令**，它会自动使用前面选定的路径。
也不要改动该调用中的-source、-tclargs或工程源文件路径。

### 方法二：不改文件，运行时指定路径

在仓库根目录打开Windows命令提示符（CMD），执行：

~~~bat
create_project.bat --vivado "D:\AMD\Vivado\2023.1\bin\vivado.bat"
~~~

该参数优先级最高，也可临时覆盖第9行设置。此方法不改动源码包，保留原SHA校验身份。
也可以仅在当前CMD窗口设置环境变量，然后运行：

~~~bat
set "DOA_VIVADO_BAT=D:\AMD\Vivado\2023.1\bin\vivado.bat"
create_project.bat
~~~

环境变量方法适用于第9行仍保留默认写法的情况；如果已将第9行改为固定路径，优先使用--vivado参数切换。

### 自动查找的顺序，以及第35行的含义

选择顺序为：--vivado参数 → 第9行指定的值（默认读取DOA_VIVADO_BAT） →
XILINX_VIVADO环境变量 → E/D/C盘标准2023.1安装目录 → PATH → 提示手工输入。

当前第35行包含自动搜索用的路径：

~~~text
%%D:\Xilinx\Vivado\2023.1\bin\vivado.bat
~~~

这一行中有两处2023.1；它们**只用于寻找工具**。
通常直接改第9行完整路径更清楚，不必修改这条循环。
电脑存在其他版本的XILINX_VIVADO或PATH设置时，请按方法一或方法二明确指定2023.1。

### 如果电脑只有其他年份版本

例如将第9行改成以下路径，只是启动2024.2，不会自动把工程迁移到2024.2：

~~~bat
set "DOA_VIVADO=D:\AMD\Vivado\2024.2\bin\vivado.bat"
~~~

当前 auto_create_project/create_project.tcl 第130行另有明确的版本检查：

~~~tcl
if {![string match "2023.1*" [version -short]]} {error "VIVADO_2023_1_REQUIRED"}
~~~

因此选中其他年份版本时，当前入口会停止并报VIVADO_2023_1_REQUIRED。
这与“找不到vivado.bat”不同；继续改BAT搜索路径不能解决版本不匹配。

当前推荐做法是安装并指定2023.1。若确需换工具大版本，应在另一个候选副本中：
核对BD/IP兼容性、处理版本检查和派生入口、重新创建工程并完成仿真/综合/实现及相关检查。
run.tcl是由中文主脚本生成的运行入口，不能只修改其中一份就认为已经完成迁移。
本仓库尚未提供经过验证的其他年份迁移版，不能通过删除版本检查宣称支持。

### 软件平台、目录与校验注意事项

- 这个BAT只创建收发端Vivado工程。改它的路径不会同步修改Vitis、BSP或ELF。
  完整BIT/XSA/ELF/BOOT流程目前按Vivado/Vitis 2023.1验证，详见[docs/BUILD.md](docs/BUILD.md)。
- 源码请放在短英文、无空格目录，例如 E:\DOA，不要放在中文目录或直接在ZIP中运行。
- 按方法一改BAT后，文件SHA自然会变化；原交付SHA只适用于未修改的原始包。
  单独修改工具路径不会改变RTL/BD/Profile，也不需要重生成设计输入清单。
  若希望原始包SHA保持一致，使用方法二。
- 已存在的工程会被保留，不会因为再次双击BAT就重新创建。
  若要从零检查另一安装环境，请把原始源码包解压到新的短英文目录再运行。
- 成功后应出现“工程已准备好”，并产生两个XPR及日志目录内的RESULT.txt。
  不要仅凭程序退出、窗口关闭或有一个XPR文件，就认定两端都已创建成功。

## 目录说明
- transmitter：AX7103/AN9767，四频、20预设、任意角度UART和按键。
- receiver：AXU2CGA/AN9238，FFT/Fine/PL校准/DOA，中文UI、原始及EMA显示、Profile15～18。
- scripts：身份检查、仿真、硬件与匹配软件/BOOT构建。
- third_party/fonts：Noto Sans SC/OFL及三份字模的生成来源，不依赖Windows字体。
- docs：架构、硬件/UART、构建及验证边界。
- evidence/current：本轮真实报告、回归日志和明确标注的HOST预览。
- SOURCE_MANIFEST、PROJECTS、SHA256SUMS：当前输入及完整交付树身份；build不进入源码交付。

~~~powershell
python -B scripts/hash_package.py
python -B scripts/check_package.py
python -B scripts/check_profiles.py
~~~

系统是有线虚拟阵列HIL，d=5m、c=3e8m/s、measured=false，不能描述成已完成真实天线绝对标定。字体资产替换只影响显示，不继承历史板测精度。

技术构建与公开许可分开：[LICENSE_SCOPE.md](LICENSE_SCOPE.md)、[docs/OPEN_SOURCE_READINESS.md](docs/OPEN_SOURCE_READINESS.md)仍列出两个采集模板包装和旧链接脚本的来源授权待确认。未自动发布GitHub。
