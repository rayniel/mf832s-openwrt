# MF832S USB 热插拔与自动重连

本项目提供一个针对单台 ZTE MF832S 的 USB 监控服务：热插拔脚本只发送轻量通知，procd 管理的后台 worker 负责设备发现、AT 注册检查、PDP 恢复及 netifd DHCP 状态监控。服务不会自动改写 `/etc/config/network`、防火墙，也不会调用独立的 `udhcpc` 或重启全局网络。

## 适用范围和限制

- 默认 USB 身份为 `19d2:0199`；通过 UCI 可更改。仅有一个匹配设备时才继续；发现多个同身份设备时安全停止。
- 必须明确配置 MF832S 的 AT 串口、数据网卡和专用 netifd 逻辑接口。不会猜测 `ttyUSB0`、`eth1`，也不会默认接管任何现有 WAN。
- 仅检查 `+CREG?` 注册状态 `1`（本地注册）或 `5`（漫游）；未注册时等待，不反复执行 modem reset。网络接口由 netifd 的 DHCP 管理。
- 拨号恢复发送标准 `CGDCONT`、`CGATT`、`CGACT` 命令；不使用未经验证的 ZTE 专有命令。路由器侧 mock 测试不能代替 MF832S、运营商 APN 和具体固件的真机验证。
- 原文档提到 OpenWrt 18.06.4。该版本已过时，本修复没有真机验证该版本或所有后续版本；不同版本的 UCI 网络设备字段和驱动可能不同，需按下文检查。
- 同一台 modem 上有多个串口时，必须确认并显式指定 AT 端口；多台同 VID/PID 设备不受支持。配置的 netifd 设备必须是该 USB modem 的数据网卡。

## 依赖

基础系统需要 `procd`、`netifd`、`ubus`、`uci`、`logger`、BusyBox `ash`、`chat` 和 modem 对应的 USB/串口内核驱动。实际驱动取决于固件和设备枚举模式，常见候选包括 `kmod-usb-serial`、`kmod-usb-serial-option` 及设备对应的 USB 网络驱动；请先检查设备实际绑定情况，不要为了本脚本盲目安装所有协议包。

可选：`usbutils`（用于 `lsusb` 查看设备）。本服务不要求 `comgt`、PPP、NCM/QMI LuCI 协议插件；它们只有在你的其他配置确实使用时才需要。

## 安装和配置

先备份现有配置及同名文件。根据固件的网络语法，先创建一个**专用** DHCP interface；以下 `wwan0` 仅是示例，必须替换为实际设备名：

```sh
cp -a /etc/config/network /root/network.before-mf832s
uci set network.mf832s=interface
uci set network.mf832s.proto='dhcp'
# 较新的 netifd 配置：
uci set network.mf832s.device='wwan0'
# 旧版配置使用 ifname，而不是 device：
# uci set network.mf832s.ifname='wwan0'
uci commit network
```

不要把 `mf832s` 配成 `unmanaged`，不要把现有 WAN 或桥接接口改给本服务，也不要仅为安装本服务更改防火墙。需要将该出口加入某个 zone 时，请先审阅并单独配置防火墙策略。

复制文件（仓库根目录执行；先按设备实际位置检查网络配置）：

```sh
cp etc/config/mf832s /etc/config/mf832s
cp etc/hotplug.d/usb/20-mf832s.sh /etc/hotplug.d/usb/20-mf832s.sh
cp etc/init.d/mf832s-monitor /etc/init.d/mf832s-monitor
cp usr/sbin/mf832s-monitor /usr/sbin/mf832s-monitor
cp etc/chatscripts/mf832s.chat /etc/chatscripts/mf832s.chat
cp etc/chatscripts/mf832s-online-test.chat /etc/chatscripts/mf832s-online-test.chat
chmod 755 /etc/hotplug.d/usb/20-mf832s.sh /etc/init.d/mf832s-monitor /usr/sbin/mf832s-monitor
```

