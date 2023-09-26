# --- GENERAL --- #
location            = "North Europe"
resource_group_name = "transit-vnet-common"
name_prefix         = "fosix-"
tags = {
  "CreatedBy"   = "Palo Alto Networks"
  "CreatedWith" = "Terraform"
}


# --- VNET PART --- #
vnets = {
  "transit" = {
    name          = "transit"
    address_space = ["10.0.0.0/25"]
    network_security_groups = {
      "management" = {
        name = "mgmt-nsg"
        rules = {
          inbound = {
            name                       = "mgmt_allow_inbound"
            priority                   = 100
            direction                  = "Inbound"
            access                     = "Allow"
            protocol                   = "Tcp"
            source_address_prefixes    = ["1.2.3.4"] # TODO: whitelist public IP addresses that will be used to manage the appliances
            source_port_range          = "*"
            destination_address_prefix = "10.0.0.0/28"
            destination_port_ranges    = ["22", "443"]
          }
        }
      }
      "public" = {
        name = "public-nsg"
      }
    }
    route_tables = {
      "management" = {
        name = "mgmt-rt"
        routes = {
          "private_blackhole" = {
            name           = "private_blackhole"
            address_prefix = "10.0.0.16/28"
            next_hop_type  = "None"
          }
          "public_blackhole" = {
            name           = "public_blackhole"
            address_prefix = "10.0.0.32/28"
            next_hop_type  = "None"
          }
        }
      }
      "private" = {
        name = "private-rt"
        routes = {
          "default" = {
            name                   = "default"
            address_prefix         = "0.0.0.0/0"
            next_hop_type          = "VirtualAppliance"
            next_hop_in_ip_address = "10.0.0.30"
          }
          "mgmt_blackhole" = {
            name           = "mgmt_blackhole"
            address_prefix = "10.0.0.0/28"
            next_hop_type  = "None"
          }
          "public_blackhole" = {
            name           = "public_blackhole"
            address_prefix = "10.0.0.32/28"
            next_hop_type  = "None"
          }
        }
      }
      "public" = {
        name = "public-rt"
        routes = {
          "mgmt_blackhole" = {
            name           = "mgmt_blackhole"
            address_prefix = "10.0.0.0/28"
            next_hop_type  = "None"
          }
          "private_blackhole" = {
            name           = "private_blackhole"
            address_prefix = "10.0.0.16/28"
            next_hop_type  = "None"
          }
        }
      }
    }
    subnets = {
      "management" = {
        name                            = "mgmt-snet"
        address_prefixes                = ["10.0.0.0/28"]
        network_security_group          = "management"
        route_table                     = "management"
        enable_storage_service_endpoint = true
      }
      "private" = {
        name             = "private-snet"
        address_prefixes = ["10.0.0.16/28"]
        route_table      = "private"
      }
      "public" = {
        name                   = "public-snet"
        address_prefixes       = ["10.0.0.32/28"]
        network_security_group = "public"
        route_table            = "public"
      }
      "appgw" = {
        name             = "appgw-snet"
        address_prefixes = ["10.0.0.48/28"]
      }
    }
  }
}