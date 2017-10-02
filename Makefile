#!/bin/sh

STAGINGDIR?=/tmp/ceres-base
STAGINGIMAGE?=/tmp/ceres-base.img
STAGINGIMAGESIZE?=1G
STAGINGSQUASHIMAGE?=/tmp/ceres-base.squash.img
STATICMOUNTDIR?=/mnt/ceres-base.img
PERSISTMOUNTDIR?=/mnt/ceres-persist.img

TARGETARCH?=$(shell dpkg --print-architecture)
TARGETKERNEL?=linux-image-$(TARGETARCH)

DEFAULTPKGS?=iproute2,bird,dnsmasq,python3,python3-pip,python3-setuptools,python3-wheel,iptables,sudo,nano,iputils-ping,net-tools
BUILDPKGS?=busybox-static,make

RELEASE=$(shell cat metadata/release)
VERSION=$(shell cat metadata/version)
BUILD=$(shell printf '.%04g' `git rev-list --count HEAD 2>/dev/null` || echo "")

define progress_out
	@echo "\033[1;33m*** $(1) ***\033[0m"
endef

define success_out
	@echo "\033[1;92m*** $(1) ***\033[0m"
endef

define error_out
	 @echo "\033[1;91m*** $(1) ***\033[0m"
endef

all:
	@make build || make error

ifeq ($(TARGETARCH), $(shell dpkg --print-architecture))
build: preflight prepare-image mount-lo bootstrap-native squash squash-stage unmount-lo postflight complete
else
QEMU?=/usr/bin/qemu-$(TARGETARCH)-static
build: preflight prepare-image mount-lo bootstrap-foreign squash squash-stage unmount-lo postflight complete
endif

prereqs:
ifneq ($(TARGETARCH), $(shell dpkg --print-architecture))
ifeq (,$(wildcard $(QEMU)))
    $(error $(QEMU) not present, install qemu-user-static)
endif
endif

bootstrap-common: mount-special stage4 stage5 stage6 stage7 bootloader unmount-special

bootstrap-native: stage1-native stage2-native stage3-native bootstrap-common
bootstrap-foreign: stage1-foreign stage2-foreign stage3-foreign bootstrap-common

preflight:
	$(call progress_out,Preflight)
	mkdir -p $(STAGINGDIR)

postflight:
	$(call progress_out,Postflight)
	rm -rf $(STAGINGDIR)
	tar -C $(shell dirname $(STAGINGIMAGE))/ -cJf $(STAGINGIMAGE).tar.xz $(shell basename $(STAGINGIMAGE))
	qemu-img convert -O vmdk $(STAGINGIMAGE) $(STAGINGIMAGE).vmdk

complete:
	$(call success_out,Build complete)
	@echo "Standard image at $(STAGINGIMAGE)"
	@echo "Compressed image at $(STAGINGIMAGE).tar.xz"
	@echo "VMware VMDK image at $(STAGINGIMAGE).vmdk"
	@echo "Squashfs file at $(STAGINGSQUASHIMAGE)"

error:
	$(call error_out,Build failed)

mount-special:
	$(call progress_out,Mount special filesystems in ${STAGINGDIR})
	mount --bind /proc $(STAGINGDIR)/proc
	mount --bind /dev $(STAGINGDIR)/dev
	mount --bind /sys $(STAGINGDIR)/sys

unmount-special:
	$(call progress_out,Unmount special filesystems from ${STAGINGDIR})
	umount -f $(STAGINGDIR)/proc
	umount -f $(STAGINGDIR)/dev
	umount -f $(STAGINGDIR)/sys

prepare-image:
	$(call progress_out,Prepare disk image ${STAGINGIMAGE})
	touch $(STAGINGIMAGE)
	fallocate -l ${STAGINGIMAGESIZE} $(STAGINGIMAGE)
	$(call progress_out,Partition disk image ${STAGINGIMAGE})
	parted -s $(STAGINGIMAGE) -- mklabel msdos mkpart primary ext4 1m 65m mkpart primary 65m 257m mkpart primary 257m 100% toggle 1 boot
	modprobe loop

mount-lo:
	$(call progress_out,Mount disk image ${STAGINGIMAGE})
	mkdir -p $(STATICMOUNTDIR)
	mkdir -p $(PERSISTMOUNTDIR)
	$(eval LOOP=$(shell losetup --show -f $(STAGINGIMAGE)))
	partprobe $(LOOP)
	mkfs.ext4 -F -O ^64bit $(LOOP)p1
	mkfs.ext4 -F -O ^64bit $(LOOP)p3
	mount $(LOOP)p1 $(STATICMOUNTDIR)
	mount $(LOOP)p3 $(PERSISTMOUNTDIR)

