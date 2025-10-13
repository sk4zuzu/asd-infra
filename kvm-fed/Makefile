.PHONY: all purge delete_vms delete_vnets delete_sgs

all:

purge: delete_vms delete_vnets delete_sgs

delete_vms:
	onevm list --no-header | awk '{print $$1}' | xargs -rn1 onevm recover --delete

delete_vnets:
	onevnet list --no-header | awk '$$1 >= 1 {print $$1}' | xargs -rn1 onevnet delete

delete_sgs:
	onesecgroup list --no-header | awk '$$1 >= 1 {print $$1}' | xargs -rn1 onesecgroup delete
