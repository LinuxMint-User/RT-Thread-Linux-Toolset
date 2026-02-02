#!/bin/sh
openocd -f ./hotfix/openocd/stm32f4-stlink.cfg -c "program rt-thread.elf verify reset exit"
