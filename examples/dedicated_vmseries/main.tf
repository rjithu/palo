# Generate a random password.
resource "random_password" "this" {
  count = var.vmseries_password == null ? 1 : 0

  length           = 16
  min_lower        = 16 - 4
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
  override_special = "_%@"
}

locals {
  vmseries_password = coalesce(var.vmseries_password, try(random_password.this[0].result, null))
}

# Obtain Public IP address of code deployment machine

data "http" "this" {
  count = length(var.bootstrap_storage) > 0 && anytrue([for v in values(var.bootstrap_storage) : try(v.storage_acl, false)]) ? 1 : 0
  url   = "https://ifconfig.me/ip"
}

# Create or source the Resource Group.
resource "azurerm_resource_group" "this" {
  count    = var.create_resource_group ? 1 : 0
  name     = "${var.name_prefix}${var.resource_group_name}"
  location = var.location

  tags = var.tags
}

data "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

locals {
  resource_group = var.create_resource_group ? azurerm_resource_group.this[0] : data.azurerm_resource_group.this[0]
}

# Manage the network required for the topology.
module "vnet" {
  source = "../../modules/vnet"

  for_each = var.vnets

  name                   = each.value.create_virtual_network ? "${var.name_prefix}${each.value.name}" : each.value.name
  create_virtual_network = each.value.create_virtual_network
  resource_group_name    = coalesce(each.value.resource_group_name, local.resource_group.name)
  location               = var.location

  address_space = each.value.address_space

  create_subnets = each.value.create_subnets
  subnets        = each.value.subnets

  network_security_groups = { for k, v in each.value.network_security_groups : k => merge(v, { name = "${var.name_prefix}${v.name}" })
  }
  route_tables = { for k, v in each.value.route_tables : k => merge(v, { name = "${var.name_prefix}${v.name}" })
  }

  tags = var.tags
}


module "natgw" {
  source = "../../modules/natgw"

  for_each = var.natgws

  create_natgw        = each.value.create_natgw
  name                = each.value.create_natgw ? "${var.name_prefix}${each.value.name}" : each.value.name
  resource_group_name = coalesce(each.value.resource_group_name, local.resource_group.name)
  location            = var.location
  zone                = try(each.value.zone, null)
  idle_timeout        = each.value.idle_timeout
  subnet_ids          = { for v in each.value.subnet_keys : v => module.vnet[each.value.vnet_key].subnet_ids[v] }

  public_ip        = try(merge(each.value.public_ip, { name = "${each.value.public_ip.create ? var.name_prefix : ""}${each.value.public_ip.name}" }), null)
  public_ip_prefix = try(merge(each.value.public_ip_prefix, { name = "${each.value.public_ip_prefix.create ? var.name_prefix : ""}${each.value.public_ip_prefix.name}" }), null)

  tags       = var.tags
  depends_on = [module.vnet]
}


# create load balancers, both internal and external
module "load_balancer" {
  source = "../../modules/loadbalancer"

  for_each = var.load_balancers

  name                = "${var.name_prefix}${each.value.name}"
  location            = var.location
  resource_group_name = local.resource_group.name
  zones               = each.value.zones

  health_probes = each.value.health_probes

  nsg_auto_rules_settings = try(
    {
      nsg_name = try(
        "${var.name_prefix}${var.vnets[each.value.nsg_auto_rules_settings.nsg_vnet_key].network_security_groups[each.value.nsg_auto_rules_settings.nsg_key].name}",
        each.value.nsg_auto_rules_settings.nsg_name
      )
      nsg_resource_group_name = try(
        var.vnets[each.value.nsg_auto_rules_settings.nsg_vnet_key].resource_group_name,
        each.value.nsg_auto_rules_settings.nsg_resource_group_name,
        null
      )
      source_ips    = each.value.nsg_auto_rules_settings.source_ips
      base_priority = each.value.nsg_auto_rules_settings.base_priority
    },
    null
  )

  frontend_ips = {
    for k, v in each.value.frontend_ips : k => merge(
      v,
      {
        public_ip_name = v.create_public_ip ? "${var.name_prefix}${v.public_ip_name}" : "${v.public_ip_name}",
        subnet_id      = try(module.vnet[v.vnet_key].subnet_ids[v.subnet_key], null)
      }
    )
  }

