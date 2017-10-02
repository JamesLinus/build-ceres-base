# build-ceres-base

## Building

Start on a Debian/Ubuntu/Devuan system. Install dependencies:
```
sudo apt-get install git make debootstrap parted qemu-system qemu-user-static squashfs-tools extlinux
```

Then clone the repository:
```
git clone https://github.com/ceres/build-ceres-base.git
```

Then build:
```
cd build-ceres
sudo make
```

On Azure the temporary disk may provide better build performance, especially if backed by an SSD:
```
cd build-ceres
sudo make STAGINGIMAGE=/mnt/resource/ceres-base.img STAGINGDIR=/mnt/resource/ceres-base STAGINGSQUASHIMAGE=/mnt/resource/ceres-base.squash.img
```

The build process produces two files: `ceres-base.img` (an ext4 filesystem) and `ceres-base.squash.img` (a squashfs filesystem).

## Running the image in qemu

You can invoke qemu to run from the ext4 image as follows:
```
qemu-system-x86_64 -vnc :0 -hda /tmp/ceres-base.img
```

Then use a VNC viewer to connect to screen :0 on the machine that qemu is running on.

### Port forwarding in PuTTY

In the event that you are SSHing to the remote server rather than running `qemu` locally, you can use SSH port forwarding to remotely access the VNC port securely.

For example, when connecting using PuTTY:

- Navigate to "Connection", "SSH" and then "Tunnels"
- Under "Add new forwarded port":
    - Enter `5900` into "Source Port"
    - Enter `127.0.0.1:5900` into "Destination"
    - Click "Add"
- Connect as normal

You can then point your VNC client to `127.0.0.1:5900` as the local port will be forwarded to the remote server.
