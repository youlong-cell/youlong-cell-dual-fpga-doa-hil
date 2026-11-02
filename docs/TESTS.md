# 当前可运行验证
- run_rtl_tests.py：发送端5项（译码7204向量、映射7204向量、真实UART任意角度/仲裁、三波特率、回复FIFO）；接收端3项（采样身份、结果槽身份ACK、相位校准）。被测RTL不改。
- 相位补偿整数Golden：2272个合成向量，覆盖正负、回绕、频带边界及非法配置；平台还覆盖COMMIT/任务快照、保持、复位和中止。不是整条ADC→FFT→Fine的端到端RTL验证。
- run_host_tests.py：字体覆盖度/混色/边界、EMA、频谱平滑、1920×1200 UI，各O0/O2。UI明确标注HOST MOCK，不能作为板测截图。
- generate_fonts.py检查解码和重复生成SHA；check_profiles.py检查四频配置及固定点。
- build_ps.py检查最终ELF架构、入口、必须符号、内嵌Profile及DDR范围。
- build_boot.py检查启动组件、应用和PL分区完整载荷。
- 完整硬件报告保留时序、资源、CDC、DRC，以原始结果为准，不能只凭正WNS宣称所有CDC签核。
命令见[BUILD.md](BUILD.md)，每轮新输出名，失败记录不覆盖。真实板测须人工完成，无自动部署。
