# 结构与数值约定
发送端：UART/按键→唯一控制与参数提交→相干NCO→DAC。模式知识来自config/hil_mode_catalog.json及生成表；禁止另存一张不一致的映射。

接收端：双通道ADC→FFT候选→时域Ring/冻结窗→细频插值/4K复相关→RAW→PL校准→DOA→Result FIFO→PS唯一消费者及身份ACK→不可变快照→UI。诊断DMA、FFT显示缓存和正式Fine窗口不是同一个数据对象。

Z=X1·conj(X0)，RAW定义CH1−CH0。CAL=wrap(sign·(RAW−bias))，DOA=asin(c·CAL/(2π·f_hat·d))，这里CAL单位为rad。S36/F35的相位整数以π为单位，deg=code×180/2^35。超出有效域必须返回无效。

d=5m、c=3e8m/s属于HIL数学模型，不是实际天线距离/电缆速度。Fs=62499374Hz为当前工程配置，未经独立计量；DAC125MHz来自独立发送板PLL，不代表两板共享时钟。

PS只选择已有分频Profile并沿STOP/INSTALL/COMMIT/ARM流程安装，不在线把未知信号相位强行归零。EMA只是同一真实发布流的显示滤波，不写回theta，不用于原始测角误差统计。
