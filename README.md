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
bash <(curl -sL https://raw.githubusercontent.com/byilrq/TrafficCop/main/trafficcop-manager.sh)
```
   
![image](交互式脚本.png)


### 一键全家桶TG推送（调用api，版本最新，可能会403）：
```
sudo apt update && mkdir -p /root/TrafficCop && curl -H "Accept: application/vnd.github.v3.raw" -fsSL "https://api.github.com/repos/ypq123456789/TrafficCop/contents/trafficcop.sh" | tr -d '\r' > /root/TrafficCop/traffic_monitor.sh && chmod +x /root/TrafficCop/traffic_monitor.sh && bash /root/TrafficCop/traffic_monitor.sh && sudo curl -H "Accept: application/vnd.github.v3.raw" -fsSL "https://api.github.com/repos/ypq123456789/TrafficCop/contents/tg_notifier.sh" | tr -d '\r' > /root/TrafficCop/tg_notifier.sh && chmod +x /root/TrafficCop/tg_notifier.sh && bash /root/TrafficCop/tg_notifier.sh
```
### 一键全家桶TG推送（从原始内容下载，版本可能落后）：
```
sudo apt update && mkdir -p /root/TrafficCop && curl -fsSL "https://raw.githubusercontent.com/ypq123456789/TrafficCop/main/trafficcop.sh" | tr -d '\r' > /root/TrafficCop/traffic_monitor.sh && chmod +x /root/TrafficCop/traffic_monitor.sh && bash /root/TrafficCop/traffic_monitor.sh && sudo curl -fsSL "https://raw.githubusercontent.com/ypq123456789/TrafficCop/main/tg_notifier.sh" | tr -d '\r' > /root/TrafficCop/tg_notifier.sh && chmod +x /root/TrafficCop/tg_notifier.sh && bash /root/TrafficCop/tg_notifier.sh
```
### 一键全家桶pushplus推送（调用api，版本最新，可能会403）：
```
sudo apt update && mkdir -p /root/TrafficCop && curl -H "Accept: application/vnd.github.v3.raw" -fsSL "https://api.github.com/repos/ypq123456789/TrafficCop/contents/trafficcop.sh" | tr -d '\r' > /root/TrafficCop/traffic_monitor.sh && chmod +x /root/TrafficCop/traffic_monitor.sh && bash /root/TrafficCop/traffic_monitor.sh && sudo curl -H "Accept: application/vnd.github.v3.raw" -fsSL "https://api.github.com/repos/ypq123456789/TrafficCop/contents/pushplus_notifier.sh" | tr -d '\r' > /root/TrafficCop/pushplus_notifier.sh && chmod +x /root/TrafficCop/pushplus_notifier.sh && bash /root/TrafficCop/pushplus_notifier.sh
```
### 一键全家桶pushplus推送（从原始内容下载，版本可能落后）：
```
sudo apt update && mkdir -p /root/TrafficCop && curl -fsSL "https://raw.githubusercontent.com/ypq123456789/TrafficCop/main/trafficcop.sh" | tr -d '\r' > /root/TrafficCop/traffic_monitor.sh && chmod +x /root/TrafficCop/traffic_monitor.sh && bash /root/TrafficCop/traffic_monitor.sh && sudo curl -fsSL "https://raw.githubusercontent.com/ypq123456789/TrafficCop/main/pushplus_notifier.sh" | tr -d '\r' > /root/TrafficCop/pushplus_notifier.sh && chmod +x /root/TrafficCop/pushplus_notifier.sh && bash /root/TrafficCop/pushplus_notifier.sh
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

