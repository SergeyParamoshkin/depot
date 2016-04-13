#!/bin/bash 

# description: Install  standby node for cluster
##             Components: Postgres 9.3 and built-in async streaming replication; corosync 1.4.7; cman 3.0.12;
##                         pacemaker 1.1.12; pgsql RA (https://github.com/ClusterLabs/resource-agents/blob/master/heartbeat/pgsql) 
#
# v1.0, April 2015, Vadim Ponomarev <vbponomarev@gmail.com>
# - Initial version of the installation script for CentOS 6.6

# Parse arguments
if test $# -ne 2
 then
	echo "Usage: $0 <database admin password> <master host name or IP address>"
	exit 1
fi

dbpasswd=$1
db_host_1=$2

# Check parameters
if [ "$(ping -c 1 $db_host_1 2>&1 | grep unknown)" ]; then
   echo "Error: Host $db_host_1 not avaliable."
      exit 1
fi

db_host_0_name=$(uname -n)
db_host_0_ip=$(ping -c 1 $db_host_0_name | grep -Eo -m 1 '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')


# Setup passwordless login into remote db host
ssh-keygen -f ~/.ssh/id_rsa -t rsa -b 2048 -N ''
ssh-keyscan $db_host_1 >> ~/.ssh/known_hosts 
ssh-copy-id -i ~/.ssh/id_rsa.pub root@$db_host_1 

# Check parameters - II
db_host_1_name=$(ssh  root@$db_host_1 "uname -n")
db_host_0_ip_on_remote_host=$(ssh  root@$db_host_1 "ping -c 1 $db_host_0_name | grep -Eo -m 1 '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'")
db_host_1_ip=$(ping -c 1 $db_host_1_name | grep -Eo -m 1 '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')

if [ ! $(echo "$db_host_1_ip" | grep -Eo -m 1 '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}') ]; then
   echo "Error: Cannot resolve full name of the remote host (uname -n = $db_host_1_name) into IP address on the local host."
   exit 1
fi


if [ ! $(echo "$db_host_0_ip_on_remote_host" | grep -Eo -m 1 '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}') ]; then
   echo "Error: Cannot resolve full name of the local host (uname -n = $db_host_0_name) into IP address on the remote host."
   exit 1
fi

if [ "$(ssh  root@$db_host_1 "crm node show | grep $db_host_0_name")" == "" ]; then
   echo "Error: You don't have full name of the local host (uname -n = $db_host_0_name) in cluster configuration."
   exit 1
fi

# Local install and configure
## Postgress

yum -y localinstall http://yum.pgrpms.org/9.3/redhat/rhel-6-x86_64/pgdg-centos93-9.3-1.noarch.rpm
yum -y install postgresql93-libs postgresql93-server postgresql93-contrib postgresql93 postgresql93-plpython uuid postgresql93-devel

chkconfig postgresql-9.3 off

echo "$dbpasswd" | passwd --stdin postgres

rm -rf /var/lib/pgsql/9.3/data
sudo -u postgres pg_basebackup -h $db_host_1_name -D /var/lib/pgsql/9.3/data/ -U postgres -v -P -X stream

cp -f ./pgclcontrol.sh /usr/bin/pgclcontrol.sh
chmod 755 /usr/bin/pgclcontrol.sh


## Clusterware 
yum -y install wget
wget -O /etc/yum.repos.d/pacemaker.repo http://clusterlabs.org/rpm-next/rhel-6/clusterlabs.repo
yum -y install pacemaker cman corosync  ccs
wget -O /etc/yum.repos.d/ha-clustering.repo http://download.opensuse.org/repositories/network:/ha-clustering:/Stable/CentOS_CentOS-6/network:ha-clustering:Stable.repo
echo "includepkgs=crmsh pssh python-pssh" >> /etc/yum.repos.d/ha-clustering.repo
yum -y install crmsh

## Pacemaker RA pgsql
cp -f pgsql /usr/lib/ocf/resource.d/heartbeat/
chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgsql

## Configure CMAN
scp root@$db_host_1:/etc/corosync/corosync.conf /etc/corosync/corosync.conf
scp root@$db_host_1:/etc/corosync/service.d/pcmk /etc/corosync/service.d/pcmk
scp root@$db_host_1:/etc/sysconfig/cman /etc/sysconfig/cman
scp root@$db_host_1:/etc/cluster/cluster.conf /etc/cluster/cluster.conf

# Start cluster services
service cman start
service pacemaker start
chkconfig cman on
chkconfig pacemaker on

echo -n "Now cluster is starting up"

# TODO: add some cluster checks into the body of the cycle
for ((i=1;i<=30;i++)) ; do 
    echo -n "."
    sleep 1 
done 

echo

# Let's check our cluster status
crm_mon -Afr -1

echo "Setup is done."
