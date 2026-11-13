# VPS 工具

四個獨立腳本；SSH 啟用與停止腳本各五行。SSH 控制適用於使用 systemd、安裝 OpenSSH 的 Linux VPS；工具安裝適用於 Debian／Ubuntu。

| 腳本 | 用途 | 指令 |
| --- | --- | --- |
| [enable-ssh.sh](enable-ssh.sh) | 啟用 SSH 並設定開機啟動 | `sudo bash vps/enable-ssh.sh` |
| [disable-ssh.sh](disable-ssh.sh) | 停止 SSH service/socket 並停用開機啟動 | `sudo bash vps/disable-ssh.sh` |
| [check-ssh-config.sh](check-ssh-config.sh) | 檢測 OS、SSH 認證與帳號規則，列出來源檔案及行號 | `sudo bash vps/check-ssh-config.sh` |
| [install-tools.sh](install-tools.sh) | 透過 apt-get 安裝常用管理工具 | `sudo bash vps/install-tools.sh` |

## SSH 控制

啟用腳本辨識 `ssh.service`／`sshd.service` 及 `ssh.socket`／`sshd.socket`，排除 alias。執行中的 service 保持 service 啟動模式；socket 執行中或 service 停止時使用 socket。啟用動作遇到 masked unit 時回傳 systemd 錯誤。

停止腳本停用開機啟動後，將 service 與 socket 放入同一個 stop 交易，讓中斷 SSH 工作階段的發行版完成停用設定。執行後 SSH 接入停止；現有連線的處理取決於發行版的 `KillMode`。恢復操作可透過 VPS 主控台執行啟用指令。

這兩個腳本管理 systemd；防火牆與雲端安全群組使用原有政策。SSH 連接埠來自 OpenSSH／socket 設定。

## SSH 設定檢測

需求：Bash、Python 3、OpenSSH server。以 root 執行可讀取受保護設定與 host keys。

```bash
sudo bash vps/check-ssh-config.sh
sudo bash vps/check-ssh-config.sh --user root --user ubuntu --addr 198.51.100.20 --host client.example.com --laddr 203.0.113.10 --lport 22
sudo bash vps/check-ssh-config.sh --config /etc/ssh/custom_sshd_config --user root --option 'PasswordAuthentication=no'
```

預設檢測 root 與呼叫 sudo 的帳號。來源及伺服器 IP／連接埠取自 `SSH_CONNECTION`；本機執行使用 `127.0.0.1` 與 `22`。`--host` 預設使用來源 IP；該參數決定 `Match Host` 的檢測條件。

報告內容：

- OS 名稱／版本與 OpenSSH 版本。
- `PasswordAuthentication`、`KbdInteractiveAuthentication`、`PubkeyAuthentication`、`AuthenticationMethods`。
- 公鑰必要性、SSH `password` 方法與 `keyboard-interactive` 路徑；包含多因素方法組合、PAM 裝置啟用狀態及 root 認證限制。PAM 的密碼／OTP 步驟由 PAM 模組定義。
- `PermitRootLogin`，以及 `AllowUsers` 是否將帳號範圍限定為 root。
- `AllowUsers`／`DenyUsers`／`AllowGroups`／`DenyGroups`、公鑰路徑、PAM、GSSAPI、主機認證與強制指令。
- 生效值的設定檔與行號；內建預設及命令列覆寫使用來源標籤。
- `Include` 載入的檔案、重複宣告及 `Match` 條件的宣告清單。

OpenSSH 的 `sshd -ddd -T -C` 提供生效值及解析追蹤。純量選取適用 `Match` 區段的首個宣告，或全域首個宣告；使用者／群組清單採用適用區段的累加結果。`ChallengeResponseAuthentication` 對應 `KbdInteractiveAuthentication`。

檢測範圍是磁碟設定與報告顯示的連線條件。自訂 daemon `-f`／`-o` 參數可透過 `--config`／`--option` 帶入。帳號停用、PAM、shell、金鑰檔案、網路與防火牆另行決定實際登入結果。腳本執行設定解析，保留 SSH 服務與設定內容。

## apt 工具

```bash
bash vps/install-tools.sh --list
bash vps/install-tools.sh --dry-run
sudo bash vps/install-tools.sh
```

| 類別 | 套件 |
| --- | --- |
| 下載、連線與同步 | ca-certificates、curl、wget、openssh-client、rsync |
| 編輯與終端 | git、jq、vim-tiny、nano、less、tmux、htop、tree、file |
| 壓縮與程序 | zip、unzip、tar、xz-utils、lsof、procps、psmisc |
| 網路診斷 | iproute2、iputils-ping、dnsutils、mtr-tiny、traceroute、tcpdump、netcat-openbsd、socat |
| 開發與簽章 | gnupg、python3、python3-pip、python3-venv、build-essential、shellcheck |

安裝流程更新 apt 索引，安裝上表套件及相依套件，略過推薦套件。`--list` 印出套件名稱；`--dry-run` 使用現有套件索引模擬安裝。索引更新或安裝失敗時回傳錯誤狀態。套件來源沿用系統 apt 設定。

## 驗證

`python3 vps/tests/test_vps.py` 執行隔離測試：systemctl／apt 使用替身；SSH 檢測使用本機 OpenSSH、暫存 host key 及設定檔。測試程式使用 `unshare -Ur` 驗證 root 分支。

參考：[OpenSSH 設定](https://man.openbsd.org/sshd_config)、[sshd 檢測模式](https://man.openbsd.org/sshd)、[systemctl](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html)、[Ubuntu socket activation](https://documentation.ubuntu.com/release-notes/24.04/)、[apt-get](https://manpages.debian.org/trixie/apt/apt-get.8.en.html)。
