#!/bin/bash 

# description: Install postgress 2-node active/standby cluster
##             Components: Postgres 9.3 and built-in async streaming replication; corosync 1.4.7; cman 3.0.12;
##                         pacemaker 1.1.12; pgsql RA (https://github.com/ClusterLabs/resource-agents/blob/master/heartbeat/pgsql) 
#
# v1.0, April 2015, Vadim Ponomarev <vbponomarev@gmail.com>
# - Initial version of the installation script for CentOS 6.6: without cman
# v1.1, April 2015,  Vadim Ponomarev <vbponomarev@gmail.com>
# - Version of the installation script for CentOS 6.6: with cman

# Parse arguments
if test $# -ne 4
 then
	echo "Usage: $0 <database admin password> <remote database host name or IP address> <Virtual IP address> <IP address of the default GW of any other pingable host in the local net>"
	exit 1
fi

dbpasswd=$1
db_host_1=$2
vip=$3
default_gw=$4

# Check parameters
if [ "$(ping -c 1 $db_host_1 2>&1 | grep unknown)" ]; then
   echo "Error: Host $db_host_1 not avaliable."
      exit 1
fi

if [ ! $(echo "$vip" | grep -Eo -m 1 '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}') ]; then
   echo "VIP must be IP address, not a hostname."
   exit 1
fi

if [ ! $(echo "$default_gw" | grep -Eo -m 1 '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}') ]; then
   echo "Default gw  must be IP address, not a hostname."
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


# Local install and configure
## Postgress

yum -y localinstall http://yum.pgrpms.org/9.3/redhat/rhel-6-x86_64/pgdg-centos93-9.3-1.noarch.rpm
yum -y install postgresql93-libs postgresql93-server postgresql93-contrib postgresql93 postgresql93-plpython uuid postgresql93-devel
service postgresql-9.3 initdb

echo "host replication postgres $db_host_0_ip/32 trust" >> /var/lib/pgsql/9.3/data/pg_hba.conf
echo "host replication postgres $db_host_1_ip/32 trust" >> /var/lib/pgsql/9.3/data/pg_hba.conf
echo "host all postgres 0.0.0.0/0 password" >> /var/lib/pgsql/9.3/data/pg_hba.conf


sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /var/lib/pgsql/9.3/data/postgresql.conf
sed -i "s/max_connections = 100/max_connections = 500/" /var/lib/pgsql/9.3/data/postgresql.conf
sed -i "s/#port = 5432/port = 5432/" /var/lib/pgsql/9.3/data/postgresql.conf
sed -i "s/#wal_level = minimal/wal_level = hot_standby/" /var/lib/pgsql/9.3/data/postgresql.conf
sed -i "s/#max_wal_senders = 0/max_wal_senders = 5/" /var/lib/pgsql/9.3/data/postgresql.conf
sed -i "s/#wal_keep_segments = 0/wal_keep_segments = 32/" /var/lib/pgsql/9.3/data/postgresql.conf
sed -i "s/#hot_standby = off/hot_standby = on/" /var/lib/pgsql/9.3/data/postgresql.conf 
sed -i "s/#restart_after_crash = on/restart_after_crash = off/" /var/lib/pgsql/9.3/data/postgresql.conf

chkconfig postgresql-9.3 off
service postgresql-9.3 start

echo "$dbpasswd" | passwd --stdin postgres
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$dbpasswd'" 

# Remote install
## Postgres

ssh -t root@$db_host_1 "yum -y localinstall http://yum.pgrpms.org/9.3/redhat/rhel-6-x86_64/pgdg-centos93-9.3-1.noarch.rpm " 
ssh -t root@$db_host_1 "yum -y install postgresql93-libs postgresql93-server postgresql93-contrib postgresql93 postgresql93-plpython uuid postgresql93-devel" 
ssh -t root@$db_host_1 "chkconfig postgresql-9.3 off" 
ssh -t root@$db_host_1 "echo '$dbpasswd' | passwd --stdin postgres"
ssh -t root@$db_host_1 "rm -rf /var/lib/pgsql/9.3/data"
ssh -t root@$db_host_1 "sudo -u postgres pg_basebackup -h $db_host_0_name -D /var/lib/pgsql/9.3/data/ -U postgres -v -P -X stream"


