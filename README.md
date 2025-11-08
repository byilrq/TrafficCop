# TrafficCop - 智能流量监控与限制脚本

1. 如果遇到问题，可以查看日志文件(/root/TrafficCop/traffic_monitor.log)获取更多信息。
## 常见问题
Q: 如何完全卸载脚本?
A: 使用以下命令:
```
sudo pkill -f traffic_monitor.sh
sudo rm -rf /root/TrafficCop
sudo tc qdisc del dev $(ip route | grep default | cut -d ' ' -f 5) root
```


## 一键安装脚本
### 一键安装交互式脚本
```
wget -N --no-check-certificate https://raw.githubusercontent.com/byilrq/TrafficCop/main/trafficcop-manager.sh && bash trafficcop-manager.sh
```

## 实用命令
### 查看日志：
```
sudo tail -f -n 30 /root/TrafficCop/traffic_monitor.log
```
### 查看当前配置：
```
sudo cat /root/TrafficCop/traffic_monitor_config.txt
```
### 紧急停止所有traffic_monitor进程（用于脚本出现问题时）：
```
sudo pkill -f traffic_monitor.sh
```

