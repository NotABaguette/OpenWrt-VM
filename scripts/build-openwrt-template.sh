#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://downloads.openwrt.org}"
REQUESTED_VERSION="${OPENWRT_VERSION_INPUT:-${OPENWRT_VERSION:-latest}}"
IMAGE_VARIANT="${IMAGE_VARIANT:-efi}"
DISK_SIZE="${DISK_SIZE:-4G}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
WORK_DIR="${WORK_DIR:-work}"
VM_NAME="${VM_NAME:-OpenWrt}"
VM_NETWORK="${VM_NETWORK:-VM Network}"
VM_CPUS="${VM_CPUS:-2}"
VM_MEMORY_MB="${VM_MEMORY_MB:-512}"
VM_HW_VERSION="${VM_HW_VERSION:-vmx-13}"
NIC_MODEL="${NIC_MODEL:-E1000e}"
SCSI_MODEL="${SCSI_MODEL:-lsilogic}"

case "${IMAGE_VARIANT}" in
  efi|bios) ;;
  *) echo "ERROR: IMAGE_VARIANT must be either 'efi' or 'bios'." >&2; exit 2 ;;
esac

rm -rf "${WORK_DIR}" "${OUTPUT_DIR}"
mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

log() {
  printf '\n==> %s\n' "$*"
}

discover_latest_stable() {
  python3 - "$BASE_URL" <<'PY'
import re
import sys
import urllib.request

base = sys.argv[1].rstrip('/')
html = urllib.request.urlopen(base + '/', timeout=30).read().decode('utf-8', errors='replace')
# The OpenWrt downloads index lists the current Stable Release before Old Stable Release.
match = re.search(r'href="(?:\./)?releases/([0-9]+\.[0-9]+\.[0-9]+)/', html)
if not match:
    match = re.search(r'releases/([0-9]+\.[0-9]+\.[0-9]+)/', html)
if not match:
    raise SystemExit('Could not discover latest stable OpenWrt version from downloads index')
print(match.group(1))
PY
}

if [[ "${REQUESTED_VERSION}" == "latest" ]]; then
  OPENWRT_VERSION="$(discover_latest_stable)"
  CHANNEL="release"
elif [[ "${REQUESTED_VERSION}" == "snapshot" ]]; then
  OPENWRT_VERSION="snapshot-$(date -u +%Y%m%d)"
  CHANNEL="snapshot"
else
  OPENWRT_VERSION="${REQUESTED_VERSION}"
  CHANNEL="release"
fi

if [[ "${CHANNEL}" == "snapshot" ]]; then
  TARGET_URL="${BASE_URL}/snapshots/targets/x86/64"
  IMAGE_PREFIX="openwrt-x86-64"
else
  TARGET_URL="${BASE_URL}/releases/${OPENWRT_VERSION}/targets/x86/64"
  IMAGE_PREFIX="openwrt-${OPENWRT_VERSION}-x86-64"
fi

if [[ "${IMAGE_VARIANT}" == "efi" ]]; then
  IMAGE_NAME="${IMAGE_PREFIX}-generic-ext4-combined-efi.img.gz"
  FIRMWARE="efi"
else
  IMAGE_NAME="${IMAGE_PREFIX}-generic-ext4-combined.img.gz"
  FIRMWARE="bios"
fi

IMAGE_URL="${TARGET_URL}/${IMAGE_NAME}"
SHA_URL="${TARGET_URL}/sha256sums"
BASE_ARTIFACT="openwrt-${OPENWRT_VERSION}-x86_64-${IMAGE_VARIANT}"
RAW_IMG="${WORK_DIR}/${BASE_ARTIFACT}.img"
RAW_GZ="${WORK_DIR}/${IMAGE_NAME}"
VMDK_NAME="${BASE_ARTIFACT}.vmdk"
OVF_NAME="${BASE_ARTIFACT}.ovf"
MF_NAME="${BASE_ARTIFACT}.mf"
OVA_NAME="${BASE_ARTIFACT}.ova"
ISO_NAME="${BASE_ARTIFACT}-bundle.iso"

log "OpenWrt version: ${OPENWRT_VERSION}"
log "Target URL: ${TARGET_URL}"
log "Image: ${IMAGE_NAME}"

log "Downloading image and checksums"
curl -fL --retry 5 --retry-delay 5 -o "${WORK_DIR}/sha256sums" "${SHA_URL}"
curl -fL --retry 5 --retry-delay 5 -o "${RAW_GZ}" "${IMAGE_URL}"

