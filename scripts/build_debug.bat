@echo off

set VC_DIR=D:\Program Files (x86)\Microsoft Visual Studio 12.0\VC
set MSDK_DIR=C:\Program Files (x86)\Microsoft SDKs\Windows\v7.1A
set QT_DIR=D:\Qt\Qt5.4.2\5.4\msvc2013_opengl
set INCLUDE=%VC_DIR%\include
set LIB=%MSDK_DIR%\Lib;%VC_DIR%\lib
set SRC_DIR=%cd%
set BUILD_DIR=%cd%\build
set PATH=%VC_DIR%\bin;%MSDK_DIR%\Bin;%QT_DIR%\bin

if not exist %QT_DIR% exit
if not exist %SRC_DIR% exit
if not exist %BUILD_DIR% md %BUILD_DIR%

cd build

@REM call "C:\Program Files (x86)\Microsoft Visual Studio\2013_opengl\Community\VC\Auxiliary\Build\vcvarsall.bat" x86

%QT_DIR%\bin\qmake.exe %SRC_DIR%\qtest.pro -spec win32-msvc2013  "CONFIG+=debug" "CONFIG+=console"
if exist %BUILD_DIR%\debug\qtest.exe del %BUILD_DIR%\debug\qtest.exe
nmake Debug
if not exist %BUILD_DIR%\debug\Qt5Cored.dll (
  %QT_DIR%\bin\windeployqt.exe %BUILD_DIR%\debug\qtest.exe
)