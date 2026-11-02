# 本轮复现的限制和剩余告警

本轮只验证离线构建与限定测试，没有板级测试或SIGNED OFF。所有原始报告保留，不降低严重等级、不新增放宽时序例外。

- 接收端routed：WNS +1.152ns，WHS +0.011ns，TNS/THS=0。该新运行与历史实现不是同一报告，不继承历史+1.848ns等数值。
- 接收端CDC：139项CDC-3 Info、70项CDC-9 Info、4项CDC-15 Warning，无Critical。四项Warning定位在厂商AXI clock converter m13_couplers/auto_cc的分布式RAM读出寄存器；本轮没有为其单独重做硬件/物理安全签核，不能称所有CDC Warning已清零。
- DRC：158项Warning（DSP流水线建议145、RAM相关12、RTSTAT-10一项），无Error/Critical。方法学保留一项ULMTCS-1，1486个control sets。没有用ignore/waiver或severity降级消除。
- bus skew：原始报告92条被报告路径、最小所报Slack +5.548ns、VIOLATED=0。路径条数不等于约束组数；完整原始报告留在build/rx9/project/receiver.runs/impl_1/top_bus_skew_routed.rpt，摘要及SHA随当前证据。
- ignored timing exceptions：报告明确No ignored timing exceptions found。
- 新平台的厂家库保留XPAR_MICROBLAZE_ADDR_SIZE未定义的-Wundef告警；应用保留一项未使用静态函数告警。构建未删除驱动或屏蔽错误。
- UI字体使用Noto/OFL，宿主预览为HOST MOCK，不是上板截图或UI实际FPS证据；1502字形解码、O0/O2边界测试和重复生成SHA通过。
- 当前所有新制品NOT_BOARD_VERIFIED；四频measured=false保持，不把HIL命令参考变为绝对仪器标定。
- 各阶段实际独立执行通过。一键编排脚本已连接同一组组件并检查语法/帮助，没有为其再重复第二次完整硬件构建。
- 本机运行期间使用R:映射到repository；原始命令中的R:/build是本目录build的别名。源码交付包不含build、历史版本或声音工程。

## 与历史实现指标的区别
本轮接收端实际为33451 LUT、48809 FF、7740 CLB（87.76%）、119.5 BRAM、102 DSP。不能把历史6886/6619 CLB或+1.848/+1.702ns写成这份新BIT的结果。
本轮采用项目默认实现流程、6线程；历史rebuild_20261023使用非项目opt/place/phys_opt/route Default及2线程。已确认没有遗漏原XPR的Verilog define/generic，但没有做消融来单独归因资源差异。本轮目标是完整离线构建，不是逐位或原优化指标复刻；源码和校准参数未改。不得把新实现当作旧版本性能复验。
