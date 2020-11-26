#!/bin/bash
WORKER_IPS=()

echo '[STEP 1 - Install packages]'
apt-get update && apt-get upgrade -y && apt-get install -y lxd lxc-utils 


echo '[STEP 2 - LXD config]'
lxd init --auto
lxc network create mynet ipv6.address=none ipv4.address=10.10.10.1/24 ipv4.nat=true
lxc profile create k8s
cat k8s_profile.yaml | lxc profile edit k8s


echo '[STEP 3 - Container config]'

for instance in worker-0 worker-1 worker-2
do
	lxc launch ubuntu:18.04 ${instance} --profile k8s 2>/dev/null
	lxc stop ${instance} 2>/dev/null
	lxc network attach mynet ${instance} eth0
	lxc start ${instance}
done;

for instance in worker-0 worker-1 worker-2
do
	WORKER_IPS+=lxc list | grep ${instance} | awk '{print $6}'
done;
