Операции 1 - 4 выполняются на основном и на резервном серверах.

1. Установить CentOS 6.6

2. Обновить дистрибутив:
# yum update
и перезагрузить после обновления:
# reboot

3. Отключить SELinux и IPtables:
# setenforce 0
и в файле /etc/selinux/config
SELINUX=enforcing заменить на SELINUX=disabled

/etc/init.d/iptables stop
chkconfig iptables off

5. Удостовериться, что установлен верный часовой пояс: 
# date
Sat Apr 18 08:41:57 PDT 2015
И, при необходимости, поправить:
# rm -f /etc/localtime
# ln -s /usr/share/zoneinfo/Europe/Moscow /etc/localtime
# date
Sat Apr 18 18:44:15 MSK 2015

4.Рекомендуется 
В файле /etc/host прописать IP адреса и имена основного и резервного хостов, что то типа такого:

192.168.0.109 pg01 pg01.test.local
192.168.0.112 pg02 pg02.test.local

установить, настроить (вписать в случае необходимости локальные серверы времени в файл /etc/ntp.conf) и запустить сервис ntpd:

# yum install ntp
# service ntpd start
# chkconfig ntpd on


Операция 5 выполняется ТОЛЬКО НА ОСНОВНОМ СЕРВЕРЕ.

5. Загрузить на сервер в каталог /root/depot файлы pgclsetup.sh pgclcontrol.sh cluster_config.crm pgsql
Запустить скрипт установки
# cd ~/depot
# chmod 755 pgclsetup.sh
# ./pgclsetup.sh <пароль пользователя postgres> <имя или адрес удаленного (резервного) сервера> <кластерный IP адрес, на который будут коннектиться клиенты> <IP адрес маршрутизатора по умолчанию, либо любого доступного для пинга хоста>
например
# ./setup_cluster.sh password pg02 192.168.0.125 192.168.0.1

В процессе установки необходимо будет ввести пароль пользователя root резервного сервера.

Ошибки и нештатные ситуации:


1. Если по каким либо причинам отпал, на время вышел из строя или был восстановлен с резервной копии резервный сервер:
 - убедиться, что основной сервер доступен и работает/usr/bin/pgclcontrol.sh status
 - включить в кластер резервный сервер: /usr/bin/pgclcontrol.sh recovery
 - проверить статус кластера /usr/bin/pgclcontrol.sh status
 - проверить состояние postgres: tail -f /var/lib/pgsql/9.3/data/pg_log/postgresql-<день недели>.log 

2.Если по каким либо причинам отпал, на время или полностью вышел из строя основной сервер:
 - убедиться, что произошло переключение на резервный сервер и теперь резервный сервер является мастером: /usr/bin/pgclcontrol.sh status 
 - восстановить вышедший из строя сервер с резервной копии, если нужно
 - превратить его  в резервный: /usr/bin/pgclcontrol.sh recovery
 - проверить статус кластера /usr/bin/pgclcontrol.sh status
 - проверить состояние postgres: tail -f /var/lib/pgsql/9.3/data/pg_log/postgresql-<день недели>.log 

3. Перемещение мастер-сервера на другой хост:
 - убедиться, что репликация между серверами работает: /usr/bin/pgclcontrol.sh status
 - выполнить перемещение: /usr/bin/pgclcontrol.sh switchover

4. Если вышли из строя или отключались оба сервера одновременно, и после старта оба находятся в состоянии STOP:
 - на обоих хостах (последовательно) запустить /usr/bin/pgclcontrol.sh recovery
 - определить какой сервер стал резервным, проверить его состояние  /usr/bin/pgclcontrol.sh status
 - в случае необходимости, восстановить, запустив на нем /usr/bin/pgclcontrol.sh recovery
 - проверить статус кластера /usr/bin/pgclcontrol.sh status
 - проверить состояние postgres: tail -f /var/lib/pgsql/9.3/data/pg_log/postgresql-<день недели>.log 

5. Если по каким-либо причинам потерян мастер и остался только slave  в состоянии HS:alone
 - его нужно директивно назначить мастером: /usr/bin/pgclcontrol.sh setlocalhostasmaster

6. Если по каким-либо причинам потерян slave (например, было проведено восстановление согласно предыдущему пункту), то чтобы добавить новый slave в кластер, необходимо 
 - установить сервер с настройками, идентичными потерянному (имя, IP адрес)
 - загрузить на сервер в каталог /root/depot файлы pgclsetup_slave.sh pgclcontrol.sh cluster_config.crm pgsql
 - запустить скрипт установки
   # cd ~/depot
   # chmod 755 pgclsetup_slave.sh
   # ./pgclsetup_slave.sh <пароль пользователя postgres> <имя или адрес удаленного мастер сервера>
   
   В процессе установки необходимо будет ввести пароль пользователя root резервного сервера.

7. Перенос БД на кластер
 - установить кластер стандартным способом (пароль пользователя postgres должен совпадать с паролем на сервере-источнике);
 - остановить обе ноды кластера: /usr/bin/pgclcontrol.sh stop
 - удалить на обоих нодах кластера файлы блокировки: rm -f /var/lib/pgsql/9.3/tmpdir/PGSQL.lock
   Следующие действия выполняются на сервере-источнике!
 - вставить строку  "host replication postgres IP-адрес-хоста-приемника/32 trust" в файл pg_hba.conf сразу после закомментированных строк
     -- IP-адрес-хоста-приемника - IP адрес хоста, на который будет скопирована база (см след шаг)
     -- для postgres 9.3 на centos 6 файл pg_hba.conf расположен в каталоге /var/lib/pgsql/9.3/data/
 - отредактировать файл postgresql.conf (для postgres 9.3 на centos 6 файл pg_hba.conf расположен в каталоге /var/lib/pgsql/9.3/data/), раскомментировав и заменив в нем  
	#wal_level = minimal на  wal_level = hot_standby, 
	#max_wal_senders = 0 на max_wal_senders = 5 и 
	#wal_keep_segments = 0 на wal_keep_segments = 32
 - перезапустить  postgres, для postgres 9.3 на centos 6 команда на перезапуск будет: service postgresql-9.3 restart  
   Следующие действия выполняются на одной (любой) ноде кластера!
 - скопировать файл БД: /usr/bin/pgclcontrol.sh recoveryfrom <Имя-или-IP-адрес-сервер-источника>, например /usr/bin/pgclcontrol.sh recoveryfrom 10.0.0.5
 - в случае необходимости ноду нужно директивно назначить мастером: /usr/bin/pgclcontrol.sh setlocalhostasmaster
   Следующие действия выполняются на второй ноде кластера!
 - запустить ноду в режиме восстановления с мастера: /usr/bin/pgclcontrol.sh recovery

