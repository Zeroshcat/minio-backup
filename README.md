# MinIO 目录监控自动备份脚本

一款基于Shell开发的自动化备份工具，实时监控指定目录的文件变化，自动上传至MinIO对象存储，并提供灵活的版本管理和通知功能。

![Shell Script](https://img.shields.io/badge/Shell_Script-%23121011.svg?style=for-the-badge&logo=gnu-bash&logoColor=white)
![MinIO](https://img.shields.io/badge/MinIO-%230077B5.svg?style=for-the-badge&logo=minio&logoColor=white)

## 功能特性

- **实时监控**：使用 `inotifywait` 监控多个目录的文件写入事件
- **自动备份**：检测到新文件立即上传到MinIO存储桶
- **版本控制**：保留指定数量的历史版本（基于文件名排序）
- **策略选择**：支持删除/保留源文件两种处理方式
- **通知系统**：通过Telegram发送关键操作通知
- **日志管理**：自动清理30天前的旧日志

## 使用前准备

1. 确保已安装依赖工具：
```bash
# Debian/Ubuntu
sudo apt-get install inotify-tools jq curl

# RHEL/CentOS
sudo yum install inotify-tools jq curl epel-release