# Continue local setup
service postgresql-9.3 stop

netmask=$(ifconfig | grep -w inet | grep $db_host_0_ip | awk '{print $4}' | cut -d ":" -f 2)
bindnetaddr=$(ipcalc -n $db_host_0_ip $netmask | cut -d "=" -f 2)
cp -f ./pgclcontrol.sh /usr/bin/pgclcontrol.sh
chmod 755 /usr/bin/pgclcontrol.sh


## Clusterware 
yum -y install wget
wget -O /etc/yum.repos.d/pacemaker.repo http://clusterlabs.org/rpm-next/rhel-6/clusterlabs.repo
yum -y install pacemaker cman corosync  ccs
wget -O /etc/yum.repos.d/ha-clustering.repo http://download.opensuse.org/repositories/network:/ha-clustering:/Stable/CentOS_CentOS-6/network:ha-clustering:Stable.repo
echo "includepkgs=crmsh pssh python-pssh" >> /etc/yum.repos.d/ha-clustering.repo
yum -y install crmsh

echo "quorum {" > /etc/corosync/corosync.conf 
echo " provider: corosync_votequorum" >> /etc/corosync/corosync.conf 
echo " expected_votes: 2" >> /etc/corosync/corosync.conf 
echo "}" >> /etc/corosync/corosync.conf 
echo "aisexec {" >> /etc/corosync/corosync.conf 
echo " user: root" >> /etc/corosync/corosync.conf 
echo " group: root" >> /etc/corosync/corosync.conf 
echo "}" >> /etc/corosync/corosync.conf 
echo "service {" >> /etc/corosync/corosync.conf 
echo " name: pacemaker" >> /etc/corosync/corosync.conf 
echo " ver: 0" >> /etc/corosync/corosync.conf 
echo "}" >> /etc/corosync/corosync.conf 
echo "totem {" >> /etc/corosync/corosync.conf
echo "        version: 2" >> /etc/corosync/corosync.conf
echo "        secauth: off" >> /etc/corosync/corosync.conf
echo "        threads: 0" >> /etc/corosync/corosync.conf
echo "        transport: udpu" >> /etc/corosync/corosync.conf
echo "        interface {" >> /etc/corosync/corosync.conf
echo "                member {" >> /etc/corosync/corosync.conf
echo "                        memberaddr: $db_host_0_ip" >> /etc/corosync/corosync.conf
echo "                }" >> /etc/corosync/corosync.conf
echo "                member {" >> /etc/corosync/corosync.conf
echo "                        memberaddr: $db_host_1_ip" >> /etc/corosync/corosync.conf
echo "                }" >> /etc/corosync/corosync.conf
echo "                ringnumber: 0" >> /etc/corosync/corosync.conf
echo "                bindnetaddr: $bindnetaddr" >> /etc/corosync/corosync.conf
#echo "                mcastaddr: 239.98.1.1" >> /etc/corosync/corosync.conf
echo "                mcastport: 5500" >> /etc/corosync/corosync.conf
echo "                ttl: 1" >> /etc/corosync/corosync.conf
echo "        }" >> /etc/corosync/corosync.conf
echo "}" >> /etc/corosync/corosync.conf
echo "logging {" >> /etc/corosync/corosync.conf
echo "    to_syslog: yes" >> /etc/corosync/corosync.conf
echo "}" >> /etc/corosync/corosync.conf

echo "service {" >> /etc/corosync/service.d/pcmk
echo "        name: pacemaker" >> /etc/corosync/service.d/pcmk
echo "        ver:  0" >> /etc/corosync/service.d/pcmk
echo "}" >> /etc/corosync/service.d/pcmk

echo "CMAN_QUORUM_TIMEOUT=0" >> /etc/sysconfig/cman

## Pacemaker RA pgsql
# yum -y install wget
# wget https://raw.githubusercontent.com/ClusterLabs/resource-agents/master/heartbeat/pgsql
cp -f pgsql /usr/lib/ocf/resource.d/heartbeat/
chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgsql

