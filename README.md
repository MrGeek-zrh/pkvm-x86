将pkvm-x86内核编译、打包的教程在 docker文件夹下，提供了开箱即用的docker环境。

打包deb包后，可以按照ubuntu24.04文件夹下的教程，将deb包安装到物理机上。为了保险起见，可以现在虚拟机中测试是否能安装并重启成功。

---
This is a pKVM-IA fork that makes the PKVM work with the full feature set
provided by the KVM. This includes working with non-modified system BIOSs,
Operating Systems and hardware flavors that do not support Virtualized
Exceptions (#VEs), including the KVM VCPU itself.

In addition, the goal is to provide multiple secure smm states via the
hypervisors help. The pkvm acts as a barrier to secure the system smm and
provides the guests a properly isolated smm state that the host cannot
access.

Beyond the basic functionality, the PKVM is extended with tools for guest
debugging and validation for any given set of virtual devices.
