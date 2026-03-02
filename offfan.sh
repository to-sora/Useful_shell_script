#!/bin/bash
DISPLAY=:1 XAUTHORITY=/run/user/1000/gdm/Xauthority nvidia-settings \
  -a "[gpu:0]/GPUFanControlState=0"