## Configure CMAN
ccs -f /etc/cluster/cluster.conf --createcluster pg_cluster
ccs -f /etc/cluster/cluster.conf --addnode $db_host_0_name
ccs -f /etc/cluster/cluster.conf --addnode $db_host_1_name
ccs -f /etc/cluster/cluster.conf --addfencedev pcmk agent=fence_pcmk
ccs -f /etc/cluster/cluster.conf --addmethod pcmk-redirect $db_host_0_name
ccs -f /etc/cluster/cluster.conf --addmethod pcmk-redirect $db_host_1_name
ccs -f /etc/cluster/cluster.conf --addfenceinst pcmk $db_host_0_name pcmk-redirect port=$db_host_0_name
ccs -f /etc/cluster/cluster.conf --addfenceinst pcmk $db_host_1_name pcmk-redirect port=$db_host_1_name

# Continue remote setup

## Clusterware
ssh -t root@$db_host_1 "yum -y install wget"
ssh -t root@$db_host_1 "wget -O /etc/yum.repos.d/pacemaker.repo http://clusterlabs.org/rpm-next/rhel-6/clusterlabs.repo"
ssh -t root@$db_host_1 "yum -y install pacemaker cman corosync  ccs"
ssh -t root@$db_host_1 "wget -O /etc/yum.repos.d/ha-clustering.repo http://download.opensuse.org/repositories/network:/ha-clustering:/Stable/CentOS_CentOS-6/network:ha-clustering:Stable.repo"
ssh -t root@$db_host_1 "echo 'includepkgs=crmsh pssh python-pssh' >> /etc/yum.repos.d/ha-clustering.repo"
ssh -t root@$db_host_1 "yum -y install crmsh"
scp /etc/corosync/corosync.conf  root@$db_host_1:/etc/corosync/corosync.conf
scp /etc/corosync/service.d/pcmk  root@$db_host_1:/etc/corosync/service.d/pcmk
scp /etc/sysconfig/cman  root@$db_host_1:/etc/sysconfig/cman

scp ./pgclcontrol.sh root@$db_host_1:/usr/bin/pgclcontrol.sh
ssh -t root@$db_host_1 "chmod 755 /usr/bin/pgclcontrol.sh"

## Pacemaker RA pgsql
# ssh -t root@$db_host_1 "yum -y install wget"
# ssh -t root@$db_host_1 "wget https://raw.githubusercontent.com/ClusterLabs/resource-agents/master/heartbeat/pgsql"
scp pgsql root@$db_host_1:/usr/lib/ocf/resource.d/heartbeat/pgsql
# ssh -t root@$db_host_1 "cp -f pgsql /usr/lib/ocf/resource.d/heartbeat/"
ssh -t root@$db_host_1 "chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgsql"

## Configure CMAN
scp /etc/cluster/cluster.conf root@$db_host_1:/etc/cluster/cluster.conf

# Start both local and remote cluster services
service cman start
service pacemaker start
chkconfig cman on
chkconfig pacemaker on
ssh -t root@$db_host_1 "service cman start"
ssh -t root@$db_host_1 "service pacemaker start"
ssh -t root@$db_host_1 "chkconfig cman on"
ssh -t root@$db_host_1 "chkconfig pacemaker on"


# Configure pacemaker
sed -i "s/ ip=\"vip\"/ ip=\"$vip\"/"  ./cluster_config.crm
sed -i "s/master_ip=\"vip\"/master_ip=\"$vip\"/"  ./cluster_config.crm
sed -i "s/node_list=\"node1 node2\"/node_list=\"$db_host_0_name $db_host_1_name\"/"  ./cluster_config.crm
sed -i "s/ host_list=\"default_gw\"/ host_list=\"$default_gw\"/"  ./cluster_config.crm
crm configure load update  ./cluster_config.crm

echo -n "Now cluster is starting up"

# TODO: add some cluster checks into the body of the cycle
for ((i=1;i<=60;i++)) ; do 
    echo -n "."
    sleep 1 
done 

echo

# Let's check our cluster status
crm_mon -Afr -1

echo "Setup is done."
