# SMSv2 AWS and KVM delivery checklist

This checklist is the acceptance ledger for issue #1209. Items are marked complete only with a retained command receipt; source changes and passing unit tests are not live-acceptance evidence.

- [x] Pin provider v9.5.1 for the Site-UID image resolver, template/JWT contract, and mutation HTTP/1 ALPN fix.
- [x] Reconcile the existing AWS showcase owner: the #1194 state root remains authoritative; #1210 starts with an empty backend.
- [x] Repair stale CI policy and contract tests for v9.5.1 and obsolete KVM bootstrap semantics.
- [x] Verify cache/download integrity for the API-selected KVM QCOW2 before libvirt imports it.
- [x] Create a dedicated Terraform-managed libvirt directory pool; do not recreate the host `default` pool.
- [x] Create the checksum-pinned on-prem workload VM and prove its interface and generated traffic.
- [x] Run one reviewed KVM apply and prove registration, MAC binding, site health, BGP, routes, traffic, and a zero-change follow-up plan.
- [ ] Run controlled AWS/KVM drift detection and repair from reviewed plans.
- [x] Destroy the failed disposable KVM cycle and independently prove libvirt, Docker, XC, and Terraform-state absence.
- [ ] Rebuild a second cycle and leave AWS plus KVM online with all acceptance receipts.