log "Verifying SHA256"
(
  cd "${WORK_DIR}"
  grep -F "${IMAGE_NAME}" sha256sums | sha256sum -c -
)

log "Decompressing image"
gzip -dc "${RAW_GZ}" > "${RAW_IMG}"

if [[ -n "${DISK_SIZE}" ]]; then
  log "Expanding raw virtual disk container to ${DISK_SIZE}"
  qemu-img resize -f raw "${RAW_IMG}" "${DISK_SIZE}"
fi

DISK_CAPACITY_BYTES="$(qemu-img info --output=json "${RAW_IMG}" | jq -r '."virtual-size"')"

log "Converting raw image to streamOptimized VMDK"
qemu-img convert -p -f raw -O vmdk \
  -o subformat=streamOptimized,adapter_type=lsilogic \
  "${RAW_IMG}" "${WORK_DIR}/${VMDK_NAME}"

VMDK_SIZE_BYTES="$(stat -c '%s' "${WORK_DIR}/${VMDK_NAME}")"

log "Writing OVF descriptor"
cat > "${WORK_DIR}/${OVF_NAME}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope
  xmlns="http://schemas.dmtf.org/ovf/envelope/1"
  xmlns:cim="http://schemas.dmtf.org/wbem/wscim/1/common"
  xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
  xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
  xmlns:vmw="http://www.vmware.com/schema/ovf"
  xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <References>
    <File ovf:href="${VMDK_NAME}" ovf:id="file1" ovf:size="${VMDK_SIZE_BYTES}" />
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="${DISK_CAPACITY_BYTES}" ovf:capacityAllocationUnits="byte" ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized" />
  </DiskSection>
  <NetworkSection>
    <Info>Logical networks</Info>
    <Network ovf:name="${VM_NETWORK}">
      <Description>Attach this network to your ESXi port group.</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="${VM_NAME}">
    <Info>OpenWrt x86_64 VMware virtual machine</Info>
    <Name>${VM_NAME}</Name>
    <OperatingSystemSection ovf:id="100" vmw:osType="other3xLinux64Guest">
      <Info>Guest operating system</Info>
      <Description>Other Linux 3.x or later kernel 64-bit</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${VM_NAME}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>${VM_HW_VERSION}</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:Description>Number of virtual CPUs</rasd:Description>
        <rasd:ElementName>${VM_CPUS} virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>${VM_CPUS}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory size</rasd:Description>
        <rasd:ElementName>${VM_MEMORY_MB}MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>${VM_MEMORY_MB}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Description>SCSI Controller</rasd:Description>
        <rasd:ElementName>SCSI Controller 0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>${SCSI_MODEL}</rasd:ResourceSubType>
        <rasd:ResourceType>6</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>Hard disk 1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>7</rasd:AddressOnParent>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>${VM_NETWORK}</rasd:Connection>
        <rasd:Description>Ethernet adapter</rasd:Description>
        <rasd:ElementName>Network adapter 1</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>${NIC_MODEL}</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
      <vmw:Config ovf:required="false" vmw:key="firmware" vmw:value="${FIRMWARE}" />
    </VirtualHardwareSection>
    <AnnotationSection>
      <Info>Build notes</Info>
      <Annotation>OpenWrt ${OPENWRT_VERSION} x86_64 ${IMAGE_VARIANT} image converted from ${IMAGE_URL}. Default OpenWrt LAN IP is usually 192.168.1.1. Set a root password after first boot.</Annotation>
    </AnnotationSection>
  </VirtualSystem>
</Envelope>
EOF

log "Writing OVF manifest"
(
  cd "${WORK_DIR}"
  sha256sum "${OVF_NAME}" "${VMDK_NAME}" | awk '{print "SHA256(" $2 ")= " $1}' > "${MF_NAME}"
)

log "Creating OVA"
# OVF should be the first file inside an OVA archive.
tar -C "${WORK_DIR}" -cvf "${WORK_DIR}/${OVA_NAME}" "${OVF_NAME}" "${MF_NAME}" "${VMDK_NAME}"

log "Creating ISO artifact bundle"
ISO_DIR="${WORK_DIR}/iso"
mkdir -p "${ISO_DIR}"
cp "${WORK_DIR}/${OVF_NAME}" "${WORK_DIR}/${MF_NAME}" "${WORK_DIR}/${VMDK_NAME}" "${ISO_DIR}/"
cat > "${ISO_DIR}/README.txt" <<EOF
OpenWrt VMware template bundle
==============================

