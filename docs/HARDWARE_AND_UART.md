# 硬件连接与控制
- 发送：AX7103，器件xc7a100tfgg484-2，AN9767（AD9767双14bit DAC）。
- 接收：AXU2CGA，器件xczu2cg-sfvc784-1-i，AN9238（AD9238双12bit ADC）。
- DAC CH1→ADC CH0、DAC CH2→ADC CH1；接收相位CH1−CH0。
- HC-05 UART候选接线：模块TXD→J11.3/P16；模块RXD←J11.4/R17；共地。不可并联到板载USB-UART的TX输出。模块底板供电/逻辑必须按实物确认。
- 本版默认9600、8-N-1；config/uart_baud_config.vh可编译期选择115200，不是波特率自动识别。
- ASCII命令，以CR、LF或CRLF结束：SET 5M +40；SET 5M -40.5；SET 1M 0；OUTPUT ON；OUTPUT OFF；STATUS?。
- STATUS反映实际提交状态。0.1°为命令步进，不是模拟相位精度或接收角误差。
- 接模拟链前先用仪器核查幅度、直流偏置、负载、共地和削顶。模块端口不能未经资料确认就假定整链50Ω。不得通过本仓库脚本自动上电、烧录或扫串口。
