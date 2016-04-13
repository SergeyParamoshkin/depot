#!/bin/sh


# description: Recovery cluster node
##             Either broken slave or failed old master after failover operation  
#
# v1.0, April 2015, Vadim Ponomarev <vbponomarev@gmail.com>
# - Initial version of the script for CentOS 6.6

# Parse arguments

MASTER=$2
POSTGRE_HOME=/var/lib/pgsql/9.3/data

localnode=$(uname -n)

setlocalhostasmaster(){
	if [ -f /var/lib/pgsql/9.3/tmpdir/PGSQL.lock  ]; then
	   echo "Error: very possible this node is already master or former master. First try $0 -recoveryfrom  <hostname or IP address of the other node>."
	   exit 1
	fi
        crm_attribute -l forever -N $localnode -n "postgresql-data-status" -v "LATEST"
        crm resource cleanup msPostgresql 
        for ((i=1;i<=30;i++)) ; do
           echo -n "." 
           sleep 1
        done
        crm_mon -Afr -1
}  


recovery(){
	MASTER=$(crm node show | grep -v data-status| grep -v $localnode | cut -d ":" -f 1)
        recoveryfrom
}


recoveryfrom(){
	if [ "$MASTER" = '' ]; then
	     echo "Usage: $0 -recoveryfrom <master db host name or IP address>"
	     exit 1
	fi
	if [ ! -f /var/lib/pgsql/9.3/tmpdir/PGSQL.lock ]; then
#	       We are on slave
		crm node standby $localnode
		sleep 5
		killall -9 postgres
                DATE=$(date +%Y%m%d%H%M)
		mv -f $POSTGRE_HOME $POSTGRE_HOME$DATE/
		cd /tmp
		sudo -u postgres pg_basebackup -h $MASTER -U postgres -D $POSTGRE_HOME -X stream -v -P
		if [ $? -ne 0 ]; then
		   echo "DB restore failed."
		   mv -f  $POSTGRE_HOME$DATE/* $POSTGRE_HOME/
		   rm -rf $POSTGRE_HOME$DATE
                   crm node online  $localnode
		   exit 1
		fi
		crm node online  $localnode
		crm resource cleanup  msPostgresql
 	        for ((i=1;i<=15;i++)) ; do
        	   echo -n "."
         	   sleep 1
   	    	done
        	crm_mon -Afr -1
        	echo "Done. Please, check postgres log files and node state." 
                echo " If everything is OK then you may delete old postgres data in dir $POSTGRE_HOME$DATE."
        	echo "Just run: rm -rf $POSTGRE_HOME$DATE."
	else
#	       We are on former master
 		rm -f /var/lib/pgsql/9.3/tmpdir/PGSQL.lock
		crm resource cleanup  msPostgresql	
	        for ((i=1;i<=15;i++)) ; do
    		       echo -n "." 
        	       sleep 1
    	        done
		crm_mon -Afr -1
		echo "Done. Please, check postgres log files and node state." 
	fi
}


switchover(){
        if [ -f $POSTGRE_HOME/recovery.conf ]; then
           echo "Error: this host is already slave."
           exit 1
        fi
        crm node standby $localnode
        for ((i=1;i<=15;i++)) ; do
           echo -n "." 
           sleep 1
	done
	rm -f /var/lib/pgsql/9.3/tmpdir/PGSQL.lock
	crm node online $localnode
        for ((i=1;i<=15;i++)) ; do
           echo -n "."
           sleep 1
 	done
	crm_mon -Afr -1
}


case "$1" in
  setlocalhostasmaster)
        setlocalhostasmaster
        ;;
  recoveryfrom)
        recoveryfrom
        ;;
  recovery)
        recovery
        ;;
  switchover)
        switchover
        ;;
  status)
        crm_mon -Afr -1
        ;;
  start)
        service cman start
        service pacemaker start
        crm node online $localnode
        ;;
  stop)
        crm node standby $localnode
        ;;
  *)
        echo "Usage: $0 {setlocalhostasmaster | recovery | recoveryfrom <master db host name or IP> | switchover | status | start | stop"
        echo "Commands description:"
        echo "    Basic commands:"
        echo "          start: put local node into online state;"
        echo "          stop: put local node into offline state;"
        echo "          status: show cluster status;"
        echo "          switchover: move master role from local to another host;"
        echo "          recovery: recover local node;"
        echo "    Dangerous commands (please, be careful!)"
        echo "          setlocalhostasmaster: force set local host as master;"
        echo "          recoveryfrom <master db host name or IP>: recover local node from specified master;"
        exit 1

esac

exit $?