  tags       = var.tags
  depends_on = [module.vnet]
}




# create the actual VMSeries VMs and resources
module "ngfw_metrics" {
  source = "../../modules/ngfw_metrics"

  count = var.ngfw_metrics != null ? 1 : 0

  create_workspace = var.ngfw_metrics.create_workspace

  name                = "${var.ngfw_metrics.create_workspace ? var.name_prefix : ""}${var.ngfw_metrics.name}"
  resource_group_name = var.ngfw_metrics.create_workspace ? local.resource_group.name : coalesce(var.ngfw_metrics.resource_group_name, local.resource_group.name)
  location            = var.location

  log_analytics_workspace = {
    sku                       = var.ngfw_metrics.sku
    metrics_retention_in_days = var.ngfw_metrics.metrics_retention_in_days
  }

  application_insights = { for k, v in var.vmseries : k => { name = "${var.name_prefix}${v.name}-ai" } }

  tags = var.tags
}

resource "local_file" "bootstrap_xml" {
  for_each = { for k, v in var.vmseries : k => v if can(v.bootstrap_storage.template_bootstrap_xml) }

  filename = "files/${each.value.name}-bootstrap.xml"
  content = templatefile(
    each.value.bootstrap_storage.template_bootstrap_xml,
    {
      private_azure_router_ip = cidrhost(
        try(
          module.vnet[each.value.vnet_key].subnet_cidrs[each.value.bootstrap_storage.private_snet_key],
          module.vnet[each.value.vnet_key].subnet_cidrs[var.bootstrap_storage[each.value.bootstrap_storage.name].private_snet_key]
        ),
        1
      )

      public_azure_router_ip = cidrhost(
        try(
          module.vnet[each.value.vnet_key].subnet_cidrs[each.value.bootstrap_storage.public_snet_key],
          module.vnet[each.value.vnet_key].subnet_cidrs[var.bootstrap_storage[each.value.bootstrap_storage.name].public_snet_key]
        ),
        1
      )

      ai_instr_key = try(module.ngfw_metrics[0].metrics_instrumentation_keys[each.key], null)

      ai_update_interval = try(
        each.value.bootstrap_storage.ai_update_interval,
        var.bootstrap_storage[each.value.bootstrap_storage.name].ai_update_interval,
        5
      )

      private_network_cidr = try(
        each.value.bootstrap_storage.intranet_cidr,
        var.bootstrap_storage[each.value.bootstrap_storage.name].intranet_cidr,
        module.vnet[each.value.vnet_key].vnet_cidr[0]
      )

      mgmt_profile_appgw_cidr = flatten([
        for _, v in var.appgws : var.vnets[v.vnet_key].subnets[v.subnet_key].address_prefixes
      ])
    }
  )

  depends_on = [
    module.ngfw_metrics,
    module.vnet
  ]
}

module "bootstrap" {
  source = "../../modules/bootstrap"

  for_each = var.bootstrap_storage

  create_storage_account           = try(each.value.create_storage, true)
  name                             = each.value.name
  resource_group_name              = try(each.value.resource_group_name, local.resource_group.name)
  location                         = var.location
  storage_acl                      = try(each.value.storage_acl, false)
  storage_allow_vnet_subnet_ids    = try(flatten([for v in each.value.storage_allow_vnet_subnets : [module.vnet[v.vnet_key].subnet_ids[v.subnet_key]]]), [])
  storage_allow_inbound_public_ips = concat(try(each.value.storage_allow_inbound_public_ips, []), try([data.http.this[0].response_body], []))

  tags = var.tags
}

module "bootstrap_share" {
  source = "../../modules/bootstrap"

  for_each = { for k, v in var.vmseries : k => v if can(v.bootstrap_storage) }

  create_storage_account = false
  name                   = module.bootstrap[each.value.bootstrap_storage.name].storage_account.name
  resource_group_name    = try(var.bootstrap_storage[each.value.bootstrap_storage].resource_group_name, local.resource_group.name)
  location               = var.location
  storage_share_name     = each.key
  files = merge(
    each.value.bootstrap_storage.static_files,
    can(each.value.bootstrap_storage.template_bootstrap_xml) ? {
      "files/${each.value.name}-bootstrap.xml" = "config/bootstrap.xml"
    } : {}
  )