OpenWrt version: ${OPENWRT_VERSION}
Image variant:   ${IMAGE_VARIANT}
Source URL:      ${IMAGE_URL}

This ISO is an artifact bundle for offline transfer. It is not an OpenWrt installer ISO.
For ESXi/vCenter, import the .ova, or import the .ovf with the .vmdk beside it.

Default OpenWrt notes:
- First boot LAN IP is usually 192.168.1.1.
- Login as root with no password on a fresh upstream image, then immediately set a password.
- Review NIC mapping before using this VM as a router.
EOF
xorriso -as mkisofs -r -J -V OPENWRT_VM -o "${WORK_DIR}/${ISO_NAME}" "${ISO_DIR}" >/dev/null

log "Copying release assets"
cp "${RAW_GZ}" "${OUTPUT_DIR}/${IMAGE_NAME}"
cp "${WORK_DIR}/${OVF_NAME}" "${OUTPUT_DIR}/"
cp "${WORK_DIR}/${MF_NAME}" "${OUTPUT_DIR}/"
cp "${WORK_DIR}/${VMDK_NAME}" "${OUTPUT_DIR}/"
cp "${WORK_DIR}/${OVA_NAME}" "${OUTPUT_DIR}/"
cp "${WORK_DIR}/${ISO_NAME}" "${OUTPUT_DIR}/"

cat > "${OUTPUT_DIR}/metadata.json" <<EOF
{
  "openwrt_version": "${OPENWRT_VERSION}",
  "requested_version": "${REQUESTED_VERSION}",
  "channel": "${CHANNEL}",
  "image_variant": "${IMAGE_VARIANT}",
  "source_url": "${IMAGE_URL}",
  "sha256sums_url": "${SHA_URL}",
  "disk_capacity_bytes": ${DISK_CAPACITY_BYTES},
  "vm_name": "${VM_NAME}",
  "vm_network": "${VM_NETWORK}",
  "vm_cpus": ${VM_CPUS},
  "vm_memory_mb": ${VM_MEMORY_MB},
  "vm_hw_version": "${VM_HW_VERSION}",
  "nic_model": "${NIC_MODEL}",
  "firmware": "${FIRMWARE}"
}
EOF

if [[ "${CHANNEL}" == "snapshot" ]]; then
  RELEASE_TAG="openwrt-${OPENWRT_VERSION}-${IMAGE_VARIANT}"
else
  RELEASE_TAG="openwrt-${OPENWRT_VERSION}-${IMAGE_VARIANT}"
fi

cat > "${OUTPUT_DIR}/metadata.env" <<EOF
OPENWRT_VERSION=${OPENWRT_VERSION}
REQUESTED_VERSION=${REQUESTED_VERSION}
CHANNEL=${CHANNEL}
IMAGE_VARIANT=${IMAGE_VARIANT}
RELEASE_TAG=${RELEASE_TAG}
SOURCE_URL=${IMAGE_URL}
EOF

cat > "${OUTPUT_DIR}/release-notes.md" <<EOF
# OpenWrt ${OPENWRT_VERSION} x86_64 ${IMAGE_VARIANT} VMware template

Built from the official OpenWrt image:

- Source: \`${IMAGE_URL}\`
- SHA256 verified against: \`${SHA_URL}\`
- Variant: \`${IMAGE_VARIANT}\`
- Virtual disk capacity: \`${DISK_CAPACITY_BYTES} bytes\`

## Assets

- \`${OVA_NAME}\` — recommended for ESXi/vCenter import.
- \`${OVF_NAME}\` + \`${VMDK_NAME}\` — importable OVF pair.
- \`${ISO_NAME}\` — offline artifact bundle; this is not an installer ISO.
- \`${IMAGE_NAME}\` — original upstream compressed OpenWrt disk image.
- \`SHA256SUMS\` — checksums for release assets.

## First boot notes

- OpenWrt's default LAN IP is usually \`192.168.1.1\`.
- Fresh upstream OpenWrt images typically allow root login with no password on the local console/LAN. Set a password immediately.
- Review the ESXi port group and NIC order before using this VM as a router.
EOF

(
  cd "${OUTPUT_DIR}"
  sha256sum *.ova *.ovf *.vmdk *.iso *.img.gz *.json 2>/dev/null > SHA256SUMS
)

log "Done. Release assets:"
ls -lh "${OUTPUT_DIR}"
