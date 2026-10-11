# Importing hand-built Proxmox VMs into a `bpg/proxmox` module without replacement

Research for issue #4. Researched 2026-10-11.

**Versions examined**

- `bpg/proxmox` **v0.111.1** (the pinned line) and **v0.116.0** (latest release, 2026-10-06). All source links below point at the `v0.111.1` tag unless marked otherwise. Between v0.111.1 and v0.116.0, nothing changed in the `proxmox_virtual_environment_vm` importer, in its `ForceNew` attributes, or in its `CustomizeDiff` replacement rules. I checked this with `git diff v0.111.1 v0.116.0 -- proxmoxtf/resource/vm/`; it shows no `ForceNew`/`Importer` lines.
- Terraform **v1.16.5** (latest release, 2026-10-02) for core behaviour, plus the v1.16.x docs.

Nothing here was run against real infrastructure. Every claim comes from provider source code, provider docs, upstream issues, or Terraform source and docs.

---

## TL;DR

1. Import ID is `<node_name>/<vm_id>`. The importer only sets the ID and `node_name`. The normal Read then fills in the rest from the Proxmox config. It never fills in `clone`, and it leaves `initialization` empty when the VM has no cloud-init drive.
2. **The only thing in our module that forces replacement after import is the `clone` block**: every field inside it is `ForceNew`, and state holds `clone = []` after import. `vm_id` and `node_name` also force replacement if they don't match the real VM. So do the `initialization.*_data_file_id`/`type` fields, but only if we set them. `disk`, `network_device`, `cpu`, `agent`, `operating_system`, `started` and `boot_order` are **never** replacement triggers. Mismatches there become in-place updates, and many of those reboot or power-cycle the VM.
3. Adding an `initialization` block to an imported ISO VM doesn't replace it. It **powers the VM off and attaches a new cloud-init drive**. We should not render that block for adopted VMs.
4. Recommended pattern: a module input (`clone_template_vm_id = null`) that drops `clone` and `initialization` through `dynamic` blocks, plus `lifecycle { ignore_changes = [clone] }`. Every other attribute is an input set to the VM's real values, and adoption runs with `reboot_after_update = false`. Iterate `terraform plan` until it says `1 to import, 0 to add, 0 to change, 0 to destroy`.
5. Removing a provider alias is safe for resources still in config. Terraform resolves the provider from config and rewrites the provider address in state. No `state` surgery is needed. Resources that exist only in state (orphans) still need their original alias, or plan fails with "Provider configuration not present".

---

## 1. How import works for `proxmox_virtual_environment_vm`

### ID format

