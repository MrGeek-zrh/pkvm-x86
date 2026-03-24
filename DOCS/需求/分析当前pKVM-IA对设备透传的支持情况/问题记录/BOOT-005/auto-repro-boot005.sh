lspci -nn | rg 'Non-Volatile|NVMe'
cat /sys/class/nvme/nvme0/serial
# 找到透传的设备的BDF号
readlink -f /sys/class/nvme/nvme0/device
BDF=0000:01:00.0
sudo modprobe vfio-pci
sudo echo vfio-pci | sudo tee /sys/bus/pci/devices/$BDF/driver_override
sudo echo "$BDF" | sudo tee /sys/bus/pci/devices/$BDF/driver/unbind || true
echo "$BDF" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
lspci -nnk -s 01:00.0

# 不带vIOMMU
sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 ./scripts/run-crosvm.sh
# 带vIOMMU
# sudo PROTECTED=1 SETUP_NET=0 VFIO_DEV=0000:01:00.0 VFIO_IOMMU=viommu ./scripts/run-crosvm.sh