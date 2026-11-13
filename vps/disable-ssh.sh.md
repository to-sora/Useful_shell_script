# 停止 SSH

`sudo bash vps/disable-ssh.sh`

需求：Bash、root、systemd 與 OpenSSH units。五行腳本停用開機啟動後，在同一個 stop 交易停止 service 與 socket。

執行後 SSH 接入停止；現有連線依發行版 KillMode 處理。恢復操作使用 VPS 主控台執行 `sudo bash vps/enable-ssh.sh`。

設定範圍及操作說明見 [README](README.md#ssh-控制)。
