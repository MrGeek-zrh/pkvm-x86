[ ] 透传给pVM的设备是怎么释放的
[ ] 设备在透传给pVM时，Host还能对设备的IOMMU页表做相关操作吗？

[ ] pVM销毁释放设备的时候，要先确保相关的内存数据情况后才能交还设备访问权给Host

[ ] allowlist的设计细化
    - 透传给pVM的设备要确实是在Host内核启动时识别到的真实PCI设备。
    

[ ] pVM运行过程中,Host有可能去改变IOMMU的一些关键寄存器吗? 当前只看到了pKVM会拦截Host对DMAR相关寄存器的访问

[ ] 在Host运行过程中热插给Host的设备，这里限制不允许再被进一步热插并直通给pVM




[ ] 透传设备给pVM的情况下，Host attach设备给pVM的时候，可能会给一个fake设备。