unmount-lo:
	$(call progress_out,Unmount disk image ${STAGINGIMAGE})
	umount -d $(STATICMOUNTDIR)
	umount -d $(PERSISTMOUNTDIR)
	sleep 1
	rm -rf $(STATICMOUNTDIR)
	rm -rf $(PERSISTMOUNTDIR)

stage1-native:
	$(call progress_out,Run Stage 1 (Native))
	debootstrap --foreign --variant=minbase \
		--include $(TARGETKERNEL),sysvinit-core,$(DEFAULTPKGS),$(BUILDPKGS) \
		stretch $(STAGINGDIR) http://ftp.uk.debian.org/debian/
	sed -i -e 's/systemd systemd-sysv libpamsystemd libsystemd0 //g' $(STAGINGDIR)/debootstrap/required

stage1-foreign:
	$(call progress_out,Run Stage 1 (Foreign))
	debootstrap --foreign --variant=minbase \
		--include $(TARGETKERNEL),sysvinit-core,$(DEFAULTPKGS),$(BUILDPKGS) \
		--arch=$(TARGETARCH) \
		stretch $(STAGINGDIR) http://ftp.uk.debian.org/debian/
	sed -i -e 's/systemd systemd-sysv libpamsystemd libsystemd0 //g' $(STAGINGDIR)/debootstrap/required

stage2-native:
	$(call progress_out,Run Stage 2 (Native))
	DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
		LC_ALL=C LANGUAGE=C LANG=C chroot $(STAGINGDIR) /debootstrap/debootstrap --second-stage

stage2-foreign:
	$(call progress_out,Run Stage 2 (Foreign))
	cp $(QEMU) $(STAGINGDIR)/usr/bin/
	DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
		LC_ALL=C LANGUAGE=C LANG=C chroot $(STAGINGDIR) /debootstrap/debootstrap --second-stage

stage3-native:
	$(call progress_out,Run Stage 3 (Native))
	DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
		LC_ALL=C LANGUAGE=C LANG=C chroot $(STAGINGDIR) dpkg --configure -a

stage3-foreign:
	$(call progress_out,Run Stage 3 (Foreign))
	DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
		LC_ALL=C LANGUAGE=C LANG=C chroot $(STAGINGDIR) dpkg --configure -a

stage4:
	$(call progress_out,Run Stage 4)
	$(call progress_out,Install ceres-initrd)
	rm -rf $(STAGINGDIR)/tmp/ceres-initrd
	git clone --depth 1 git@gitlab.com:ceres/ceres-initrd.git $(STAGINGDIR)/tmp/ceres-initrd || true
	chroot $(STAGINGDIR) bash -c "cd /tmp/ceres-initrd/; rm -rf .git; make install"

stage5:
	$(call progress_out,Run Stage 5)
	echo "export PATH=/opt/ceres/sbin:$$PATH" > $(STAGINGDIR)/etc/profile.d/ceres-shell.sh
	echo "ceres $(RELEASE)-$(VERSION)$(BUILD)\n\nImage built on `date`\n" > $(STAGINGDIR)/etc/issue
	echo "ceres-base" > $(STAGINGDIR)/etc/hostname
	chroot $(STAGINGDIR) useradd -m ceres
	chroot $(STAGINGDIR) useradd -m ceres-cfg
	echo "root:root" | chroot $(STAGINGDIR) chpasswd
	echo "ceres:ceres" | chroot $(STAGINGDIR) chpasswd

stage6:
	$(call progress_out,Run Stage 6)
	chroot $(STAGINGDIR) pip3 install flask
	chroot $(STAGINGDIR) pip3 install pyaml
	chroot $(STAGINGDIR) pip3 install requests
	$(call progress_out,Installing from repos)
	for repo in `cat metadata/repos`; \
	do \
		git clone $$repo /tmp/`basename $$repo`; \
		cd /tmp/`basename $$repo`; \
		STAGINGDIR="$(STAGINGDIR)" make install; \
		cd ..; \
		rm -rf /tmp/`basename $$repo`; \
	done

