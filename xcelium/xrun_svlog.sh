#!/bin/sh
xrun \
    -64bit \
    -sv \
    -makelib svlib \
        ../rtl/rsa_core.sv \
        ../rtl/rsa_core_tb.sv \
    -endlib \
    -top svlib.rsa_core_tb \
    -l logs/xrun_svlog.log \
    -history_file logs/xrun.history \
    -xmlibdirname xcelium.d