识别端口时插入 modem，查看 `dmesg`、`lsusb` 以及 `/sys/bus/usb/devices/` 中匹配 `19d2:0199` 的设备树。核实 AT 串口属于该 USB 设备（不要仅凭端口编号猜测），再设置：

```sh
uci set mf832s.main.enabled='1'
uci set mf832s.main.at_port='/dev/ttyUSB2'   # 替换为已确认的 AT 端口
uci set mf832s.main.network='mf832s'
uci set mf832s.main.data_device='wwan0'      # 替换为 network.mf832s 绑定的同一网卡
uci set mf832s.main.apn='your.apn'           # 按运营商要求填写；留空表示使用空 APN/设备默认配置
uci commit mf832s
```

默认 `enabled=0`、AT 端口和数据设备为空；未完成显式配置时服务不接管网络。`network`、`data_device`、USB ID 和 APN 会校验；服务还会验证 `network.<name>` 是绑定到该设备的 DHCP interface。18.06 等旧版使用 `ifname`，较新版使用 `device`；必须与目标设备配置一致。配置发生变化后重启服务：

```sh
/etc/init.d/mf832s-monitor enable
/etc/init.d/mf832s-monitor restart
logread -e mf832s
```

查看运行状态可用 `/etc/init.d/mf832s-monitor status`（若固件支持）、`ubus call network.interface.mf832s status` 和 `logread -e mf832s`。停止时执行 `/etc/init.d/mf832s-monitor stop`；服务会关闭它自身启动的逻辑接口。禁用并停止：`/etc/init.d/mf832s-monitor disable && /etc/init.d/mf832s-monitor stop`。

## 旧配置迁移、卸载和回滚

旧用法将 `eth1` 设为 `unmanaged` 并手动运行 `udhcpc -i eth1`。迁移前先记录原配置；停止旧脚本/手工 DHCP 客户端，再新建单独的 `proto dhcp` 逻辑接口并让 netifd 管理该设备。不能同时对同一网卡运行手工 `udhcpc` 和 netifd DHCP。不要直接覆盖旧 WAN 或其他逻辑接口。需要回滚时先停止并禁用本服务，移除它安装的脚本/服务/worker，再根据备份恢复 `/etc/config/network`；本项目卸载不会自动删改你的网络或防火墙设置。

```sh
/etc/init.d/mf832s-monitor stop
/etc/init.d/mf832s-monitor disable
rm -f /etc/hotplug.d/usb/20-mf832s.sh /etc/init.d/mf832s-monitor
rm -f /usr/sbin/mf832s-monitor
# 仅在确认不再需要后，手工删除 /etc/config/mf832s 和专用 network interface。
```

## 真机验收清单

在有控制台或其他 WAN 可恢复访问的条件下逐项检查，并确认日志和 `ubus call network.interface.mf832s status`：

1. modem 已插入时重启路由器，确认启动扫描发现设备并由 netifd 获得租约。
2. 拔出再插入，确认目标逻辑接口下线、重新发现，并恢复 DHCP；快速重复插拔，确认不出现重复 worker。
3. 保持 USB 接入，制造无线网络不可用/恢复情形，观察注册等待、重试间隔和重新获取 DHCP。
4. 让另一 WAN 同时在线，确认它未被服务改动，也不会被误认为 modem 的健康状态。
5. 检查 modem 的 AT 端口选择和 APN 是否正确；不要通过频繁重置 modem 来测试恢复。

## 本地回归测试

不需要 root 或真实 modem：

```sh
sh -n etc/hotplug.d/usb/20-mf832s.sh
sh -n etc/init.d/mf832s-monitor
sh -n usr/sbin/mf832s-monitor
sh tests/test-hotplug.sh
sh tests/test-monitor.sh
```

这些 mock 覆盖设备过滤、启动时已插入、节点晚就绪、netifd DHCP 等待、注册状态、退避恢复、重插身份变化、单实例、停止清理及禁用配置；通过仅表明模拟状态路径正常，不代表真机兼容性。
