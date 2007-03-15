Installation
~~~~~~~~~~~~

At this moment software is installed in /opt/mmm directory, but later we will add 
there some installation script to install it to any directory on the server.

One copy of mmmd_agent process must be running on all mysql-servers of cluster.
One copy of mmmd_mon process must be running on monitoring server.


Configuration
~~~~~~~~~~~~~

Configuration file for mmmd_mon daemon and for mmm_control is /opt/mmm/mmm_mon.conf and has 
really simple structure like 

variable value
or
object_class variable_name
  param1_name param1_value
  param2_name param2_value

All configuration settings are described in config file comments (beginning with # char).

Administration
~~~~~~~~~~~~~~

In normal mode software works in background and writes all its logs to /opt/mmm/var/mmm.log.

To perform any operations with servers you can use /opt/mmm/mmm_control utility:

1) ./mmm_control show - shows all info about servers

2) ./mmm_control ping - check if local mmmd daemon is running

3) ./mmm_control set_online <host_name> - set host with host_name (as in config file) to 
                 active state if it can be done in current situation (if it is awaiting_recovery now)

4) ./mmm_control set_offline <host_name> - set host with host_name (as in config file) to 
                 admin_offline state if it can be done in current situation (if it is online now)

5) ./mmm_control move_role <role_name> <host_name> - moves exclusive rolw from one server to another.