The docs give `terraform import proxmox_virtual_environment_vm.<name> <node>/<vmid>` ([docs, Import](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/docs/resources/virtual_environment_vm.md#import); same text in [v0.116.0](https://github.com/bpg/terraform-provider-proxmox/blob/v0.116.0/docs/resources/virtual_environment_vm.md#import)).

The importer splits on `/`. It errors with `unexpected format of ID (...), expected node/id` if there's no slash. Then it sets the ID to the numeric VMID and sets `node_name`. Nothing else happens ([vm.go L1794-L1810](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L1794-L1810), [parseImportIDWithNodeName L7555](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L7555)).

Equivalent `import` block, which goes in the **root** module and can target a resource inside a module ([Terraform `import` block docs](https://developer.hashicorp.com/terraform/language/block/import), whose example uses `to = module.group[...].aws_s3_bucket.this[...]`):

```hcl
import {
  to = module.vm["<key>"].proxmox_virtual_environment_vm.this
  id = "<node>/<vmid>"
}
```

`import` blocks also take `for_each`, and `provider = proxmox.<alias>` if needed (same doc). After the import is applied, the blocks can be removed or kept as a record ([Import a single resource](https://developer.hashicorp.com/terraform/language/import/single-resource)).

### What gets populated

After the importer runs, Terraform calls Read (`vmRead`, then `vmReadCustom`) ([L4293](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L4293), [L4358](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L4358)). Several of Read's code paths branch on `len(clone) == 0`. After import `clone` is always empty, so Read takes the "not a clone" path everywhere and fills in **everything** it can read from the VM config:

| Attribute | What Read does after import |
|---|---|
| `clone` | Never set by Read. State is `[]`. |
| `started` | Set from the live status: `running` gives `true` ([L4378](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L4378)). |
| `agent` | Read from the config. A missing `type` is reported as the schema default `virtio` so imports don't diff ([L4440](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L4440)). |
| `cpu.type` | From config. If PVE has no `cpu:` key, reported as `qemu64` ([L4708](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L4708)). |
| `keyboard_layout` | A missing value is reported as the schema default ([L5772](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L5772)). This and the `agent.type` fix came from upstream [#2902](https://github.com/bpg/terraform-provider-proxmox/issues/2902), fixed by PR #2911 and first released in v0.108.0. |
| `operating_system.type` | From `ostype`; state is `[]` when it equals the default `other` ([L5309-L5334](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L5309-L5334)). |
| `boot_order` | From `boot: order=...`, otherwise null ([L5731](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L5731)). Optional+Computed. |
| `disk` | All disks, keyed by interface, with `datastore_id`, `path_in_datastore`, `size` (GB), `file_format`, `aio` (missing becomes `io_uring`), and so on ([disk.go Read L385](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/disk/disk.go#L385), [aio default L467](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/disk/disk.go#L467)). `file_id` is **not** filled in ([#1998](https://github.com/bpg/terraform-provider-proxmox/issues/1998)). |
| `network_device` | All NICs, including the real `mac_address`. |
| `initialization` | Only filled in if a cloud-init drive exists ([L5015](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L5015)). For an ISO-installed VM with no cloud-init drive it stays `[]`. |
| `cdrom` | Read looks at the interface in state, which falls back to the default `ide3` ([L4574](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L4574)). An installer ISO left on `ide2` is not picked up. The disk-removal path skips CD-ROM media ([L6503-L6512](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L6503)). |
| Provider-only settings (`timeout_*`, `stop_on_destroy`, `reboot_after_update`, `migrate`, ...) | Set to defaults when missing, so they don't diff ([L5631-L5644](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L5631)). |

## 2. Which attributes force replacement after import

Source of truth: `ForceNew` in the schema plus the `CustomizeDiff` functions ([vm.go L1765-L1793](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L1765-L1793)).

| Attribute | Forces replacement? | Evidence / behaviour after import |
|---|---|---|
| `clone { vm_id, full, datastore_id, node_name, retries }` | **Yes.** Every sub-field is `ForceNew`, and `vm_id` is required ([L592-L638](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L592-L638)). | State has `clone = []` and config has `clone { vm_id = X }`, so the plan is `-/+`. This is upstream [#1988](https://github.com/bpg/terraform-provider-proxmox/issues/1988), closed as stale. The workaround named there is `ignore_changes` on `clone`. It also means that **changing the template ID later replaces every cloned VM**, unless `clone` is ignored. |
| `vm_id` | **Yes**, if it differs from the imported ID (`ForceNewIf`, [L1767-L1779](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L1767-L1779)). | Must equal the real VMID. |
| `node_name` | **Yes**, unless `migrate = true` ([L1781-L1790](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L1781-L1790)). | Must equal the node the VM is on. |
| `initialization` (block) | No. The block itself isn't `ForceNew` ([L833](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L833)). | **In-place, but disruptive.** With no existing cloud-init drive, update powers the VM off, attaches `<datastore>:cloudinit` on `ide2`, and writes cloud-init config ([L6592-L6684](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L6592-L6684)). |
| `initialization.{user,vendor,network,meta}_data_file_id`, `initialization.type` | **Yes** (`ForceNew`, Optional+Computed; [L994-L1032](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L994-L1032)). | Only if set in config. If left unset (Computed), there's no diff. |
| `disk.interface` | No | A mismatch is an in-place update. The configured interface gets a **new blank disk** and the real disk is removed from config via `delete`. Update refuses this if the real disk is in `boot_order` ([L6493-L6524](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L6493-L6524)). Disk-to-interface matching after import has known issues: [#2285](https://github.com/bpg/terraform-provider-proxmox/issues/2285) (open). |
| `disk.datastore_id` (default `local-lvm`) | No | A mismatch is a **disk move** that needs the VM shut down ([L7252-L7275](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L7252)). Always set it to the real datastore. |
| `disk.size` (default 8) | No | Bigger means a resize. Smaller fails with `Cannot shrink ... it is not supported!` ([L7278-L7305](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L7278-L7305)). |
| `disk.file_format` | No (Optional+Computed, [disk/schema.go L110](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/disk/schema.go#L110)) | Leave it unset. Update never resends `format` for existing volumes ([disk.go L656-L663](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/disk/disk.go#L656)), so a wrong value just keeps showing up as a diff. |
| `disk.file_id` | **Yes** (`ForceNew`, [disk/schema.go L136](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/disk/schema.go#L136)) | Never filled in on import ([#1998](https://github.com/bpg/terraform-provider-proxmox/issues/1998), open). Don't set it for adopted VMs. |
| `disk.aio`, `iothread`, `ssd`, `discard`, `cache`, `backup`, `replicate` | No | In-place. An `aio` change sets "reboot required" ([disk.go L675](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/disk/disk.go#L675)). `aio` handling for VMs created in the GUI: [#2858](https://github.com/bpg/terraform-provider-proxmox/issues/2858) (open). |
| `network_device.mac_address` | No (Optional+Computed, [network/schema.go L108](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/network/schema.go#L108)) | Omit it and the imported MAC is kept. Setting a different value is an in-place NIC change, not a replacement. |
| `network_device` (`bridge`, `model`, `firewall`, `vlan_id`, `mtu`, `queues`) | No | In-place. Note the defaults: `bridge = "vmbr0"`, `model = "virtio"`, `firewall = false` ([network/schema.go](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/network/schema.go#L18-L25)). The PVE web wizard ticks Firewall by default ([pve-manager NetworkEdit.js](https://git.proxmox.com/?p=pve-manager.git;a=blob;f=www/manager6/qemu/NetworkEdit.js;hb=76177f3d466d9a3b6fc5180d2cf03aff1b02fecb)), so GUI-built VMs often have `firewall=1`. |
| `cpu.type` (default `qemu64`, [L78](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L78)) | No | In-place plus reboot ([L6382](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L6382)). The PVE GUI default model for x86_64 is `x86-64-v2-AES` ([pve-manager Architecture.js](https://git.proxmox.com/?p=pve-manager.git;a=blob;f=www/manager6/qemu/Architecture.js;hb=76177f3d466d9a3b6fc5180d2cf03aff1b02fecb)), so set it explicitly. |
| `agent` | No | In-place, with `rebootRequired = true` ([L6266-L6291](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L6266)). Only set `enabled = true` on VMs that actually run `qemu-guest-agent`. Otherwise Proxmox shutdown/reboot goes through the agent and times out ([docs, "Qemu guest agent"](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/docs/resources/virtual_environment_vm.md#qemu-guest-agent)). |
| `operating_system` (default `other`) | No | In-place plus reboot ([L6850-L6866](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L6850)). Ubuntu VMs from the wizard are normally `l26`. |
| `started` (default `true`) | No | In-place start/stop ([L7107](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L7107)). A VM that is stopped when we plan will get started unless the module sets `started = false`. |
| `boot_order` | No | In-place plus reboot ([L6320-L6331](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L6320)). It's Optional+Computed, so omitting it means no diff. |
| `scsi_hardware` (default `virtio-scsi-pci`, [L145](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L145)) | No | In-place plus reboot. The PVE wizard default is `virtio-scsi-single` ([pve-manager OSDefaults.js](https://git.proxmox.com/?p=pve-manager.git;a=blob;f=www/manager6/qemu/OSDefaults.js;hb=76177f3d466d9a3b6fc5180d2cf03aff1b02fecb)). Not in our module today, but it will diff unless we set it. |
| `amd_sev`, `tpm_state.version`, `efi_disk.type` | Yes (not used by our module) | [L454-L458](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L454), [`forceNewOnTPMVersionChange` L1814](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L1814) and [`forceNewOnEFIDiskTypeChange` L1875](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L1875). Only relevant if a VM uses OVMF/TPM. |

**Takeaway:** for our module, `clone` is the only replacement trigger (assuming `vm_id` and `node_name` are correct). Everything else is about avoiding **in-place updates that power-cycle the VM**: `cpu.type`, `scsi_hardware`, `operating_system`, `agent`, `initialization`, `disk.datastore_id`, `disk.interface`, and NIC `firewall`.

## 3. Strategies for a zero-change plan

### 3a. Module flag that omits `clone` and `initialization` (recommended, primary)

`lifecycle` arguments only accept literal values ([lifecycle docs](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle); [resource block docs](https://developer.hashicorp.com/terraform/language/block/resource): "You can only use literal values in the lifecycle block"). So a module can't switch `ignore_changes` on or off per instance. Per-instance behaviour has to come from `dynamic` blocks:

- `clone_template_vm_id = null` renders no `clone` block. Config `clone = []` matches state `clone = []`, so nothing is `ForceNew`.
- The same flag turns off `initialization`, so no cloud-init drive is attached and there's no power-off.
- Every other attribute becomes an input whose value comes from the VM's real config (`qm config <vmid>` on the node, read-only).

### 3b. `lifecycle { ignore_changes = [clone] }` (recommended, as a backstop)

Terraform core applies `ignore_changes` to the config **before** it calls the provider's `PlanResourceChange`. The provider never sees the ignored difference, so `ForceNew` can't fire ([terraform v1.16.5 `node_resource_abstract_instance.go` L970-L987](https://github.com/hashicorp/terraform/blob/v1.16.5/internal/terraform/node_resource_abstract_instance.go#L970-L987)). The docs say ignored arguments still count on create and are only ignored on update ([lifecycle docs](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle)). That makes `ignore_changes = [clone]` safe for a module that both creates clones and adopts VMs, because `clone` only matters at create time anyway. It also stops a template-ID bump from replacing every cloned VM.

`ignore_changes = [initialization]` would also stop the cloud-init drive from being attached on adopted VMs. But it applies to **all** instances of the module, so it would also freeze cloud-init edits on cloned VMs. Use the dynamic block for that instead.

`ignore_changes` for `network_device[0].mac_address` isn't needed if `mac_address` is left unset (it's Optional+Computed).

### 3c. `terraform plan -generate-config-out=...` (discovery aid only)

- Experimental, and it only generates config for import targets that **don't already exist in config** ([Generating configuration](https://developer.hashicorp.com/terraform/language/import/generating-configuration)).
- Only root-module addresses can have config generated: `Only resources within the root module are eligible for config generation.` ([terraform v1.16.5 `node_resource_validate.go` L899-L907](https://github.com/hashicorp/terraform/blob/v1.16.5/internal/terraform/node_resource_validate.go#L899-L907)). It can't generate straight into `module.vm[...]`.
- Use it in a scratch root module (with no backend, or a throwaway one) to dump every attribute value the provider reads. Copy those values into the module inputs and delete the scratch output. **Never commit the generated file**: it contains MAC addresses, node names, VMIDs and similar details, and this repo is public.

### Adoption workflow

1. Read the live config on the node (`qm config <vmid>`, read-only). Record `cpu`, `scsihw`, `ostype`, `boot`, `agent`, each disk's interface/storage/size/options, each NIC's bridge/model/firewall/tag, and the power state.
2. Add the module instance with `clone_template_vm_id = null` and those values. Set `reboot_after_update = false` while adopting. Then any update that needs a reboot or power-off **fails** instead of power-cycling the VM ([docs, `reboot_after_update`](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/docs/resources/virtual_environment_vm.md#argument-reference)).
3. Add a root `import {}` block with `id = "<node>/<vmid>"`.
4. Run `terraform plan`. The target is `Plan: 1 to import, 0 to add, 0 to change, 0 to destroy.` Any `~` attribute means a module input is wrong. Fix the input; don't add more `ignore_changes`.
5. Run `terraform apply` once the plan is clean. Optionally go back to `reboot_after_update = true` afterwards.

## 4. Removing a provider alias (single-cluster collapse)

Terraform core behaviour, v1.16.5:

- State records a provider **configuration** address for each resource, for example `provider["registry.terraform.io/bpg/proxmox"].<alias>`.
- **Resources that are still in config:** the provider comes from config first ("If we have a config we prefer that above all else", [`node_resource_abstract.go` L335-L345](https://github.com/hashicorp/terraform/blob/v1.16.5/internal/terraform/node_resource_abstract.go#L335-L345)). The resolved address is written back to state ([L546](https://github.com/hashicorp/terraform/blob/v1.16.5/internal/terraform/node_resource_abstract.go#L546)). Remove `provider = proxmox.<alias>` from the resource, or change the module call from `providers = { proxmox = proxmox.<alias> }` to the default (or drop it; child modules inherit default, unaliased configs per the [`providers` meta-argument docs](https://developer.hashicorp.com/terraform/language/meta-arguments/providers)). Terraform then uses the default config, and the next apply saves the new address. This doesn't change the resource address, so it's not a replace and needs no `state` command.
- **Resources that exist only in state (orphans):** "An address from the state must match exactly" ([L348-L357](https://github.com/hashicorp/terraform/blob/v1.16.5/internal/terraform/node_resource_abstract.go#L348-L357)). If the alias block is gone, plan fails with `Provider configuration not present ... its original provider configuration at ... is required, but it has been removed` ([`transform_provider.go` L263-L265](https://github.com/hashicorp/terraform/blob/v1.16.5/internal/terraform/transform_provider.go#L263-L265)). Finish destroying or `removed {}`-ing those resources before deleting the alias.
- `terraform state replace-provider` changes a provider's **source FQN** (such as `registry.terraform.io/x/proxmox` to `.../bpg/proxmox`), not an alias ([docs](https://developer.hashicorp.com/terraform/cli/commands/state/replace-provider)). It isn't needed here.
- If the collapse also renames module calls or keys (for example, merging per-cluster module calls into one `for_each`), that's a **resource address** change and needs `moved {}` blocks. It's a separate concern from the provider address.
- If a child module declares `configuration_aliases`, remove the alias from its `required_providers` too.
- Provider-specific caveat: the default provider must point at the **same cluster**. In v0.111.1, `vmRead` drops a VM from state (`SetId("")`) when the cluster resource list doesn't contain it ([L4306-L4315](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go#L4306-L4315)), so the next plan would show a **create**. v0.113.0 changed this to fall back to the node config endpoint ([#3068](https://github.com/bpg/terraform-provider-proxmox/issues/3068), [v0.116.0 vm.go](https://github.com/bpg/terraform-provider-proxmox/blob/v0.116.0/proxmoxtf/resource/vm/vm.go)). Either way, check that the plan shows `0 to add` after the switch.

## 5. Recommended module pattern

```hcl
# modules/proxmox-vm/variables.tf (excerpt)
variable "clone_template_vm_id" {
  type        = number
  default     = null
  description = "Template VM to clone. null = adopt an existing (imported) VM: no clone or cloud-init blocks are rendered."
}

variable "cloud_init" {
  type = object({
    datastore_id = string
    ipv4_address = string
    ipv4_gateway = optional(string)
    username     = string
    ssh_keys     = list(string)
  })
  default     = null
  description = "Cloud-init settings; only used when cloning."
}

variable "cpu_type" { type = string }      # value of `cpu:` in qm config
variable "scsi_hardware" { type = string } # value of `scsihw:`
variable "os_type" { type = string }       # value of `ostype:`
variable "agent_enabled" { type = bool }

variable "started" {
  type    = bool
  default = true
}

variable "nic_firewall" {
  type    = bool
  default = false
}

variable "reboot_after_update" {
  type    = bool
  default = true
}

# node_name, vm_id, name, tags, cores, memory_mb, bridge omitted for brevity
variable "disk" {
  type = object({
    interface    = string
    datastore_id = string
    size_gb      = number
    iothread     = optional(bool, false)
    discard      = optional(string, "ignore")
    ssd          = optional(bool, false)
  })
}
```

```hcl
# modules/proxmox-vm/main.tf (excerpt)
resource "proxmox_virtual_environment_vm" "this" {
  node_name = var.node_name
  vm_id     = var.vm_id # must equal the real VMID for adopted VMs
  name      = var.name
  tags      = var.tags

  started             = var.started
  reboot_after_update = var.reboot_after_update
  scsi_hardware       = var.scsi_hardware

  dynamic "clone" {
    for_each = var.clone_template_vm_id == null ? [] : [var.clone_template_vm_id]
    content {
      vm_id = clone.value
      full  = true
    }
  }

  dynamic "initialization" {
    for_each = var.clone_template_vm_id == null || var.cloud_init == null ? [] : [var.cloud_init]
    content {
      datastore_id = initialization.value.datastore_id
      ip_config {
        ipv4 {
          address = initialization.value.ipv4_address
          gateway = initialization.value.ipv4_gateway
        }
      }
      user_account {
        username = initialization.value.username
        keys     = initialization.value.ssh_keys
      }
    }
  }

  agent {
    enabled = var.agent_enabled
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory_mb
  }

  operating_system {
    type = var.os_type
  }

  disk {
    interface    = var.disk.interface
    datastore_id = var.disk.datastore_id
    size         = var.disk.size_gb
    iothread     = var.disk.iothread
    discard      = var.disk.discard
    ssd          = var.disk.ssd
    # file_format and file_id deliberately unset
  }

  network_device {
    bridge   = var.bridge
    model    = "virtio"
    firewall = var.nic_firewall
    # mac_address deliberately unset: Optional+Computed keeps the imported MAC
  }

  lifecycle {
    # clone is create-only; ignoring it stops imported VMs (state clone = [])
    # and template-ID changes from forcing replacement.
    ignore_changes = [clone]
  }
}
```

```hcl
# root: adopting one VM (placeholders only)
module "vm" {
  source   = "./modules/proxmox-vm"
  for_each = var.vms
  # ... inputs per VM; adopted VMs set clone_template_vm_id = null,
  # reboot_after_update = false during adoption
}

import {
  for_each = var.adopted_vm_ids # map(key => "<node>/<vmid>")
  to       = module.vm[each.key].proxmox_virtual_environment_vm.this
  id       = each.value
}
```

Notes on the sketch:

- Defaults like `nic_firewall = false` and `iothread = false` match the provider defaults, so new cloned VMs behave as they do today. Adopted VMs override them with whatever `qm config` shows.
- If a VM has more disks or NICs than the module declares, plan will show them being removed (disks are detached to `unused*`, see §2). Either extend the module to take lists of disks/NICs or adopt only single-disk/single-NIC VMs. That's a scope decision for the module ticket.
- Adding `prevent_destroy = true` while adopting is cheap insurance. It also has to be a literal and applies to every instance of the module.

## 6. Open risks / not verified

- **Nothing was run.** The table in §2 comes from reading the source. Confirm the zero-change result with a real `terraform plan` on each VM before any apply.
- **CD-ROM drift:** ISO-installed VMs usually still have the installer ISO or an empty drive on `ide2`, while the provider's `cdrom` default interface is `ide3`. Read won't pick up `ide2` after import (§1). Removal paths skip CD-ROM media, but whether an unset `cdrom` block shows a diff wasn't confirmed. Check the first plan.
- **Memory ballooning (`memory.floating`)**, `bios`/`machine`, `vga`, `serial_device`, and `startup`/`on_boot` weren't analysed one by one. Any non-default value in `qm config` needs a matching module input or it shows as an in-place diff.
- **Guest-side cloud-init:** if a cloud-init drive ever got attached to an adopted Ubuntu VM (for example, by forgetting the flag), cloud-init inside the guest might apply the new datasource on next boot (hostname, network, users). That's guest behaviour and wasn't checked against the provider. The flag in §3a exists to avoid it.
- Upstream issues still open that could affect imports: [#2285](https://github.com/bpg/terraform-provider-proxmox/issues/2285) (disk matching), [#2858](https://github.com/bpg/terraform-provider-proxmox/issues/2858) (`aio` default), [#1998](https://github.com/bpg/terraform-provider-proxmox/issues/1998) (`file_id`). The SDKv2 VM resource is due to be replaced by a Plugin Framework one ([#1231](https://github.com/bpg/terraform-provider-proxmox/issues/1231)). The experimental `proxmox_vm` / `proxmox_virtual_environment_cloned_vm` resources aren't meant for this, and the docs say not to use `proxmox_vm` in production.

## Sources

- bpg provider, v0.111.1: [`proxmoxtf/resource/vm/vm.go`](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/vm.go), [`disk/schema.go`](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/disk/schema.go), [`disk/disk.go`](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/disk/disk.go), [`network/schema.go`](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/vm/network/schema.go), [`docs/resources/virtual_environment_vm.md`](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/docs/resources/virtual_environment_vm.md)
- bpg provider, v0.116.0: [release](https://github.com/bpg/terraform-provider-proxmox/releases/tag/v0.116.0), [CHANGELOG](https://github.com/bpg/terraform-provider-proxmox/blob/v0.116.0/CHANGELOG.md)
- bpg issues: [#1988](https://github.com/bpg/terraform-provider-proxmox/issues/1988), [#1998](https://github.com/bpg/terraform-provider-proxmox/issues/1998), [#2285](https://github.com/bpg/terraform-provider-proxmox/issues/2285), [#2858](https://github.com/bpg/terraform-provider-proxmox/issues/2858), [#2902](https://github.com/bpg/terraform-provider-proxmox/issues/2902), [#3068](https://github.com/bpg/terraform-provider-proxmox/issues/3068), [#1231](https://github.com/bpg/terraform-provider-proxmox/issues/1231)
- Terraform v1.16.5 source: [`node_resource_abstract_instance.go`](https://github.com/hashicorp/terraform/blob/v1.16.5/internal/terraform/node_resource_abstract_instance.go), [`node_resource_abstract.go`](https://github.com/hashicorp/terraform/blob/v1.16.5/internal/terraform/node_resource_abstract.go), [`transform_provider.go`](https://github.com/hashicorp/terraform/blob/v1.16.5/internal/terraform/transform_provider.go), [`node_resource_validate.go`](https://github.com/hashicorp/terraform/blob/v1.16.5/internal/terraform/node_resource_validate.go)
- Terraform docs (v1.16.x): [import block](https://developer.hashicorp.com/terraform/language/block/import), [import a single resource](https://developer.hashicorp.com/terraform/language/import/single-resource), [generating configuration](https://developer.hashicorp.com/terraform/language/import/generating-configuration), [lifecycle](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle), [resource block](https://developer.hashicorp.com/terraform/language/block/resource), [providers meta-argument](https://developer.hashicorp.com/terraform/language/meta-arguments/providers), [provider block](https://developer.hashicorp.com/terraform/language/block/provider), [state replace-provider](https://developer.hashicorp.com/terraform/cli/commands/state/replace-provider)
- Proxmox VE web UI defaults (pve-manager @ `76177f3d`): [OSDefaults.js](https://git.proxmox.com/?p=pve-manager.git;a=blob;f=www/manager6/qemu/OSDefaults.js;hb=76177f3d466d9a3b6fc5180d2cf03aff1b02fecb), [Architecture.js](https://git.proxmox.com/?p=pve-manager.git;a=blob;f=www/manager6/qemu/Architecture.js;hb=76177f3d466d9a3b6fc5180d2cf03aff1b02fecb), [NetworkEdit.js](https://git.proxmox.com/?p=pve-manager.git;a=blob;f=www/manager6/qemu/NetworkEdit.js;hb=76177f3d466d9a3b6fc5180d2cf03aff1b02fecb)
