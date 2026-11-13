# SSH 設定檢測

`sudo bash vps/check-ssh-config.sh`

需求：Bash、Python 3、OpenSSH server。報告 OS、認證方法、root／帳號限制、生效設定來源檔案與行號。`--user`、`--addr`、`--host`、`--laddr`、`--lport` 指定 Match 條件；`--config` 與 `--option` 對應自訂 daemon 參數。

完整選項、輸出範圍與範例見 [README](README.md#ssh-設定檢測)。
