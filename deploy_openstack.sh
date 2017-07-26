#!/bin/bash
set -e

MGMT_IP=10.14.1.216
MGMT_NETMASK=255.255.240.0
MGMT_GATEWAY=10.14.0.1
MGMT_DNS="8.8.8.8 8.8.4.4"

FIP_START=192.168.2.35
FIP_END=192.168.2.59
FIP_GATEWAY=192.168.2.1
FIP_CIDR=192.168.2.0/24
TENANT_NET_DNS="8.8.8.8 8.8.4.4"

KOLLA_INTERNAL_VIP_ADDRESS=10.14.1.254

KOLLA_BRANCH=stable/ocata
KOLLA_OPENSTACK_VERSION=4.0.0

DOCKER_NAMESPACE=kolla

sudo tee /etc/network/interfaces <<EOF
# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto eth0
iface eth0 inet static
address $MGMT_IP
netmask $MGMT_NETMASK
gateway $MGMT_GATEWAY
dns-nameservers $MGMT_DNS

auto eth1
iface eth1 inet manual
up ip link set \$IFACE up
up ip link set \$IFACE promisc on
down ip link set \$IFACE promisc off
down ip link set \$IFACE down

auto eth2
iface eth2 inet manual
up ip link set \$IFACE up
up ip link set \$IFACE promisc on
down ip link set \$IFACE promisc off
down ip link set \$IFACE down
EOF

for iface in eth0 eth1 eth2
do
    sudo ifdown $iface || true
    sudo ifup $iface
done

# Get Docker and Ansible
sudo apt-add-repository ppa:ansible/ansible -y
sudo apt-get update
sudo apt-get install -y docker.io ansible

# NTP client
sudo apt-get install -y ntp

# Remove lxd or lxc so it won't bother Docker
sudo apt-get remove -y lxd lxc

# Install Kolla
cd ~
git clone https://github.com/openstack/kolla -b $KOLLA_BRANCH
sudo apt-get install -y python-pip
sudo pip install ./kolla
sudo cp -r kolla/etc/kolla /etc/

sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/kolla.conf <<-'EOF'
[Service]
MountFlags=shared
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker

# Get the container images for the OpenStack services
sudo sed -i '/#kolla_base_distro/i kolla_base_distro: "ubuntu"' /etc/kolla/globals.yml
sudo sed -i '/#docker_namespace/i docker_namespace: "'$DOCKER_NAMESPACE'"' /etc/kolla/globals.yml
sudo sed -i '/#openstack_release/i openstack_release: "'$KOLLA_OPENSTACK_VERSION'"' /etc/kolla/globals.yml
sudo kolla-ansible pull

sudo sed -i 's/^kolla_internal_vip_address:\s.*$/kolla_internal_vip_address: "'$KOLLA_INTERNAL_VIP_ADDRESS'"/g' /etc/kolla/globals.yml
sudo sed -i '/#network_interface/i network_interface: "eth0"' /etc/kolla/globals.yml
sudo sed -i '/#neutron_external_interface/i neutron_external_interface: "eth1"' /etc/kolla/globals.yml

# kolla-ansible prechecks fails if the hostname in the hosts file is set to 127.0.1.1
MGMT_IP=$(sudo ip addr show eth0 | sed -n 's/^\s*inet \([0-9.]*\).*$/\1/p')
sudo bash -c "echo $MGMT_IP $(hostname) >> /etc/hosts"

# Generate random passwords for all OpenStack services
sudo kolla-genpwd

sudo kolla-ansible prechecks -i kolla/ansible/inventory/all-in-one
sudo kolla-ansible deploy -i kolla/ansible/inventory/all-in-one
sudo kolla-ansible post-deploy -i kolla/ansible/inventory/all-in-one

# Remove unneeded Nova containers
for name in nova_compute nova_ssh nova_libvirt
do
    for id in $(sudo docker ps -q -a -f name=$name)
    do
        sudo docker stop $id
        sudo docker rm $id
    done
done

#sudo add-apt-repository cloud-archive:newton -y && apt-get update
sudo apt-get install -y python-openstackclient

source /etc/kolla/admin-openrc.sh

wget https://cloudbase.it/downloads/cirros-0.3.4-x86_64.vhdx.gz
gunzip cirros-0.3.4-x86_64.vhdx.gz
openstack image create --public --property hypervisor_type=hyperv --disk-format vhd --container-format bare --file cirros-0.3.4-x86_64.vhdx cirros-gen1-vhdx
rm cirros-0.3.4-x86_64.vhdx

# Create the private network
neutron net-create private-net --provider:network_type vxlan
neutron subnet-create private-net 10.10.10.0/24 --name private-subnet --allocation-pool start=10.10.10.50,end=10.10.10.200 --dns-nameservers list=true $TENANT_NET_DNS --gateway 10.10.10.1

# Create the public network
neutron net-create public-net --router:external --provider:physical_network physnet1 --provider:network_type flat
neutron subnet-create public-net --name public-subnet --allocation-pool start=$FIP_START,end=$FIP_END --disable-dhcp --gateway $FIP_GATEWAY $FIP_CIDR

# Sec Group Config
neutron security-group-rule-create default --direction ingress --ethertype IPv4 --protocol icmp --remote-ip-prefix 0.0.0.0/0
neutron security-group-rule-create default --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-ip-prefix 0.0.0.0/0
# Open heat-cfn so it can run on a different host
neutron security-group-rule-create default --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 8000 --port-range-max 8000 --remote-ip-prefix 0.0.0.0/0
neutron security-group-rule-create default --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 8080 --port-range-max 8080 --remote-ip-prefix 0.0.0.0/0


# create a router and hook it the the networks
neutron router-create router1

neutron router-interface-add router1 private-subnet
neutron router-gateway-set router1 public-net

# Create sample flavors
nova flavor-create m1.nano 11 96 1 1
nova flavor-create m1.tiny 1 512 1 1
nova flavor-create m1.small 2 2048 20 1
nova flavor-create m1.medium 3 4096 40 2
nova flavor-create m1.large 5 8192 80 4
nova flavor-create m1.xlarge 6 16384 160 8
