#!/bin/sh
xrun \
    -64bit \
    -makelib vlib \
        ../rtl/rsa_core.v \
        ../rtl/rsa_core_tb.v \
    -endlib \
    -top vlib.rsa_core_tb \
    -l logs/xrun_vlog.log \
    -history_file logs/xrun.history \
    -xmlibdirname xcelium.d
