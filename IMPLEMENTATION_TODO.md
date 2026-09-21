# SMSv2 AWS and KVM delivery checklist

This checklist is the acceptance ledger for issue #1209. Items are marked complete only with a retained command receipt; source changes and passing unit tests are not live-acceptance evidence.

- [x] Pin the released Site-UID image resolver and template/JWT contract at provider v9.5.0.
- [x] Reconcile the existing AWS showcase owner: the #1194 state root remains authoritative; #1210 starts with an empty backend.
- [x] Repair stale CI policy and contract tests from v9.5.0 and obsolete KVM bootstrap semantics.
- [ ] Verify cache/download integrity for the API-selected KVM QCOW2 before libvirt imports it.
- [ ] Create a dedicated Terraform-managed libvirt directory pool; do not recreate the host `default` pool.
- [ ] Create the checksum-pinned on-prem workload VM and prove its interface and generated traffic.
- [ ] Run reviewed KVM first apply, registration/MAC/site health/BGP/routes/traffic and zero-change reapply.
- [ ] Run controlled AWS/KVM drift detection and repair from reviewed plans.
- [ ] Destroy the disposable first cycle, independently prove cloud/libvirt/XC absence and empty state.
- [ ] Rebuild a second cycle and leave AWS plus KVM online with all acceptance receipts.
