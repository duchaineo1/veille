#!/bin/bash

CONTROLLER_IPS=()
WORKER_IPS=()
CLUSTER_IP=""
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
	lxc launch ubuntu:18.04 ${instance} --profile k8s
	sleep 10
	lxc stop ${instance}
	sleep 10
	lxc list
	lxc network attach mynet ${instance} eth0
	lxc start ${instance}
done;

sleep 30

for instance in worker-0 worker-1 worker-2
do
	WORKER_IPS+=$(lxc list | grep ${instance} | awk '{print $6}') && WORKER_IPS+=' '
done;

for instance in controller-0 controller-1 controller-2
do
        lxc launch ubuntu:18.04 ${instance} --profile k8s
        sleep 10
        lxc stop ${instance}
        sleep 10
        lxc list
        lxc network attach mynet ${instance} eth0
        lxc start ${instance}
done;

sleep 30

for instance in controller-0 controller-1 controller-2
do
        CONTROLLER_IPS+=$(lxc list | grep ${instance} | awk '{print $6}') && CONTROLLER_IPS+=' '
done;

lxc launch images:centos/7 haproxy
sleep 10
lxc stop haproxy
sleep 10
lxc network attach mynet haproxy eth0 
lxc start haproxy
sleep 20
CLUSTER_IP=$(lxc list | grep haproxy | awk '{print $6}')
echo 'Cluster IP :' ${CLUSTER_IP}
echo 'Workers IP :' ${WORKER_IPS}
echo 'Controller IP :' ${CONTROLLER_IPS}

echo '[STEP 4 - haproxy config and client tools install on host]'

lxc exec haproxy -- yum install -y haproxy

controller0_ip=$(echo $CONTROLLER_IPS | awk '{print $1}')
controller1_ip=$(echo $CONTROLLER_IPS | awk '{print $2}')
controller2_ip=$(echo $CONTROLLER_IPS | awk '{print $3}')

export controller0_ip controller1_ip controller2_ip CLUSTER_IP
envsubst < haproxy_template.cfg > haproxy.cfg
lxc file push haproxy.cfg haproxy/etc/haproxy/haproxy.cfg
lxc exec haproxy -- systemctl enable haproxy
lxc exec haproxy -- systemctl start haproxy
