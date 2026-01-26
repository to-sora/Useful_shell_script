
## 1. 在 Proxmox host 驗證：GPU 是否已綁定 `vfio-pci`

### 指令

```bash
lspci -nnk -s 01:00.0
lspci -nnk -s 01:00.1
```

### expected output

```text
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD102 [GeForce RTX 4090 D] [10de:2685] (rev a1)
	Subsystem: Gigabyte Technology Co., Ltd Device [1458:414b]
	Kernel driver in use: vfio-pci
	Kernel modules: nvidiafb, nouveau
01:00.1 Audio device [0403]: NVIDIA Corporation AD102 High Definition Audio Controller [10de:22ba] (rev a1)
	Subsystem: Gigabyte Technology Co., Ltd Device [1458:414b]
	Kernel driver in use: vfio-pci
	Kernel modules: snd_hda_intel
```

---

## 2. Fix GRUB（`/etc/default/grub`）

### Ensure line is

```text
GRUB_CMDLINE_LINUX_DEFAULT="pcie_aspm=off pcie_port_pm=off quiet amd_iommu=on iommu=pt"
```

### Then run

```bash
update-grub
reboot
```

---

## 3. 設定 `vfio-pci` Power Management

### Ensure file

`/etc/modprobe.d/vfio-pci.conf`
contain line

```text
options vfio-pci disable_idle_d3=1
```

### Then update

```bash
update-initramfs -u -k all
reboot
```

---

## 4. For guest agent

### Run

```bash
sudo bash -c 'echo on > /sys/bus/pci/devices/0000:01:00.0/power/control'
sudo bash -c 'echo on > /sys/bus/pci/devices/0000:02:00.0/power/control' 2>/dev/null || true
sudo nvidia-smi -pm 1
```

### If forever

```bash
sudo tee /etc/udev/rules.d/80-nvidia-runtimepm.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{power/control}="on"
EOF
sudo udevadm control --reload-rules
```

### Verify

```bash
cat /sys/bus/pci/devices/0000:01:00.0/power/control
```

---

## 5. Fix PCIe ASPM

### Run

```bash
echo performance | sudo tee /sys/module/pcie_aspm/parameters/policy
```

### Verify

```bash
cat /sys/module/pcie_aspm/parameters/policy
# expected output : [default] performance powersave powersupersave

lspci -vvv -s 01:00.0 | grep -iE 'LnkCap|LnkSta|LnkCtl'
lspci -vvv -s 00:01.1 | grep -iE 'LnkCap|LnkSta|LnkCtl'
cat /proc/cmdline
```

### One of valide output

```text
lspci -vvv -s 00:01.1 | grep -iE 'LnkCap|LnkSta|LnkCtl'
		LnkCap:	Port #0, Speed 16GT/s, Width x16, ASPM L1, Exit Latency L1 <4us
		LnkCtl:	ASPM L1 Enabled; RCB 64 bytes, LnkDisable- CommClk+
		LnkSta:	Speed 16GT/s, Width x16
		LnkCap2: Supported Link Speeds: 2.5-16GT/s, Crosslink- Retimer+ 2Retimers+ DRS-
		LnkCtl2: Target Link Speed: 16GT/s, EnterCompliance- SpeedDis-
		LnkSta2: Current De-emphasis Level: -3.5dB, EqualizationComplete+ EqualizationPhase1+
		LnkCtl3: LnkEquIntrruptEn- PerformEqu-
		LnkCap:	Port #0, Speed 16GT/s, Width x16, ASPM L1, Exit Latency L1 <64us
		LnkCtl:	ASPM L1 Enabled; RCB 64 bytes, LnkDisable- CommClk+
		LnkSta:	Speed 16GT/s, Width x16
		LnkCap2: Supported Link Speeds: 2.5-16GT/s, Crosslink- Retimer+ 2Retimers+ DRS-
		LnkCtl2: Target Link Speed: 16GT/s, EnterCompliance- SpeedDis-
		LnkSta2: Current De-emphasis Level: -3.5dB, EqualizationComplete+ EqualizationPhase1+
		LnkCtl3: LnkEquIntrruptEn- PerformEqu-
```

### Make persistence

```bash
sudo update-grub
sudo reboot
```

---

## 6. Manual PCIe Link Retrain（Executed）

```bash
PORT=00:01.1

# 讀目前 Link Control
OLD=$(setpci -s $PORT CAP_EXP+10.w)
echo "OLD=$OLD"

# 設 retrain bit (bit5 = 0x20)
NEW=$(printf "%04x" $(( 0x$OLD | 0x0020 )))
echo "NEW=$NEW"

# 寫回，觸發 retrain
setpci -s $PORT CAP_EXP+10.w=$NEW

# 等一陣
sleep 2

# 再檢查 link
lspci -vvv -s $PORT | grep -iE 'LnkCap|LnkCtl|LnkSta'
lspci -vvv -s 01:00.0 | grep -iE 'LnkCap|LnkCtl|LnkSta'
```


