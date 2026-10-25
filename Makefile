PYTHON ?= .venv/bin/python
VIVADO ?= vivado
WORK ?= $(CURDIR)/build/linux-cache
OUTPUT ?= build/hardware_next
JOBS ?= 12
LINUX_OUTPUT ?= build/linux_host_next
.PHONY: test lint hardware linux-configure linux linux-verify linux-archive linux-legal-info
test:
	$(PYTHON) -m pytest -q tests
lint:
	verilator --lint-only -Wall --top-module pcie_soft_link $(filter-out ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_gth.sv ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_root_port.sv,$(wildcard ip/soft_pcie_root/rtl/pcie_soft/*.sv))
	verilator --lint-only -Wall --top-module pcie_root_csr ip/soft_pcie_root/rtl/management/pcie_root_csr.sv
	verilator --lint-only -Wall --top-module pcie_ddr_bridge ip/soft_pcie_root/rtl/host/pcie_ddr_bridge.sv
	verilator --lint-only -Wall --top-module pcie_host_axi ip/soft_pcie_root/rtl/host/pcie_host_axi.sv
	verilator --lint-only -Wall --top-module pcie_cmd_mux ip/soft_pcie_root/rtl/host/pcie_cmd_mux.sv
	python3 scripts/test_cmd_xpm.py --elaborate-only
	verilator --lint-only -Wall --top-module pcie_soft_rate_control ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_rate_control.sv
hardware:
	mkdir -p $(dir $(OUTPUT))
	$(VIVADO) -mode batch -log $(OUTPUT)/vivado.log -journal $(OUTPUT)/vivado.jou -source examples/zcu104/build.tcl -tclargs $(OUTPUT) $(IP_REPO)
linux-configure:
	python3 software/linux/build.py configure --work $(WORK)
linux:
	python3 software/linux/build.py build --work $(WORK) --jobs $(JOBS)
linux-verify:
	python3 software/linux/build.py verify --work $(WORK)
linux-archive:
	python3 software/linux/build.py archive --work $(WORK) --output $(LINUX_OUTPUT)
linux-legal-info:
	python3 software/linux/build.py legal-info --work $(WORK)
HARDWARE_OUTPUT ?= $(OUTPUT)
AUDIT_OUTPUT ?= build/hardware_audit_next
PROFILE_OUTPUT ?= build/soft-profile_next
.PHONY: hardware-audit soft-profile
hardware-audit:
	mkdir -p $(AUDIT_OUTPUT)
	$(VIVADO) -mode batch -log $(AUDIT_OUTPUT)/vivado.log -journal $(AUDIT_OUTPUT)/vivado.jou -source examples/zcu104/audit.tcl -tclargs $(HARDWARE_OUTPUT)/routed.dcp $(AUDIT_OUTPUT)
	python3 scripts/validate_hardware.py $(HARDWARE_OUTPUT) --output $(AUDIT_OUTPUT)/validation.json
soft-profile:
	python3 scripts/package_soft_profile.py --work $(WORK) --hardware $(HARDWARE_OUTPUT) --output $(PROFILE_OUTPUT)
QEMU ?= qemu-system-aarch64
VM_OUTPUT ?= /tmp/zcu104-server-next
.PHONY: linux-test
linux-test:
	python3 software/linux/smoke_qemu.py --kernel $(WORK)/output/images/Image --initramfs $(WORK)/output/images/rootfs.cpio.gz --qemu $(QEMU) --work $(VM_OUTPUT)

IP_OUTPUT ?= build/ip_v1
IP_REPO ?= $(IP_OUTPUT)/core
.PHONY: ip release-check
ip:
	mkdir -p $(dir $(IP_OUTPUT))
	$(VIVADO) -mode batch -log $(IP_OUTPUT).log -journal $(IP_OUTPUT).jou -source ip/soft_pcie_root/package.tcl -tclargs $(IP_OUTPUT)
release-check:
	$(PYTHON) scripts/check_release.py
