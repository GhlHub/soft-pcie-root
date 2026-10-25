obj-m += zcu104-soft-pcie.o
# Embed the actual compiled source identity; stale Buildroot local copies fail validation.
ccflags-y += -DZCU104_SOURCE_SHA256=\"$(shell sha256sum $(src)/zcu104-soft-pcie.c | cut -d' ' -f1)\"
