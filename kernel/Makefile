# ddk 构建入口 (ddk build 在本目录执行 make, KDIR 由 ddk 镜像环境提供)
MODULE_NAME := opensesame
$(MODULE_NAME)-objs := opensesame.o
obj-m := $(MODULE_NAME).o

KDIR := $(KDIR)
MDIR := $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

all:
	make -C $(KDIR) M=$(MDIR) modules
clean:
	make -C $(KDIR) M=$(MDIR) clean
