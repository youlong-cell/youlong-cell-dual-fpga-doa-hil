# 许可证适用范围
原创部分按项目负责人选择采用MIT；第三方原有版权和条款继续有效。

## 2026-11-02 三文件补传
负责人在来源核查后明确要求直接上传，现原样补齐：
- receiver/ip_repo/ad9238_sample_1.1/hdl/ad9238_sample_v1_0.v：与ALINX原始课程对应文件字节相同。
- receiver/ip_repo/ad9238_sample_1.1/hdl/ad9238_sample_v1_0_S00_AXI.v：保留课程AXI框架，含本工程CDC与状态处理修改。
- receiver/software/src/lscript.ld：保留旧Xilinx生成声明及当前应用内存布局。

三份文件的分发依据尚未完全核实；上传决定与许可核实状态分开记录，不将它们重标为本项目原创MIT，不删除或替换原有声明。

## 其他第三方内容
- 带AMD/Xilinx MIT头的代码保留原版权与SPDX，原许可汇编见third_party。
- ALINX ad9238_sample.v按该文件自身的版权、分发与免责声明处理；不自动扩大其适用范围。
- 三份字形来自Noto Sans SC，适用OFL-1.1；原字体、许可、上游身份和生成资料见third_party/fonts。
- AMD工具、XPM和内置IP由使用者按适用条款安装及生成，本项目MIT不授予额外权利。
