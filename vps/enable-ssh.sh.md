# 啟用 SSH

`sudo bash vps/enable-ssh.sh`

需求：Bash、root、systemd 與 OpenSSH service。五行腳本辨識 service／socket 啟動模式，啟動 SSH 並設定開機啟動。

執行中的 service 保留原啟動模式；socket 執行中或 service 停止時使用 socket。錯誤狀態由 systemctl 傳回。

設定範圍及操作說明見 [README](README.md#ssh-控制)。
