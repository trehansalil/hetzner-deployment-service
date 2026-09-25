# Option B: rescale `portfolio` to 16 GB

**Status:** not executed. Alternative: [Option A dedicated node](option-a-docling-node/RUNBOOK.md).

```bash
hcloud server describe portfolio               # record current type + disk size first
hcloud server-type describe cpx41              # confirm orderable in hel1 and check the price
hcloud server shutdown portfolio               # graceful ACPI shutdown; poll until status=off
hcloud server change-type --keep-disk portfolio cpx41
hcloud server poweron portfolio
```

- **Flag:** `--keep-disk` is verified against the hcloud CLI reference (`hcloud server change-type [--keep-disk] <server> <server-type>`). Its description reads: "Keep disk size of current Server Type. This enables downgrading the server." In the API it maps to `upgrade_disk=false`.
- **Power-off is required.** The API's change_type action only succeeds on a stopped server.
- **Downtime:** everything is down, including all apps, ingress, postgres and the CI deploy endpoint. That covers shutdown, the rescale (usually a few minutes, but it is not guaranteed), boot, then k3s start and pod restarts, which take several more minutes.
  - Plan a window of about 15–30 min.
  - Swap is not in `/etc/fstab`, so the 8 GiB swapfile is **gone after the reboot** unless re-enabled by hand.
  - The attached Volume (`HC_Volume_106759881`) and the Primary IP stay attached.
- **Downgrade:** with `--keep-disk` the root disk stays at its current size, so you can later `change-type` back to the current 8 GB type, again powered off. Without `--keep-disk` the disk grows to the new type's size, and you can never downgrade to a type with a smaller disk.
- **Price:** billed hourly. Check the current CPX41 price in the Cloud Console. No price is quoted here. If `cpx41` is no longer orderable, use the current 8 vCPU / 16 GB type.
- **Afterwards:** apply `kubelet-memory.yaml` with the 16 GB values from `KUBELET-MEMORY-RUNBOOK.md` §6. Those are system-reserved 2Gi, kube-reserved 1Gi and eviction-hard 500Mi; re-measure non-pod PSS first. Then re-check that allocatable covers the branch's 7000Mi worst case (docling 2560 + 2 workers at 1Gi + the rest).
- **B does not isolate anything.** Docling, the Claude sessions and traefik/postgres still share one kernel. The reservations and eviction thresholds become more important, not less.
