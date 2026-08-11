# -*- mode: ruby -*-
# vi: set ft=ruby :

# ----------------------------------------------------------------
# IMPORTANT: this Vagrantfile reads its IP addresses and hostnames from
# vagrant-configs/cluster.conf. To change the cluster's network layout
# (e.g. move to a different subnet), edit ONLY that file. The Vagrant
# VMs will then be created with the new IPs automatically.
#
# We shell out and source the bash file rather than use a YAML/JSON
# shim, so bash provisioners and Ruby share the exact same source of
# truth and stay byte-for-byte consistent.
# ----------------------------------------------------------------
require 'open3'

CLUSTER_CONF = File.join(__dir__, 'vagrant-configs', 'cluster.conf')
abort "cluster.conf missing at #{CLUSTER_CONF}" unless File.exist?(CLUSTER_CONF)

def bash_value(var, file = CLUSTER_CONF)
  out, _ = Open3.capture2("bash -c 'source #{file}; echo \"${#{var}}\"'")
  out.strip
end

DB_NODES = bash_value('DB_NODES[@]').split
LB_VMS   = bash_value('LB_VMS[@]').split
ETCD_NODES = bash_value('ETCD_NODES[@]').split

# Pure-DB vs. etcd-member classification.
DB_NODES.each do |n|
  eval <<~RUBY
    NODE_IP_#{n} = bash_value('NODE_IP_#{n}')
  RUBY
end
LB_VMS.each do |n|
  eval <<~RUBY
    NODE_IP_#{n}   = bash_value('NODE_IP_#{n}')
    NODE_HOST_#{n} = bash_value('NODE_HOST_#{n}')
  RUBY
end

Vagrant.configure("2") do |config|

  config.vm.provider "virtualbox" do |v|
    v.memory = 16384
    v.cpus = 2
  end


  # Every Vagrant virtual environment requires a box to build off of.
  config.vm.box = "bento/almalinux-9"
  config.ssh.username = "vagrant"

  # Forwarded-port range. Each VM grabs one unique host port from the
  # configured range. We anchor the ranges far from common service ports
  # (30000+) so 8 simultaneous VMs don't collide on a single port.
  # Range = 50000..50100 = 100 unique host ports, plenty for 8 VMs.
  config.vm.usable_port_range = 50000..50100

  DB_BASE_GUEST_PORT = 31_000  # first guest port; +N per VM
  DB_PORTS_PER_VM    = 5       # 5 forwarded ports per DB node
  LB_BASE_GUEST_PORT = 40_000  # first guest port; +N per LB node
  LB_PORTS_PER_VM    = 3       # 3 forwarded ports per LB node

  vm_seq = 0
  # ----------------------------------------------------------------
  # DB nodes — Postgres + Patroni
  # ----------------------------------------------------------------
  DB_NODES.each_with_index do |name, idx|
    is_etcd = ETCD_NODES.include?(name)
    ip_var = "NODE_IP_#{name}"
    ip = eval(ip_var)

    config.vm.define name.to_sym do |target_config|
      target_config.vm.host_name = name
      target_config.vm.provider "virtualbox"
      target_config.vm.network "private_network", ip: ip

      # Pick a deterministic base guest port for this VM and assign
      # auto-corrected host ports one-per-VM in the usable_port_range
      # above (so 8 VMs don't fight over a single base port).
      base = DB_BASE_GUEST_PORT + (idx * DB_PORTS_PER_VM)
      [
        [base,     22   ],  # SSH
        [base + 1, 5432 ],  # Postgres
        [base + 2, 8008 ],  # Patroni REST
        [base + 3, 2379 ],  # etcd client (etcd members only)
        [base + 4, 2380 ],  # etcd peer   (etcd members only)
      ].each do |guest, host_svc|
        target_config.vm.network "forwarded_port",
          guest: guest, host: guest, host_ip: "127.0.0.1",
          auto_correct: true, protocol: "tcp"
      end

      # cluster.conf MUST be present in /tmp/ before any *_setup.sh runs,
      # because every script sources it via 'CONF=/tmp/cluster.conf'.
      target_config.vm.provision :file,
        source: 'vagrant-configs/cluster.conf',
        destination: '/tmp/cluster.conf'
      target_config.vm.provision :shell, :path => 'vagrant-configs/common-setup.sh', :args => name
      if is_etcd
        target_config.vm.provision :shell, :path => 'vagrant-configs/etcd-setup.sh', :args => name, run: "never"
      end
      target_config.vm.provision :shell, :path => 'vagrant-configs/pg-setup.sh', :args => name, run: "never"
    end
  end

  # ----------------------------------------------------------------
  # LB nodes — HAProxy + Keepalived
  # ----------------------------------------------------------------
  LB_VMS.each_with_index do |name, idx|
    ip_var   = "NODE_IP_#{name}"
    host_var = "NODE_HOST_#{name}"
    ip   = eval(ip_var)
    host = eval(host_var)

    config.vm.define name.to_sym do |target_config|
      target_config.vm.host_name = host
      target_config.vm.provider "virtualbox" do |v|
        v.memory = 1024
        v.cpus = 1
      end
      target_config.vm.network "private_network", ip: ip

      base = LB_BASE_GUEST_PORT + (idx * LB_PORTS_PER_VM)
      [
        [base,     22  ],  # SSH
        [base + 1, 8080],  # HAProxy stats
        [base + 2, 80  ],  # HAProxy HTTP (if you ever add it)
      ].each do |guest, _host_svc|
        target_config.vm.network "forwarded_port",
          guest: guest, host: guest, host_ip: "127.0.0.1",
          auto_correct: true, protocol: "tcp"
      end

      target_config.vm.provision :file,
        source: 'vagrant-configs/cluster.conf',
        destination: '/tmp/cluster.conf'
      target_config.vm.provision :shell, :path => 'vagrant-configs/common-setup.sh',  :args => host
      target_config.vm.provision :shell, :path => 'vagrant-configs/haproxy-setup.sh'
      target_config.vm.provision :shell, :path => 'vagrant-configs/keepalived-setup.sh', :args => host, run: "never"
    end
  end

end
