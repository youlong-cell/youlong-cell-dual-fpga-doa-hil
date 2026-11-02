@echo off
setlocal DisableDelayedExpansion
set "DOA_DIRECTORY=%~dp0"
for /f "tokens=2 delims=:" %%C in ('chcp') do set "DOA_ORIGINAL_CP=%%C"
chcp 65001 >nul
rem 双击只创建收发两端Vivado工程，不综合、不生成镜像、不烧录。
set "DOA_NO_PAUSE="
set "DOA_EXPLICIT_TOOL="
set "DOA_VIVADO=%DOA_VIVADO_BAT%"
if defined DOA_VIVADO set "DOA_EXPLICIT_TOOL=1"

:parse_args
if "%~1"=="" goto locate_tool
if /I "%~1"=="--no-pause" (
    set "DOA_NO_PAUSE=1"
    shift /1
    goto parse_args
)
if /I "%~1"=="--vivado" (
    if "%~2"=="" goto bad_arguments
    set "DOA_VIVADO=%~2"
    set "DOA_EXPLICIT_TOOL=1"
    shift /1
    shift /1
    goto parse_args
)
goto bad_arguments

:locate_tool
rem PS IP生成器对中文和空格路径支持不完整，提前给出明确提示。
if not "%DOA_DIRECTORY: =%"=="%DOA_DIRECTORY%" goto unsupported_path
for /f "delims=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_:\-./" %%C in ("%DOA_DIRECTORY%") do goto unsupported_path
if defined DOA_EXPLICIT_TOOL goto check_tool
if defined XILINX_VIVADO if exist "%XILINX_VIVADO%\bin\vivado.bat" set "DOA_VIVADO=%XILINX_VIVADO%\bin\vivado.bat"
for %%D in (E D C) do if not defined DOA_VIVADO if exist "%%D:\Xilinx\Vivado\2023.1\bin\vivado.bat" set "DOA_VIVADO=%%D:\Xilinx\Vivado\2023.1\bin\vivado.bat"
if not defined DOA_VIVADO for /f "delims=" %%I in ('where vivado.bat 2^>nul') do if not defined DOA_VIVADO set "DOA_VIVADO=%%I"
if defined DOA_VIVADO goto check_tool
echo 未找到Vivado 2023.1。
if defined DOA_NO_PAUSE goto missing_tool
set /p "DOA_VIVADO=请粘贴vivado.bat完整路径，然后回车："
set "DOA_VIVADO=%DOA_VIVADO:"=%"

:check_tool
if not defined DOA_VIVADO goto missing_tool
if not exist "%DOA_VIVADO%" goto missing_tool
set "DOA_LOG_REL=build\create_project\run_%RANDOM%_%RANDOM%"
set "DOA_LOG=%DOA_DIRECTORY%%DOA_LOG_REL%"
if exist "%DOA_LOG%" goto log_conflict
mkdir "%DOA_LOG%"
if errorlevel 1 goto log_conflict
echo 正在从源码创建发送端和接收端工程，请等待。
echo 工具：%DOA_VIVADO%
echo 详细日志：%DOA_LOG%
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%DOA_DIRECTORY%auto_create_project\verify_inputs.ps1" -LogDirectory "%DOA_LOG%"
set "DOA_RC=%ERRORLEVEL%"
if not "%DOA_RC%"=="0" goto failed
pushd "%DOA_DIRECTORY%"
if errorlevel 1 goto path_error
rem 收发端分属不同器件，使用独立Vivado进程创建，避免工程状态相互污染。
call :create_side transmitter
set "DOA_RC=%ERRORLEVEL%"
if not "%DOA_RC%"=="0" goto side_failed
call :create_side receiver
set "DOA_RC=%ERRORLEVEL%"
if not "%DOA_RC%"=="0" goto side_failed
popd
echo CREATE_PROJECTS_OK>"%DOA_LOG%\RESULT.txt"
echo.
echo 工程已准备好，用Vivado打开以下文件：
echo 发送端：%DOA_DIRECTORY%transmitter\vivado\transmitter.xpr
echo 接收端：%DOA_DIRECTORY%receiver\vivado\receiver.xpr
echo 本次没有运行综合、布局布线或生成镜像。
set "DOA_RC=0"
goto finish

:side_failed
popd
goto failed
:unsupported_path
echo 请将整个源码目录放到短英文无空格路径，例如 E:\DOA，再双击本BAT。
echo 当前Vivado的PS IP生成器不保证中文或空格路径可用，尚未创建新工程。
set "DOA_RC=2"
goto finish
:bad_arguments
echo 参数错误。通常直接双击即可。
echo 自动测试可用：create_project.bat --no-pause --vivado "工具完整路径"
set "DOA_RC=2"
goto finish
:missing_tool
echo 找不到有效的Vivado入口：%DOA_VIVADO%
echo 请安装Vivado 2023.1，或将其vivado.bat路径填入环境变量DOA_VIVADO_BAT。
set "DOA_RC=2"
goto finish
:log_conflict
echo 无法创建新的日志目录，原有文件没有覆盖。
set "DOA_RC=3"
goto finish
:path_error
echo 无法进入源码目录。
set "DOA_RC=3"
goto finish
:missing_result
echo 工具没有给出完整成功标记，不能判定工程创建成功。
set "DOA_RC=4"
goto failed
:failed
echo 创建未完成。请查看刚才显示的日志目录。
echo 已有工程和失败现场均保留，不会自动删除。
if "%DOA_RC%"=="0" set "DOA_RC=4"
:finish
if not defined DOA_NO_PAUSE pause
if defined DOA_ORIGINAL_CP chcp %DOA_ORIGINAL_CP% >nul
exit /b %DOA_RC%


:create_side
set "DOA_SIDE=%~1"
call "%DOA_VIVADO%" -mode batch -nojournal -log "%DOA_LOG_REL%\%DOA_SIDE%_vivado.log" -source auto_create_project/run.tcl -tclargs "%DOA_SIDE%" "%DOA_LOG_REL%"
set "DOA_RC=%ERRORLEVEL%"
if not "%DOA_RC%"=="0" exit /b %DOA_RC%
if not exist "%DOA_LOG%\%DOA_SIDE%_result.txt" exit /b 4
set "DOA_RESULT="
for /f "usebackq delims=" %%R in ("%DOA_LOG%\%DOA_SIDE%_result.txt") do if not defined DOA_RESULT set "DOA_RESULT=%%R"
if not "%DOA_RESULT%"=="CREATE_PROJECT_SIDE_OK" exit /b 4
exit /b 0