stage7:
	$(call progress_out,Run Stage 7)
	rm -rf $(STAGINGDIR)/*.old $(STAGINGDIR)/vmlinuz $(STAGINGDIR)/initrd.img
	$(call progress_out,Remove temporary build packages)
	chroot $(STAGINGDIR) $(QEMU) /usr/bin/apt-get -y purge `echo $(BUILDPKGS) | tr ',' ' '`
	chroot $(STAGINGDIR) $(QEMU) /usr/bin/apt-get -y autoremove
	chroot $(STAGINGDIR) $(QEMU) /usr/bin/apt-get -y clean
	$(call progress_out,Remove unwanted startup tasks)
	chroot $(STAGINGDIR) update-rc.d -f mountall-bootclean.sh remove
	chroot $(STAGINGDIR) update-rc.d -f mountall.sh remove
	rm -rf $(STAGINGDIR)/etc/init.d/mountall.sh
	rm -rf $(STAGINGDIR)/etc/init.d/mountall-bootclean.sh
#	rm -rf $(STAGINGDIR)/usr/bin/qemu-*

bootloader:
	$(call progress_out,Configure bootloader)
	if [ "$(TARGETARCH)" = "amd64" ] || [ "$(TARGETARCH)" = "i386" ]; \
	then \
		echo "default linux" > $(STAGINGDIR)/boot/extlinux.conf; \
		echo "prompt 0" >> $(STAGINGDIR)/boot/extlinux.conf; \
		echo "timeout 0" >> $(STAGINGDIR)/boot/extlinux.conf; \
		echo "" >> $(STAGINGDIR)/boot/extlinux.conf; \
		echo "label linux" >> $(STAGINGDIR)/boot/extlinux.conf; \
		echo "kernel /$(shell ls $(STAGINGDIR)/boot/vmlinuz* | tr '/' '\n' | tail -1)" >> $(STAGINGDIR)/boot/extlinux.conf; \
		echo "initrd /ceres-init.cpio.gz" >> $(STAGINGDIR)/boot/extlinux.conf; \
#		echo "initrd /boot/$(shell ls $(STAGINGDIR)/boot/initrd* | tr '/' '\n' | tail -1)" >> $(STAGINGDIR)/boot/extlinux.conf; \
		echo "append root=/dev/sda2 rootfstype=squashfs ro" >> $(STAGINGDIR)/boot/extlinux.conf; \
		mkdir -p $(STATICMOUNTDIR)/boot; \
		extlinux --install $(STATICMOUNTDIR)/boot --device=$(LOOP)p1; \
		dd if=/usr/lib/syslinux/mbr/mbr.bin of=$(LOOP) conv=notrunc; \
	fi

squash:
	$(call progress_out,Create squashfs ${STAGINGSQUASHIMAGE})
	mksquashfs $(STAGINGDIR) $(STAGINGSQUASHIMAGE) -noappend -e "boot"

squash-stage:
	$(call progress_out,Copy squashfs into ${STAGINGIMAGE})
	cp -r $(STAGINGDIR)/boot/* $(STATICMOUNTDIR)/
#	cp -r $(STAGINGSQUASHIMAGE) $(STATICMOUNTDIR)/boot/
	dd if=$(STAGINGSQUASHIMAGE) of=$(LOOP)p2
	rm -rf $(STAGINGDIR)/boot

clean:
	$(call progress_out,Unmount special filesystems and loopbacks)
	while [ `mount | grep $(STAGINGDIR)/dev | wc -l` -gt 0 ]; do umount $(STAGINGDIR)/dev; done
	while [ `mount | grep $(STAGINGDIR)/sys | wc -l` -gt 0 ]; do umount $(STAGINGDIR)/sys; done
	while [ `mount | grep $(STAGINGDIR)/proc | wc -l` -gt 0 ]; do umount $(STAGINGDIR)/proc; done
	while [ `mount | grep $(STATICMOUNTDIR)/dev | wc -l` -gt 0 ]; do umount $(STATICMOUNTDIR)/dev; done
	while [ `mount | grep $(STATICMOUNTDIR)/sys | wc -l` -gt 0 ]; do umount $(STATICMOUNTDIR)/sys; done
	while [ `mount | grep $(STATICMOUNTDIR)/proc | wc -l` -gt 0 ]; do umount $(STATICMOUNTDIR)/proc; done
	while [ `mount | grep $(STATICMOUNTDIR) | wc -l` -gt 0 ]; do umount $(STATICMOUNTDIR); done
	while [ `mount | grep $(PERSISTMOUNTDIR) | wc -l` -gt 0 ]; do umount $(PERSISTMOUNTDIR); done
	while [ `mount | grep $(STAGINGDIR) | wc -l` -gt 0 ]; do umount $(STAGINGDIR); done
	@sleep 2
	$(call progress_out,Cleanup files and folders)
	rm -rf $(STAGINGDIR)
	rm -rf $(STATICMOUNTDIR)
	rm -rf $(PERSISTMOUNTDIR)
	rm -rf $(STAGINGIMAGE)
	rm -rf $(STAGINGSQUASHIMAGE)
	$(call success_out,Cleanup complete)