  files_md5 = can(each.value.bootstrap_storage.template_bootstrap_xml) ? {
    "files/${each.value.name}-bootstrap.xml" = local_file.bootstrap_xml[each.key].content_md5
  } : {}

  tags = var.tags

  depends_on = [
    local_file.bootstrap_xml,
    module.bootstrap
  ]
}



resource "azurerm_availability_set" "this" {
  for_each = var.availability_sets

  name                         = "${var.name_prefix}${each.value.name}"
  resource_group_name          = local.resource_group.name
  location                     = var.location
  platform_update_domain_count = try(each.value.update_domain_count, null)
  platform_fault_domain_count  = try(each.value.fault_domain_count, null)

  tags = var.tags
}

module "vmseries" {
  source = "../../modules/vmseries"

  for_each = var.vmseries

  location            = var.location
  resource_group_name = local.resource_group.name

  name        = "${var.name_prefix}${each.value.name}"
  username    = var.vmseries_username
  password    = local.vmseries_password
  img_version = try(each.value.version, var.vmseries_version)
  img_sku     = var.vmseries_sku
  vm_size     = try(each.value.vm_size, var.vmseries_vm_size)
  avset_id    = try(azurerm_availability_set.this[each.value.availability_set_key].id, null)

  enable_zones = var.enable_zones
  avzone       = try(each.value.avzone, 1)
  bootstrap_options = try(
    each.value.bootstrap_options,
    join(",", [
      "storage-account=${module.bootstrap[each.value.bootstrap_storage.name].storage_account.name}",
      "access-key=${module.bootstrap[each.value.bootstrap_storage.name].storage_account.primary_access_key}",
      "file-share=${each.key}",
      "share-directory=None"
    ]),
    ""
  )

  interfaces = [for v in each.value.interfaces : {
    name                     = "${var.name_prefix}${each.value.name}-${v.name}"
    subnet_id                = try(module.vnet[each.value.vnet_key].subnet_ids[v.subnet_key], null)
    create_public_ip         = try(v.create_pip, false)
    public_ip_name           = try(v.public_ip_name, null)
    public_ip_resource_group = try(v.public_ip_resource_group, null)
    enable_backend_pool      = can(v.load_balancer_key) ? true : false
    lb_backend_pool_id       = try(module.load_balancer[v.load_balancer_key].backend_pool_id, null)
    private_ip_address       = try(v.private_ip_address, null)
  }]

  tags = var.tags
  depends_on = [
    module.vnet,
    azurerm_availability_set.this,
    module.bootstrap,
    module.bootstrap_share
  ]
}

module "appgw" {
  source = "../../modules/appgw"

  for_each = var.appgws

  name                = each.value.name
  public_ip           = each.value.public_ip
  resource_group_name = local.resource_group.name
  location            = var.location
  subnet_id           = module.vnet[each.value.vnet_key].subnet_ids[each.value.subnet_key]

  managed_identities = each.value.managed_identities
  capacity           = each.value.capacity
  waf                = each.value.waf
  enable_http2       = each.value.enable_http2
  zones              = each.value.zones

  frontend_ip_configuration_name = each.value.frontend_ip_configuration_name
  listeners                      = each.value.listeners
  backend_pool = {
    name = "vmseries"
    vmseries_ips = [
      for k, v in var.vmseries : module.vmseries[k].interfaces[
        "${var.name_prefix}${v.name}-${each.value.vmseries_public_nic_name}"
      ].private_ip_address if try(v.add_to_appgw_backend, false)
    ]
  }
  backends      = each.value.backends
  probes        = each.value.probes
  rewrites      = each.value.rewrites
  rules         = each.value.rules
  redirects     = each.value.redirects
  url_path_maps = each.value.url_path_maps

  ssl_global   = each.value.ssl_global
  ssl_profiles = each.value.ssl_profiles

  tags       = var.tags
  depends_on = [module.vnet]
}
