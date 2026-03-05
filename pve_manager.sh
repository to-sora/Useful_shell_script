
#!/bin/bash

# ==============================================================================
# PVE ADMIN MANAGER
# Wraps existing scripts for VM 100, 102, 103 and handles VM 200 Cloning.
# ==============================================================================

# Script Directory (Assume scripts are in ./vm_script relative to this file)
SCRIPT_DIR="$(dirname "$0")/vm_script"

# Helper Function: Pause for user
pause() {
    read -p "Press [Enter] to continue..."
}

# Helper Function: Check if script exists and run it
run_script() {
    local script_name=$1
    local full_path="$SCRIPT_DIR/$script_name"
    
    if [ -f "$full_path" ]; then
        echo ">> Executing: $script_name"
        # We call bash explicitly to run it
        bash "$full_path"
        if [ $? -eq 0 ]; then
            echo "✅ $script_name completed successfully."
        else
            echo "❌ $script_name FAILED."
            read -p "Press [Enter] to acknowledge error and continue..."
        fi
    else
        echo "❌ Error: Script not found at $full_path"
    fi
}

# ==============================================================================
# TASK 1: OFFLOAD DRIVES (Backup Mode)
# ==============================================================================
do_offload() {
    clear
    echo "=========================================="
    echo "   TASK 1: OFFLOAD DRIVES (MOUNT TO HOST)"
    echo "=========================================="
    echo "This will STOP VMs 100, 102, 103 and mount drives to /mnt/."
    echo ""
    
    # 1. VM 100 (Windows)
    read -p "Step 1/3: Stop VM 100 and Mount Drives? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        run_script "Unload_VM100.sh"
    else
        echo "Skipping VM 100."
    fi
    echo "------------------------------------------"

    # 2. VM 102 (Passthrough)
    read -p "Step 2/3: Stop VM 102 and Mount Drives? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        run_script "Unload_VM102.sh"
    else
        echo "Skipping VM 102."
    fi
    echo "------------------------------------------"

    # 3. VM 103 (Ubuntu)
    read -p "Step 3/3: Stop VM 103 and Mount Drives? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        run_script "Unload_VM103.sh"
    else
        echo "Skipping VM 103."
    fi

    echo ""
    echo "✅ Offload sequence finished."
    pause
}

# ==============================================================================
# TASK 2: RELOAD DRIVES (VM Mode)
# ==============================================================================
do_reload() {
    clear
    echo "=========================================="
    echo "   TASK 2: RELOAD DRIVES (RETURN TO VM)"
    echo "=========================================="
    echo "This will unmount drives from Host and re-attach to VMs."
    echo ""

    # 1. VM 100
    read -p "Step 1/3: Reload VM 100? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        run_script "Reload_VM100.sh"
    else
        echo "Skipping VM 100."
    fi
    echo "------------------------------------------"

    # 2. VM 102
    read -p "Step 2/3: Reload VM 102? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        run_script "Reload_VM102.sh"
    else
        echo "Skipping VM 102."
    fi
    echo "------------------------------------------"

    # 3. VM 103
    read -p "Step 3/3: Reload VM 103? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        run_script "Reload_VM103.sh"
    else
        echo "Skipping VM 103."
    fi

    echo ""
    echo "✅ Reload sequence finished."
    pause
}

# ==============================================================================
# TASK 3: CLONE VM 200
# ==============================================================================
# ==============================================================================
# TASK 3: CLONE VM 200
# ==============================================================================
do_clone_200() {
    clear
    echo "=========================================="
    echo "   TASK 3: CLONE VM 200 (Standard)"
    echo "=========================================="
    
    # Input: New VM ID
    while true; do
        read -p "Enter new VM ID (e.g. 201): " NEW_ID
        if [[ "$NEW_ID" =~ ^[0-9]+$ ]]; then
            if qm status $NEW_ID &>/dev/null; then
                echo "❌ Error: VM ID $NEW_ID already exists."
            else
                break
            fi
        else
            echo "❌ Invalid input. Numbers only."
        fi
    done

    # Input: Name
    read -p "Enter name for VM $NEW_ID: " NEW_NAME

    # Input: VLAN Tag
    while true; do
        echo "Available VLAN Tags: 20 (Win), 21 (Danger), 30 (Safe), 31 (Mgmt)"
        read -p "Select VLAN Tag: " VLAN_TAG
        case $VLAN_TAG in
            20|21|30|31) break ;;
            *) echo "❌ Invalid Tag. You must choose 20, 21, 30, or 31." ;;
        esac
    done

    # Input: Storage (New QCOW2 or Linked Clone?)
    echo "Storage Options for 'vm-os':"
    echo "  1) Full Clone (Independent - Safer, uses more space)"
    echo "  2) Linked Clone (Reference - Faster, saves space)"
    read -p "Select Option (1/2): " CLONE_TYPE
    
    FULL_CLONE_FLAG=""
    if [ "$CLONE_TYPE" == "1" ]; then
        FULL_CLONE_FLAG="--full 1"
        echo ">> Mode: Full Clone"
    else
        FULL_CLONE_FLAG="--full 0"
        echo ">> Mode: Linked Clone"
    fi

    # Confirmation
    echo ""
    echo "SUMMARY:"
    echo "  Source:      VM 200"
    echo "  Target ID:   $NEW_ID"
    echo "  Target Name: $NEW_NAME"
    echo "  VLAN Tag:    $VLAN_TAG"
    echo "  Bridge:      MAIN_br"
    echo ""
    read -p "Proceed with clone? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        pause
        return
    fi

    # Execution
    echo ">> Cloning VM 200 to $NEW_ID..."
    qm clone 200 $NEW_ID --name "$NEW_NAME" --storage vm-os $FULL_CLONE_FLAG
    
    if [ $? -ne 0 ]; then
        echo "❌ Clone Failed."
        pause
        return
    fi

    echo ">> Updating Network Config (VLAN $VLAN_TAG on MAIN_br)..."
    # This command sets the Bridge to MAIN_br, sets the VLAN, 
    # and auto-generates a NEW MAC address because we are redefining net0.
    qm set $NEW_ID --net0 virtio,bridge=MAIN_br,firewall=1,tag=$VLAN_TAG

    echo ""
    echo "✅ VM $NEW_ID created successfully."
    echo "⚠️  NEXT STEP: Start VM $NEW_ID and run './reset.sh $NEW_NAME' inside it!"
    pause
}




# ==============================================================================
# MAIN MENU
# ==============================================================================
while true; do
    clear
    echo "=========================================="
    echo "   PROXMOX ADMIN MANAGER"
    echo "=========================================="
    echo "1. Offload Drives (Mount to Host -> VM 100/102/103)"
    echo "2. Reload Drives (Attach to VM -> VM 100/102/103)"
    echo "3. Clone VM 200 (Create New Standard VM)"
    echo "4. Exit"
    echo "=========================================="
    read -p "Select Option: " choice

    case $choice in
        1) do_offload ;;
        2) do_reload ;;
        3) do_clone_200 ;;
        4) exit 0 ;;
        *) echo "Invalid option." ; pause ;;
    esac
done
