*Update: 2026.02.02*
Please forgive my poor English expressing if that makes you uncomfortable.🙏
  
### RT-Thread-Linux-Toolset
A Toolset that created for myself to compile RT-Thread BSPs on Linux.
一个用于在 Linux 系统上编译 RT-Thread BSP 的自用工具箱。

### Usage 使用方法
- `picocom`: directory for ***`bash`*** scripts used to connect the serial debugger. 存放连接串口调试器的 ***`bash`*** 脚本。
- `openocd`: contains `openocd` configuration scripts and a ***`bash`*** script (`flash2mcu.sh`) for flashing programs to the MCU. The ***`bash`*** script needs manually changing of the `openocd` cfg scripts name inside as needed. 存放 `openocd` 的配置文件和烧录程序的 `flash2mcu.sh` 脚本，`flash2mcu.sh` 脚本要按需手动替换其中指定的 `openocd` 配置文件。
- `venv-creator.sh`: to create a virtual Python environment where ***scons*** and other packages exist, for detail see `requirements.txt`. 创建 ***scons*** 工具所需的 Python 虚拟环境，环境中安装的主要包详见 `requirements.txt`。
- `requirements.txt`: it is needed to create the virtual Python environment mentioned above. Don't worry if it is lost as its content is hardcoded in the script above, which can be created again from scratch. 用于创建上面提到的 Python 虚拟环境。该文件可以通过上述脚本生成。
- `convert-rtconfig.py`: it can convert (actually generate after analyze) the original `rtconfig.py` to a **"Linux version"**. Differences will show in convert logs. 将原本的 `rtconfig.py` 转换成可在 Linux 下正常工作的版本。转换差异将写在转换日志中。
- `compile-env-check.py`: it checks the basic compile environment and toolchain that is needed. The Toolset uses **GCC (gcc)**. 检查基础的编译环境与工具链，该工具箱使用 **GCC（gcc）**。
- `build-flash.sh`: the ***`bash`*** script which executes the actual complete build-flash workflow. 用于执行完整编译-下载工作流的脚本。

### Feature 特点
- Every executable script will print help message with `-h` or `--help`. 所有的可执行脚本均可通过 `-h` 或 `--help` 参数获得帮助信息。
- All scripts have been strictly checked by multiple LLMs and have met the basic requirements for use in a production environment. 所有脚本均经过（多个 LLM）严格的检查，已达到基本的生产环境使用要求。

### Other 其他
- All the scripts' print messages are all written in **Simplified Chinese**. 该工具箱中的所有脚本的输出信息均为**简体中文**
- Written on Fedora 43 KDE, not fully tested on other Linux Distributions. 该工具箱在 Fedora 43 KDE上编写，未在其他 Linux 发行版上进行充分测试。
- Using GCC (gcc). 使用 GCC（gcc）工具链。
- Written by myself, some habits may not suit everyone. 个人编写，某些习惯可能不适合所有人。
- Written separately so scripts' behaviours have minor differences. 脚本是分开编写的所以其行为有些许差异。
- There might be undiscovered issues or bugs. 可能有未能察觉的暗病。
- Backward compatibility with older version (e.g., 4.x.x) of RT-Thread source code was not tested. The toolset was built and run well with source code version 5.3.0 (2025's official master branch on Github). 对旧版本 RT-Thread 源码的向下兼容性没有测试。这个工具箱在 2025 年官方 master 分支的 5.3.0 版本源码中工作得很好。

### Example 示例
Assume Python 3 was installed properly and in a BSP directory with `hotfix` directory which holds the toolset copied in. (Its name can be changed freely, `hotfix` is what it is called from scratch.)
假设 Python 3 已正确安装，并且当前在一个有包含这个工具箱文件夹的 BSP 文件夹内。（工具箱的名字可以随意改，`hotfix` 是这个工具箱一开始的名字。）
- check compile environment 检查编译环境:
```bash
python ./hotfix/compile-env-check.py
```

- convert 转换 `rtconfig.py`:
```bash
python ./hotfix/convert-rtconfig.py ./rtconfig.py
```

- create venv 创建 venv 环境:
```bash
./hotfix/venv-creator.sh
```
And then follow the instructions. 接下来按脚本引导即可。

- build & flash 编译 & 烧录:
```bash
./hotfix/build-flash.sh
```
Use `-h` or `--help` for more details. 使用 `-h` 或 `--help` 参数查看更多细节
DO NOT forget to modify `openocd` cfg in `flash2mcu.sh` before flash ! 不要忘记在烧录前修改 `flash2mcu.sh` 里的 `openocd` 的配置文件！

- picocom:
Assume picocom is installed properly. 假设 picicom 已正确安装。
On board debugger usually named `/dev/ttyACMx`, in the file below is `ttyACM0`, change if needed.
板载调试器在系统中通常命名为 `/dev/ttyACMx`，在下面的文件中是 `ttyACM0`，请按需修改。
```bash
./hotfix/picocom/serial-ACM.sh
```

Single debugger usually named `/dev/ttyUSBx`, in the file below is `ttyUSB0`, change if needed.
单独调试器在系统中通常命名为 `/dev/ttyUSBx`，在下面的文件中是 `ttyUSB0`，请按需修改。
```bash
./hotfix/picocom/serial-USB.sh
```
Some Linux Distributions may need `sudo` to make the scripts run.
某些 Linux 发行版可能需要 `sudo` 来运行这两个脚本。

If both of them do not work, please check the `/dev` directory to find out the real name of the debugger.
如果这两个脚本都不工作,请检查 `/dev` 目录找到正确的调试器设备文件名称。