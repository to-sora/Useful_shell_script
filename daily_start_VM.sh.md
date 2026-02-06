# daily_start_VM.sh

```bash
#!/bin/bash

# ==============================================================================
# DAILY STARTUP CONTROLLER V7 (Multi-Net & Strict Audit)
# ==============================================================================

# --- CONFIGURATION ---
EXCLUSIVE_VMS=(100 102 103)
FORBIDDEN_VMS=(104 200) # Safety Stop & Hide
CORE_VM=106             # Infra (Exempt from VLAN Policy)
DENY_VM=107             # Hidden

# Allowed VLAN Tags (Define constants at top)
VALID_TAGS=" 10 11 20 21 30 31 "

# VLAN Policies (Switching Logic)
declare -A VLAN_GROUPS
VLAN_GROUPS["10"]="10,11"
VLAN_GROUPS["11"]="10,11"
VLAN_GROUPS["20"]="20,21"
VLAN_GROUPS["21"]="20,21"
VLAN_GROUPS["30"]="30,31"
VLAN_GROUPS["31"]="30,31"

# Expected Disk Counts
declare -A EXPECTED_DISKS
EXPECTED_DISKS["100"]=2
EXPECTED_DISKS["102"]=2
EXPECTED_DISKS["103"]=2

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GRAY='\033[1;30m'
# ALERT: Red Background (41), White Text (97), Bold (1)
ALERT='\033[1;41;97m'
NC='\033[0m'

get_vm_status() { qm status $1 2>/dev/null | awk '{print $2}'; }
get_vm_name() { grep "^name:" /etc/pve/qemu-server/$1.conf 2>/dev/null | awk '{print $2}'; }

# ==============================================================================
# PHASE 1: SAFETY CHECKS
# ==============================================================================
echo -e "${YELLOW}>> Phase 1: Safety Checks${NC}"
for vm in "${FORBIDDEN_VMS[@]}"; do
    if [ -f "/etc/pve/qemu-server/$vm.conf" ] && [ "$(get_vm_status $vm)" == "running" ]; then
        if [ "$vm" == "104" ]; then
            echo -e "${ALERT} CRITICAL: VM 104 is RUNNING! Exiting. ${NC}"; exit 1
        else
            echo -e "${RED}WARNING: VM $vm is RUNNING.${NC}"
            read -p "Stop VM $vm? (y/n): " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] && qm stop $vm || exit 1
        fi
    fi
    # Additional check to ensure VM 200 is stopped
    if [ "$vm" == "200" ] && [ "$(get_vm_status $vm)" == "running" ]; then
        echo -e "${RED}WARNING: VM 200 is running. It should not be running directly.${NC}"
        read -p "Stop VM 200? (y/n): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] && qm stop $vm || exit 1
    fi
done
echo -e "${GREEN}✅ Safety checks passed.${NC}"

# ==============================================================================
# PHASE 2: INFRASTRUCTURE
# ==============================================================================
echo -e "
${YELLOW}>> Phase 2: Infrastructure${NC}"
if [ -f "/etc/pve/qemu-server/$CORE_VM.conf" ] && [ "$(get_vm_status $CORE_VM)" != "running" ]; then
    read -p "Start Core VM $CORE_VM? (y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && qm start $CORE_VM
fi

if [ -f "/etc/pve/qemu-server/$DENY_VM.conf" ] && [ "$(get_vm_status $DENY_VM)" == "running" ]; then
    read -p "Stop Deny VM $DENY_VM? (y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && qm stop $DENY_VM
fi
echo -e "${GREEN}✅ Infrastructure ready.${NC}"

# ==============================================================================
# PHASE 3: GLOBAL VLAN AUDIT (Data Collection Mode)
# ==============================================================================
echo -e "
${YELLOW}>> Phase 3: Global VLAN Audit${NC}"

# Array to store table rows
declare -a REPORT_ROWS
ISSUE_FOUND=0

# Loop through ALL config files
for conf in /etc/pve/qemu-server/*.conf; do
    vmid=$(basename "$conf" .conf)
    name=$(grep "^name:" "$conf" | awk '{print $2}')
    
    # 1. Get ALL Network Interfaces (net0, net1, etc.)
    # We use grep to find all lines starting with net[0-9]
    net_lines=$(grep "^net[0-9]\+:" "$conf")
    
    # Default State
    vm_tags=""
    vm_status="${GREEN}OK${NC}"
    is_violation=0
    
    # EXCEPTION: VM 106 is always OK
    if [ "$vmid" == "$CORE_VM" ]; then
        vm_status="${GREEN}Infra OK${NC}"
        vm_tags="Any"
    elif [ -z "$net_lines" ]; then
        # VM has NO network cards
        vm_status="${GRAY}No-NIC${NC}"
        vm_tags="-"
    else
        # Check EACH Interface found
        while IFS= read -r line; do
            # Check Bridge
            if [[ "$line" != *"bridge=MAIN_br"* ]]; then
                is_violation=1
                vm_tags="${vm_tags} [Non-Main]"
            else
                # Extract Tag
                tag=$(echo "$line" | grep -o 'tag=[0-9]*' | cut -d= -f2)
                if [ -z "$tag" ]; then tag="Untagged"; fi
                
                # Check Valid List
                if [[ ! "$VALID_TAGS" =~ " $tag " ]]; then
                    is_violation=1
                    vm_tags="${vm_tags} [${tag}*]" # Mark bad tag with *
                else
                    vm_tags="${vm_tags} ${tag}"
                fi
            fi
        done <<< "$net_lines"
        
        if [ $is_violation -eq 1 ]; then
            vm_status="${ALERT} VIOLATE ${NC}"
            ISSUE_FOUND=1
        fi
    fi

    # Store Row
    # If VMID is small, pad name for alignment
    row=$(printf "%-6s %-20s %-20s %b" "$vmid" "$name" "${vm_tags:0:20}" "$vm_status")
    REPORT_ROWS+=("$row")
done

# --- PRINT TABLE ---
printf "%-6s %-20s %-20s %s
" "VMID" "NAME" "VLANs" "STATUS"
echo "----------------------------------------------------------------"
for row in "${REPORT_ROWS[@]}"; do
    echo -e "$row"
done
echo "----------------------------------------------------------------"

if [ $ISSUE_FOUND -ne 0 ]; then
    echo -e "${ALERT} WARNING: VLAN Policy violations detected above! ${NC}"
    read -p "Continue anyway? (y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
else
    echo -e "${GREEN}✅ All VMs comply with VLAN Policy.${NC}"
fi

# ==============================================================================
# PHASE 4: VM STARTUP SELECTION
# ==============================================================================
echo -e "
${YELLOW}>> Phase 4: Select VM to Start${NC}"

ALL_VMS=$(ls /etc/pve/qemu-server/*.conf | awk -F/ '{print $NF}' | sed 's/.conf//' | sort -n)

echo "Available VMs:"
for vm in $ALL_VMS; do
    # Hide Core/Forbidden/Deny from Start Menu
    if [[ " ${FORBIDDEN_VMS[*]} " =~ " ${vm} " ]] || [ "$vm" == "$DENY_VM" ] || [ "$vm" == "$CORE_VM" ]; then
        continue
    fi

    status=$(get_vm_status $vm)
    name=$(get_vm_name $vm)
    
    if [ "$status" == "running" ]; then
        echo -e "  [${GREEN}$vm${NC}] $name (running)"
    else
        echo -e "  [${NC}$vm${NC}] $name (stopped)"
    fi
done

echo ""
read -p "Enter VM ID to start: " TARGET_ID

# Validation
[[ ! "$TARGET_ID" =~ ^[0-9]+$ ]] && { echo "Invalid ID"; exit 1; }

# Exclusive VM Check
if [[ " ${EXCLUSIVE_VMS[*]} " =~ " ${TARGET_ID} " ]]; then
    echo -e "
${YELLOW}>> Checking Exclusive Resource Locks...${NC}"
    for other in "${EXCLUSIVE_VMS[@]}"; do
        if [ "$other" != "$TARGET_ID" ] && [ "$(get_vm_status $other)" == "running" ]; then
            echo -e "${ALERT} CONFLICT: VM $other is running! ${NC}"; exit 1
        fi
    done

    # Mount Verification
    req=${EXPECTED_DISKS[$TARGET_ID]}
    cur=$(grep -c "^scsi[1-9]:" /etc/pve/qemu-server/$TARGET_ID.conf)
    
    if [ "$cur" -lt "$req" ]; then
        echo -e "${ALERT} Missing Disks! Found $cur, Expected $req. ${NC}"
        read -p "Run Reload_VM$TARGET_ID.sh now? (y/n): " fix
        if [[ "$fix" =~ ^[Yy]$ ]]; then
            bash "$HOME/pve-admin/vm_script/Reload_VM$TARGET_ID.sh"
            cur=$(grep -c "^scsi[1-9]:" /etc/pve/qemu-server/$TARGET_ID.conf)
            [ "$cur" -lt "$req" ] && { echo "❌ Still failed."; exit 1; }
        else
            exit 1
        fi
    fi
    echo -e "${GREEN}✅ Resources ready.${NC}"
fi

# VLAN Switching
net_conf=$(grep "^net0:" /etc/pve/qemu-server/$TARGET_ID.conf)
cur_tag=$(echo "$net_conf" | grep -o 'tag=[0-9]*' | cut -d= -f2)
[ -z "$cur_tag" ] && cur_tag="Untagged"

echo -e "
Current VLAN: $cur_tag"
if [ -n "${VLAN_GROUPS[$cur_tag]}" ]; then
    opts=${VLAN_GROUPS[$cur_tag]}
    read -p "Switch VLAN? (Allowed: $opts) [Enter to keep]: " new_tag
    if [ -n "$new_tag" ]; then
        if [[ ",$opts," =~ ",$new_tag," ]]; then
            qm set $TARGET_ID --net0 virtio,bridge=MAIN_br,firewall=1,tag=$new_tag
        else
            echo -e "${ALERT} Denied. ${NC}"
        fi
    fi
fi

echo -e "
${GREEN}>> Starting VM $TARGET_ID...${NC}"
qm start $TARGET_ID
```
