notice('MODULAR: ironic/network.pp')

$network_scheme    = hiera('network_scheme', {})
prepare_network_config($network_scheme)
$network_metadata  = hiera_hash('network_metadata', {})
$neutron_config    = hiera_hash('quantum_settings')
$pnets             = $neutron_config['L2']['phys_nets']
$baremetal_vip     = $network_metadata['vips']['baremetal']['ipaddr']
$baremetal_int     = get_network_role_property('ironic/baremetal', 'interface')
$baremetal_ipaddr  = get_network_role_property('ironic/baremetal', 'ipaddr')
$baremetal_netmask = get_network_role_property('ironic/baremetal', 'netmask')
$baremetal_network = get_network_role_property('ironic/baremetal', 'network')
$nameservers       = $neutron_config['predefined_networks']['net04']['L3']['nameservers']

$ironic_hash       = hiera_hash('fuel-plugin-ironic', {})
$baremetal_L3_allocation_pool = $ironic_hash['l3_allocation_pool']
$baremetal_L3_gateway = $ironic_hash['l3_gateway']


# Firewall
###############################
firewallchain { 'baremetal:filter:IPv4':
  ensure => present,
} ->
firewall { '100 allow ping from VIP':
  chain       => 'baremetal',
  source      => $baremetal_vip,
  destination => $baremetal_ipaddr,
  proto       => 'icmp',
  icmp        => 'echo-request',
  action      => 'accept',
} ->
firewall { '999 drop all':
  chain  => 'baremetal',
  action => 'drop',
  proto  => 'all',
} ->
firewall {'00 baremetal-filter ':
  proto   => 'all',
  iniface => $baremetal_int,
  jump => 'baremetal',
  require => Class['openstack::firewall'],
}

class { 'openstack::firewall':}


# VIP
###############################
$ns_iptables_start_rules = "iptables -A INPUT -i baremetal-ns -s ${baremetal_network} -d ${baremetal_vip} -p tcp -m multiport --dports 6385,8080 -m state --state NEW -j ACCEPT; iptables -A INPUT -i baremetal-ns -s ${baremetal_network} -d ${baremetal_vip} -m state --state ESTABLISHED,RELATED -j ACCEPT; iptables -A INPUT -i baremetal-ns -j DROP"
$ns_iptables_stop_rules = "iptables -D INPUT -i baremetal-ns -s ${baremetal_network} -d ${baremetal_vip} -p tcp -m multiport --dports 6385,8080 -m state --state NEW -j ACCEPT; iptables -D INPUT -i baremetal-ns -s ${baremetal_network} -d ${baremetal_vip} -m state --state ESTABLISHED,RELATED -j ACCEPT; iptables -D INPUT -i baremetal-ns -j DROP"
$baremetal_vip_data = {
  namespace      => 'haproxy',
  nic            => $baremetal_int,
  base_veth      => 'baremetal-base',
  ns_veth        => 'baremetal-ns',
  ip             => $baremetal_vip,
  cidr_netmask   => netmask_to_cidr($baremetal_netmask),
  gateway        => 'none',
  gateway_metric => '0',
  bridge         => $baremetal_int,
  ns_iptables_start_rules => $ns_iptables_start_rules,
  ns_iptables_stop_rules  => $ns_iptables_stop_rules,
  iptables_comment        => 'baremetal-filter',
}

cluster::virtual_ip { 'baremetal' :
  vip => $baremetal_vip_data,
}


# Physnets
###############################
if $pnets['physnet1'] {
  $physnet1 = "physnet1:${pnets['physnet1']['bridge']}"
}
if $pnets['physnet2'] {
  $physnet2 = "physnet2:${pnets['physnet2']['bridge']}"
}
$physnet_ironic = "physnet-ironic:br-ironic"
$physnets_array = [$physnet1, $physnet2, $physnet_ironic]
$bridge_mappings = delete_undef_values($physnets_array)

$br_map_str = join($bridge_mappings, ',')
neutron_agent_ovs {
  'ovs/bridge_mappings': value => $br_map_str;
}

$flat_networks  = ['physnet-ironic']
neutron_plugin_ml2 {
  'ml2_type_flat/flat_networks': value => join($flat_networks, ',');
}

service { 'p_neutron-plugin-openvswitch-agent':
  ensure => 'running',
  enable => true,
  provider => 'pacemaker',
}
service { 'p_neutron-dhcp-agent':
  ensure => 'running',
  enable => true,
  provider => 'pacemaker',
}

Neutron_plugin_ml2<||> ~> Service['p_neutron-plugin-openvswitch-agent'] ~> Service['p_neutron-dhcp-agent']
Neutron_agent_ovs<||> ~> Service['p_neutron-plugin-openvswitch-agent'] ~> Service['p_neutron-dhcp-agent']


# Predefined network
###############################
$netdata = {
  'L2' => {
    network_type => 'flat',
    physnet => 'physnet-ironic',
    router_ext => 'false',
    segment_id => 'null'
  },
  'L3' => {
    enable_dhcp => true,
    floating => $baremetal_L3_allocation_pool,
    gateway => $baremetal_L3_gateway,
    nameservers => $nameservers,
    subnet => $baremetal_network
  },
  'shared' => 'true',
  'tenant' => 'admin',
}

openstack::network::create_network{'baremetal':
  netdata           => $netdata,
  segmentation_type => 'flat',
} ->
neutron_router_interface { "router04:baremetal__subnet":
  ensure => present,
}


# Order
###############################
Firewall<||> -> Cluster::Virtual_ip<||> -> Neutron_plugin_ml2<||> -> Neutron_agent_ovs<||> -> Openstack::Network::Create_network<||>
