# OpenWrt ESXi OVA/OVF VMDK

Automatically builds VMware-friendly **OpenWrt x86_64 templates** from official OpenWrt images using GitHub Actions, then publishes the generated files to **GitHub Releases**.

> The `.iso` is **not** an OpenWrt installer ISO.
> It is only a bundle for easier uploading in some environments.

## Download

Open the repository’s **[Releases](https://github.com/NotABaguette/OpenWrt-VM/releases)** page and download the build you need.

For most users, download:

```text
.ova
```
The `.ova` file is the easiest option for ESXi and vCenter with bundled VMDK.

## Import into ESXi

In the ESXi Web UI:

```text
Virtual Machines
→ Create / Register VM
→ Deploy a virtual machine from an OVF or OVA file
```
## Scheduled builds

The workflow runs weekly and publishes updated assets to GitHub Releases.
```text
openwrt_version = latest
image_variant   = efi
disk_size       = 4G
```

## Local build

On Debian/Ubuntu:
```bash
sudo apt-get update
sudo apt-get install -y ca-certificates coreutils curl gzip jq qemu-utils tar xorriso
git clone https://github.com/NotABaguette/OpenWrt-VM.git
cd OpenWrt-VM
chmod +x scripts/build-openwrt-template.sh

OPENWRT_VERSION_INPUT=latest \
IMAGE_VARIANT=efi \
DISK_SIZE=4G \
scripts/build-openwrt-template.sh
```

## Configuration

Optional environment variables:

| Variable                |      Default |
| ----------------------- | -----------: |
| `OPENWRT_VERSION_INPUT` |     `latest` |
| `IMAGE_VARIANT`         |        `efi` |
| `DISK_SIZE`             |         `4G` |
| `VM_NAME`               |    `OpenWrt` |
| `VM_NETWORK`            | `VM Network` |
| `VM_CPUS`               |          `2` |
| `VM_MEMORY_MB`          |        `512` |
| `NIC_MODEL`             |     `E1000e` |
| `VM_HW_VERSION`         |     `vmx-13` |


## First boot

Default upstream OpenWrt behavior is usually:

```text
LAN IP: 192.168.1.1
User: root
Password: empty
```

## Notes

* The downloaded OpenWrt image is verified against OpenWrt checksums.
* Expanding the virtual disk does not automatically expand the OpenWrt root filesystem.
* For multi-NIC router use, import the VM first, then add NICs in ESXi.

## License

MIT
