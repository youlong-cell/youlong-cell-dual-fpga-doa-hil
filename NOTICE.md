# 本次公开范围补充

三份来源未确认文件已按负责人要求排除。接收端完整复现暂时受阻，详见根README和PUBLIC_RELEASE_STATUS.json。以下保留原候选的技术说明或历史许可待办，不把历史构建记录当作公开删减版验证。

# 第三方与来源说明
本系统使用Vivado/Vitis2023.1、AMD器件原语、XPM和内置IP。仓库保留自定义配置和连接关系，不打包工具安装包、生成网表、厂商IP输出产品、预编译BSP或libxil。

修改过的axidma/dppsu/dpdma驱动保留原MIT和版权头；修改用途包括服务预算及DisplayPort恢复。完整依赖许可汇编在third_party目录，适用范围按文件声明核对。

AN9238采集参考文件的ALINX署名、邮箱和许可头为第三方版权署名，故予以保留，不能在脱敏时冒充个人隐私直接删除。

模板包装、链接脚本的来源范围仍有待办，见docs/OPEN_SOURCE_READINESS.md；不得使用根MIT覆盖这些不确定项。

三份当前字形由Noto Sans SC生成，适用OFL-1.1，官方字体及许可在third_party/fonts/。字体与生成字形不以根MIT重新许可。
