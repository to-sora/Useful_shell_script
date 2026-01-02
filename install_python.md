# 🐍 Python Multi-Version + Conda Bootstrapper

一鍵式在 **Ubuntu** 系統上安裝多版本 Python（Build from Source）+ Conda（Miniforge）開發環境。  

## 📦 安裝內容

| 類型     | 說明                                         |
|----------|----------------------------------------------|
| Python   | 3.8.19, 3.10.18, 3.11.13（源碼編譯）           |
| Conda    | Miniforge 25.9.1-0，自動初始化 `.bashrc`     |
| Shims    | 自動產生 `py38`, `py10`, `py11`, `cbase`, `cenv` 等指令入口 |
| Cache    | 自動配置 HuggingFace / pip / torch / ollama 等目錄 |

---

## ⚙️ 系統需求

- 作業系統：Ubuntu 20.04 或更新版本
- 套件工具：`sudo`, `curl`, `gcc`, `make`, `gpg`, `tar` 等（可自動安裝）

bash bootstrap.sh /path/to/my_env
```

### 進階選項

| 參數         | 說明                              |
|--------------|-----------------------------------|
| `--reuse`     | 若目錄已存在則重用，不重新初始化 |
| `--skip-apt`  | 不執行 `apt install`             |
| `--skip-gpg`  | 不驗證 Python PGP 簽章 |

---

## 🧪 使用方法

### 🔢 啟用特定 Python 版本

```bash
/path/to/my_env/bin/py38      # 啟用 Python 3.8 環境
/path/to/my_env/bin/py10      # 啟用 Python 3.10 環境
/path/to/my_env/bin/py11      # 啟用 Python 3.11 環境
```

這些會開啟一個新 shell，`python` 和 `pip` 將對應正確版本。

也可直接執行：

```bash
py11 python my_script.py
py38 pip install -r requirements.txt
```

---

### 📦 使用 Conda

```bash
/path/to/my_env/bin/cbase          # 啟動 base conda 環境
/path/to/my_env/bin/cenv myenv     # 啟動指定 conda 環境
/path/to/my_env/bin/cenv myenv jupyter lab
```

#### 📌 注意事項

- `conda init` 已自動執行（**無需手動設定 shell**）
- 為防止污染系統環境，腳本會自動在 `~/.bashrc` 中加入：
  ```bash
  conda deactivate
  ```
  保證登入時 Conda 不會強制啟用 base 環境。

---

## 📁 環境目錄結構

```
my_env/
├── bin/            # 所有入口指令 py38/py11/cenv/cbase
├── opt/            # 安裝好的 Python 與 Conda
├── src/            # Python 原始碼
├── CACHE/
│   ├── pip/        # pip 快取
│   ├── hf/         # HuggingFace 快取
│   ├── conda/      # Conda 快取 + 設定
│   └── tmp/        # 暫存檔案
```

---

## 🧼 移除環境

```bash 
sudo rm -rf /path/to/my_env
```
And remember clear .bashrc
---

## ❓常見問題

### Q: 可以在 WSL2 或 Debian 上用嗎？  
目前腳本僅支援 Ubuntu，其餘請修改 `detect_ubuntu()` 判斷。

### Q: 安裝中斷後重跑會怎樣？  
加上 `--reuse` 可略過已完成步驟（如下載與編譯）。

---

## 📄 License

MIT License — Free to use and modify.
