2026-11-02补充：三份文件已按负责人明确指令原样补齐；其许可依据仍待核实。本轮未重新构建或板测，历史离线记录与本次补传分别理解。详见README和LICENSE_SCOPE.md。

# 从源码复现当前版本

本仓库只含当前RF/HIL版本，收发端分开，不含声学工程及历史制品。一键创建的工程位于各侧vivado目录，高级构建写入新的build子目录；均不访问板卡。实际完成状态和SHA以根REPRODUCTION_STATUS.json、evidence/current及原始日志为准。

## 最简单：一个BAT创建收发端工程
安装Vivado **2023.1**及对应器件支持，将源码解压到短英文无空格目录，双击根目录 create_project.bat。
自动找到Vivado后，直接创建：
- transmitter/vivado/transmitter.xpr
- receiver/vivado/receiver.xpr

本操作不要求Python，不自动综合/实现/生成镜像，也不操作板卡。
必要的PLL/BD/IP输出会生成；原始RTL、XDC、BD、Profile不改。
已有工程不覆盖；未完成的输出目录会报错停止，不自动清理。
完整日志在 build/create_project/run_*/，成功标记为 RESULT.txt 的 CREATE_PROJECTS_OK。

默认检查 DOA_VIVADO_BAT、XILINX_VIVADO、C/D/E盘标准安装路径及PATH。
也可以明确指定：
~~~bat
create_project.bat --vivado "E:\\Xilinx\\Vivado\\2023.1\\bin\\vivado.bat"
~~~
--no-pause用于自动验证。本入口要求短英文无空格路径；实测中文路径下PS IP初始化文件生成失败，因此提前阻断并提示，不假称支持。
移动已创建的工程前先关闭Vivado；推荐在最终源码存放位置运行BAT，而非单独复制XPR。

auto_create_project/create_project.tcl为可阅读中文主脚本，run.tcl和sources.tcl为已随包提供的ASCII派生入口，
由权威JSON生成。用户不需要运行生成器；维护者改动源清单后运行 scripts/generate_bat_entry.py 并检查差异。

## 以下为高级完整构建，不是双击建工程的前置步骤
下面仍保留已验证的独立仿真、硬件及软件构建流程；它们需要Python/Vitis等额外工具。

## 环境
- Windows，Vivado/Vitis **2023.1**，xc7a100t及xczu2cg器件支持和适用IP许可。
- Python3.12；Pillow12.3.0。仅编译已提供字模不要求重新栅格化；重新生成固定FreeType2.14.3。
- 可选完整宿主GCC用于O0/O2回归；启动器会给子进程补齐binutils PATH。
- 至少30GB工作空间；建议短ASCII仓库路径，例如E:\doa，避免Windows的260字符路径限制。
- 不依赖作者原机器工程、旧XSA/BSP或系统字体。AMD工具与内置IP不随包分发。

## 一条命令完成离线构建
在仓库根目录运行，按实际安装修改工具路径，run-name必须未使用：
~~~powershell
python -B scripts/reproduce.py --vivado E:\Xilinx\Vivado\2023.1 --vitis E:\Xilinx\Vitis\2023.1 --run-name clean1
~~~
增加--with-tests --host-gcc <gcc.exe完整路径>可先运行8项独立RTL和8项O0/O2宿主测试。RTL由实际xvlog/xelab/xsim运行，严格检查结束标记。

执行链：身份/Profile/模式表 → 收发端建工程 → 综合/布局布线/时序/CDC/DRC → BIT → 接收端匹配XSA → 新Platform/BSP/FSBL/PMUFW → 当前A53 ELF → BOOT → 分区及完整载荷逐字节核验。

失败即停并保留日志，不换历史DCP、不放宽约束、不覆盖旧输出、不操作硬件。成功后看build/clean1/COMPLETE.json与build/clean1_boot/BOOT_RESULT.json。本机实际执行证据与这些未来目录分开。

若路径太长，可由用户选择未占用的盘符：
~~~powershell
subst R: "实际仓库绝对路径"
python -B scripts/reproduce.py --vivado E:\Xilinx\Vivado\2023.1 --vitis E:\Xilinx\Vitis\2023.1 --run-name clean2 --repo-root R:/
~~~
别名必须解析到同一仓库，运行期间保持映射。结束后仅删除自己创建的映射，不覆盖他人盘符；优先直接放短目录。

## 分阶段排障
~~~powershell
python -B scripts/check_package.py
python -B scripts/check_profiles.py
python -B transmitter/scripts/generate_mode_catalog.py --check
python -B scripts/run_rtl_tests.py --tool-home E:\Xilinx\Vivado\2023.1 --out-name sim1
python -B scripts/run_host_tests.py --gcc <gcc.exe路径> --out-name host1
python -B scripts/prepare_project.py --side receiver --out-name rx1
python -B scripts/run_vivado.py --tool-home E:\Xilinx\Vivado\2023.1 --script build/rx1/loader.tcl --out-name rx1
python -B scripts/prepare_build.py --side receiver --project-run rx1 --out-name rx_pl1
python -B scripts/run_vivado.py --tool-home E:\Xilinx\Vivado\2023.1 --script build/rx_pl1/loader.tcl --out-name rx_pl1
~~~
发送端把side换为transmitter。平台、ELF、BOOT分别由build_platform.py、build_ps.py、build_boot.py驱动，参数见各脚本--help。只接收本轮真实产物，不能拿文件名证明匹配。

## 保持的合同
- 原RTL、BD、ROM、XDC、Profile不改变，按SOURCE_MANIFEST及PROJECTS校验。
- TX保留原synth_1后处理apply_uart_j11.tcl，确保J11约束生效。PLL只重定位候选XCI输出目录，不改变配置参数。
- RX直接加载原BD逐字节副本。disabled的纯CDC XDC继续disabled，guard保持implementation-only/LATE及opt_design PRE失败阻断。
- 本机可用入口是ASCII直接执行壳，人读主脚本仍为中文UTF-8。保留厂商所需用户目录环境，不宣称已屏蔽个人init.tcl。禁用可再生IP缓存，不改变设计或时序例外。
- A53按BUILD_SPEC的25个单元构建，从最终ELF再次解码Profile15～18，不修改四频校准及几何。
- BOOT核验FSBL/PMUFW/应用内存范围、器件、分区及完整PL/ELF载荷。
- 无JTAG、SD/QSPI或自动部署。新制品未经过真实ADC/DMA/DP和精度复测。

## 开源字模
third_party/fonts包含固定提交Noto Sans SC及OFL-1.1，三份字模不含微软雅黑。
~~~powershell
python -m pip install -r requirements-fonts.txt
python -B scripts/generate_fonts.py
~~~
固定weight400、七个行高、85%行高基线；renderer API不变。1502字形覆盖度流逐像素解码自检，并验证重复生成SHA一致，见GENERATED_ASSETS.json。

## 结论边界
不承诺不同机器的BIT SHA、放置结果或资源数逐位一致；BIT头含时间戳，实现和SDK路径也可能影响二进制。应核对源身份、配置、报告、ELF参数和载荷。

系统是有线HIL，d=5m、c=3e8m/s、measured=false；新构建不继承历史板测签核或测角精度。发布许可门槛与技术构建分开判断。
