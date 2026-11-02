#ifndef UI_ZH_H
#define UI_ZH_H
/* Presentation-only translations. Never alter protocol/model status strings. */
#include <string.h>
#include <stdio.h>
typedef struct { const char *en,*zh; } ui_translation_t;
static const ui_translation_t ui_zh_labels[]={
 {"REAL-TIME DOA ANALYZER | DUAL FPGA HIL","实时 DOA 测向终端 | 双 FPGA HIL"},
 {"ENGINEERING_TEST / NOT_SIGNED_OFF","工程测试 / 未签核  ENGINEERING_TEST"},
 {"DOA RESULT","DOA 测向结果"},{"HIL VALIDATION","HIL 验证"},
 {"ENGINEERING DETAIL","采集诊断"},{"SYSTEM DETAIL","系统详情"},
 {"AZIMUTH","方位角"},
 {"STALE / ENGINEERING ESTIMATE","结果已过期 / 工程估计"},
 {"LIVE ENGINEERING ESTIMATE","实时工程估计"},
 {"SIGNAL INVALID","信号无效"},{"NO CURRENT DIRECTION","暂无有效方向"},
 {"Frequency","频率"},{"Raw Phase","原始相位 RAW"},
 {"Cal Phase","补偿相位 CAL"},{"Result Age","结果距今"},
 {"STATUS: ENGINEERING MODE","状态：工程模式"},
 {"SOURCE CONFIG","发送端参考配置"},{"Frequency: ---","参考频率：---"},
 {"Phase Offset: ---","参考相位：---"},{"SOURCE NOT CONFIGURED","发送端参考未配置"},
 {"MEASURED / FINAL PL RESULT","实际测量 / PL 最终结果"},
 {"Reference angle: ---","参考角度：---"},{"Error: ---","测角误差：---"},
 {"NO SOURCE TRUTH / NO ERROR CLAIM","缺少独立参考，不报告测角精度"},
 {"Measured values never use source settings","测量值不使用发送端设定值代替"},
 {"FIFO OCCUPANCY: NOT AVAILABLE","FIFO 占用：未提供"},
 {"Detailed errors on UART / no added polling","详细诊断见 UART；不增加硬件轮询"},
 {"LIVE FFT SPECTRUM","实时 FFT 频谱"},
 {"CH0 cyan","CH0 青色"},{"CH1 amber","CH1 琥珀色"},
 {"NO FFT DATA","暂无 FFT 数据"},
 {"-110 dBFS REFERENCE ONLY","-110 dBFS 仅显示参考线"},
 {"Frequency / MHz","频率 / MHz"},
 {"Live spectrum and final DOA are independent snapshots","频谱与最终 DOA 为独立时刻的快照"},
 {"TARGET INFO","目标信息"},{"SYSTEM STATUS","系统状态"},
 {"SNR: ---","SNR：---"},
 {"Noise Floor: -110 dBFS (UI)    Latency: ---","显示底限：-110 dBFS    处理时延：---"},
 {"SNR / processing latency unavailable; no substituted metric","SNR / 处理时延未提供；不以其他指标代替"},
 {"OK","正常"},{"ERROR","错误"},{"NO DATA","无数据"},
 {"NOT INITIALIZED","未初始化"},{"NOT READY","未就绪"},{"INVALID","无效"},
 {"VALID","有效"},{"FAULT","故障"},{"STALE","已过期"},
 {"READY","就绪"},{"RUNNING","运行中"},{"ACTIVE","已启用"},{"CLOSED","已关闭"},
 {"ENGINEERING_ESTIMATE","工程估计 ENGINEERING_ESTIMATE"},
 {"ENGINEERING_ESTIMATE / UNCALIBRATED","未独立标定 ENGINEERING_ESTIMATE / UNCALIBRATED"}
};
/* Known reason prefixes retain the original status suffix for diagnosis.
 * Unknown future reasons remain verbatim, rather than inventing semantics. */
static const ui_translation_t ui_zh_reasons[]={
 {"UNCALIBRATED","未标定 UNCALIBRATED"},
 {"INVALID FREQUENCY","频率无效"},{"INVALID PHASE","相位无效"},
 {"INVALID GEOMETRY","几何配置无效"},{"SPATIAL AMBIGUITY","空间模糊"},
 {"ASIN DOMAIN","ASIN 超出定义域"},
 {"GEOMETRY BOUNDARY UNCERTAIN","几何边界不确定"},
 {"GEOMETRY NUMERIC RANGE","几何数值越界"},{"PHASE BOUNDARY UNCERTAIN","相位边界不确定"},
 {"UNRECOGNIZED DOA STATUS","未知 DOA 状态"},
 {"INTERPOLATION NOT CONFIGURED","插值未配置"},
 {"INTERPOLATION INVALID SCORE","插值功率无效"},
 {"CENTER NOT LOCAL MAXIMUM","中心频点不是局部峰值"},
 {"LOW PEAK PROMINENCE","峰值突出度不足"},
 {"NONNEGATIVE CURVATURE","插值曲率非负"},{"WEAK CURVATURE","插值曲率不足"},
 {"DELTA OUT OF RANGE","插值偏移越界"},{"FREQUENCY / META RANGE","频率或元数据越界"},
 {"INTERPOLATION CONFIG BUDGET","插值误差预算无效"},
 {"THREE-BIN / CONFIG INVALID","三频点或配置无效"},
 {"CALIBRATION NOT CONFIGURED","相位补偿未配置"},
 {"CALIBRATION CONFIG INVALID","相位补偿配置无效"},
 {"CALIBRATION FREQUENCY RANGE","超出相位补偿频带"},
 {"CALIBRATION INVALID","相位补偿无效"},{"FINE CONFIG INVALID","Fine 配置无效"},
 {"FINE 4K INVALID","Fine 4K 数值无效"},{"CROSS PHASE INVALID","交叉谱相位无效"},
 {"NUMERIC INVALID","数值无效"},
 {"UI THETA CODE OUT OF RANGE (NO CLAMP)","角度编码越界，不强行限幅"},
 {"SOFTWARE PROTOCOL FAULT / reason ","软件协议故障 / 原因 "}
};
static inline const char *ui_zh_text(const char *s,char *scratch,size_t size)
{
 for(unsigned i=0;i<sizeof ui_zh_labels/sizeof ui_zh_labels[0];i++)
  if(!strcmp(s,ui_zh_labels[i].en))return ui_zh_labels[i].zh;
 for(unsigned i=0;i<sizeof ui_zh_reasons/sizeof ui_zh_reasons[0];i++){
  size_t n=strlen(ui_zh_reasons[i].en);
  if(!strncmp(s,ui_zh_reasons[i].en,n)&&(s[n]==0||s[n]==' ')){
   snprintf(scratch,size,"%s%s",ui_zh_reasons[i].zh,s+n);return scratch;
  }
 }
 return s;
}
static inline const char *ui_zh_state(enum debug_state s)
{return s==DBG_OK?"正常":s==DBG_ERROR?"错误":s==DBG_NO_DATA?"无数据":"未初始化";}
#endif
