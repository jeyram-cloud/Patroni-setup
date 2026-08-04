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
  config.vm.network "forwarded_port", guest: 11434, host: 11434, auto_correct: true
  config.vm.network "forwarded_port", guest: 2222,    host: 2222,  auto_correct: true
  config.vm.network "forwarded_port", guest: 6379,  host: 6379,  auto_correct: true
  config.vm.network "forwarded_port", guest: 26379, host: 26379, auto_correct: true
  config.vm.network "forwarded_port", guest: 8080,  host: 8080,  auto_correct: true

  # ----------------------------------------------------------------
  # DB nodes (postnode1..6) — Postgres + Patroni
  # ----------------------------------------------------------------
  DB_NODES.each_with_index do |name, idx|
    is_etcd = ETCD_NODES.include?(name)
    ip_var = "NODE_IP_#{name}"
    ip = eval(ip_var)

    config.vm.define name.to_sym do |target_config|
      target_config.vm.host_name = name
      target_config.vm.provider "virtualbox"
      target_config.vm.network "private_network", ip: ip
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
  # LB nodes (haproxy1, haproxy2) — HAProxy + Keepalived
  # ----------------------------------------------------------------
  LB_VMS.each do |name|
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
      target_config.vm.provision :file,
        source: 'vagrant-configs/cluster.conf',
        destination: '/tmp/cluster.conf'
      target_config.vm.provision :shell, :path => 'vagrant-configs/common-setup.sh',  :args => host
      target_config.vm.provision :shell, :path => 'vagrant-configs/haproxy-setup.sh'
      target_config.vm.provision :shell, :path => 'vagrant-configs/keepalived-setup.sh', :args => host, run: "never"
    end
  end

end
