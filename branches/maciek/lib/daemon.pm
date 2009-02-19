#-----------------------------------------------------------------
sub DaemonMain($$) {
    my ($command_queue, $status_queue) = @_;

    while (!$shutdown) {
        LogDebug("Daemon: New iteration...");
        LogDebug("Failover method: $failover_method");

        # Processing check state change commands and etc
        my $n = ProcessCommands($command_queue);
        if ($n) {
            LogNotice("Daemon: Processed $n commands...");
            LogDebug("Daemon: Check status: " . Dumper($checks_status));
        }
        
        # Check all servers and change their states if necessary
        $status_sem->down;
        $n = CheckServersStates();
        $status_sem->up;
        
        if ($n) {
            LogNotice("Daemon: $n servers changed their states");
            LogDebug("Daemon: Servers status: " . Dumper($servers_status));
        }
        
        # Process orphaned roles and try to find eligible hosts for them
        $status_sem->down;
        $n = ProcessOrphanedRoles();
        $status_sem->up;
        
        if ($n) {
            LogNotice("Daemon: $n orphaned roles were attached to new servers");
            LogDebug("Daemon: Roles status: " . Dumper($roles));
        }

        # Process all assigned roles and try to balance them between cluster nodes
        $status_sem->down;
        $n = BalanceRoles();
        $status_sem->up;
        if ($n) {
            LogNotice("Daemon: $n assigned roles were moved to new servers");
            LogDebug("Daemon: Roles status: " . Dumper($roles));
        }
        
        # Send SET_STATUS commands to agents
        SendStatusToAgents();
        
        sleep(1);
    }

    return 0;
}

#-----------------------------------------------------------------
sub CreateCommand {
    my $command = shift;
    my @params: shared = @_;
    
    my $cmd : shared = &share({});
    $cmd->{command} = $command;
    $cmd->{params} = \@params;

    return $cmd;
}

#-----------------------------------------------------------------
sub ProcessCommands($) {
    LogDebug('ProcessCommands()');
    my $command_queue = shift;
    
    my $res = 0;
    
    while (my $command = $command_queue->dequeue_nb) {
        if (ProcessDaemonCommand($command)) {
            $res++;
        }
    }
    
    LogDebug("ProcessCommands(): $res");
    return $res;
}

#-----------------------------------------------------------------
sub ProcessDaemonCommand($) {
    my $cmd = shift;
    my $active_master_name = GetActiveMaster();

    return 0 unless ($cmd);
    
    # Command shortcuts
    my $command = $cmd->{command};
    my $params = $cmd->{params};
    
    LogDebug("---------------------------------------------------------------------------------");
    LogNotice("Status: Processing command '$cmd->{command}'");

    if ($command eq 'CHECK_OK') {
        my $host = $params->[0];
        my $check = $params->[1];
        $checks_status->{$host}->{$check} = 1;
        return 1;
    }

    if ($command eq 'CHECK_UNKNOWN') {
        my $host = $params->[0];
        my $check = $params->[1];
        $checks_status->{$host}->{$check} = -1;
        return 1;
    }

    if ($command eq 'CHECK_FAIL') {
        my $host = $params->[0];
        my $check = $params->[1];
        $checks_status->{$host}->{$check} = 0;
        return 1;
    }

    LogDebug("---------------------------------------------------------------------------------");
    return 0;
}

#-----------------------------------------------------------------
sub CheckServersStates() {
    LogDebug('CheckServersStates()');
    my $cnt = 0;
    foreach my $host_name (keys(%$servers_status)) {
        # Save status info
        UpdateStatusFile();
        
        my $peer_name = $config->{host}->{$host_name}->{peer};

        if ($peer_name eq '' && $config->{host}->{$host_name}->{mode} eq 'slave') {
            $peer_name = GetActiveMaster();
        }

        my $host = $servers_status->{$host_name};
        my $peer = $servers_status->{$peer_name};
        my $host_checks = $checks_status->{$host_name};
        
        # Simply skip this host. It is offlined by admin
        next if ($host->{state} eq 'ADMIN_OFFLINE');

        # PENDING -> =SendAgentCommand($host_name, 'GET_STATUS')
        if ($host->{state} eq 'PENDING' && $host_checks->{ping} > 0 && $host_checks->{mysql} > 0) {
            # Try to get state info from agent
            my $res = SendAgentCommand($host_name, 'GET_STATUS');
            if ($res && $res =~ /(.*)\|(.*)?\|.*UP\:(.*)/) {
                my ($remote_host, $remote_version, $remote_state, $remote_roles_str, $remote_master) = split(':', $2);
                if ($remote_state ne "UNKNOWN") {
                    LogTrap("Daemon: Restored state $remote_state and roles from agent on host $host_name");
                    $servers_status->{$host_name}->{state} = $remote_state;
                    $servers_status->{$host_name}->{state_change} = time();
                    my @remote_roles = split(',', $remote_roles_str);
                    foreach my $role (@remote_roles) {
                        my $role_name = $1 if $role =~ /^([a-z]+)\(/;
                        AssignRole($role, $host_name) if GetActiveMaster() ne '' || $roles->{$role_name}->{mode} ne 'exclusive';
                    }
                } else {
                    LogTrap("Daemon: Agent on host $host_name returned state $remote_state. Forcing HARD_OFFLINE.");
                    $servers_status->{$host_name}->{state} = 'HARD_OFFLINE';
                    $servers_status->{$host_name}->{state_change} = time();
                }
            }
            
            $cnt++;
            $next;
        }

        # AWAITING_RECOVERY -> HARD_OFFLINE
        if ($host->{state} eq 'AWAITING_RECOVERY' && (!$host_checks->{ping} || !$host_checks->{mysql})) {
            LogTrap("Daemon: State change($host_name): AWAITING_RECOVERY -> HARD_OFFLINE");
            $host->{state} = 'HARD_OFFLINE';
            $host->{state_change} = time();
            #FIXME: maybe we need to do something else?

            $cnt++;
            next;
        }
        
        # HARD_OFFLINE -> AWAITING_RECOVERY || ONLINE
        if ($host->{state} eq 'HARD_OFFLINE' && $host_checks->{ping} > 0 && $host_checks->{mysql} > 0) {
            LogTrap("Daemon: State change($host_name): HARD_OFFLINE -> AWAITING_RECOVERY");
            $host->{state} = 'AWAITING_RECOVERY';
            $host->{state_change} = time();
            #FIXME: maybe we need to do something else?

            $cnt++;
            next;
        }

        # AWAITING_RECOVERY -> ONLINE 
        if ($host->{state} eq 'AWAITING_RECOVERY' && $host_checks->{ping} > 0 
         && $host_checks->{mysql} > 0 
         && (($peer->{state} ne 'ONLINE' && defined($config->{wait_for_other_master}) 
           && $config->{wait_for_other_master} > 0 && $config->{wait_for_other_master} <= time() - $host->{status_change})
          || ($host_checks->{rep_backlog} > 0 && $host_checks->{rep_threads} > 0))) {
            my $uptime_diff = $host->{uptime} - $host->{last_uptime};
            LogDebug("AWAITING_RECOVERY state on $host_name... Uptime change is $uptime_diff");
            # If hard_offline period was short and uptime is not decreased or
            # if auto_set_online was set
            if (($host->{last_uptime} > 0 && $uptime_diff > 0 && $uptime_diff < 60)
             || (defined($config->{auto_set_online}) && $config->{auto_set_online} > 0 
              && $config->{auto_set_online} <= time() - $host->{state_change})) {
                my $status_diff = time() - $host->{status_change};
                # Server is online now
                $host->{state} = 'ONLINE';
                $host->{state_change} = time();
    
                LogTrap("Daemon: State change($host_name): AWAITING_RECOVERY -> ONLINE. Uptime diff = $uptime_diff seconds; Status change diff = $status_diff");

                # Notify host about its state
                my $res = SendStatusToAgent($host_name);
            
                $cnt++;
                next;
            }
        }
        
        # REPLICATION_FAIL || REPLICATION_DELAY -> HARD_OFFLINE
        if (($host->{state} eq 'REPLICATION_FAIL' || $host->{state} eq 'REPLICATION_DELAY')
         && (!$host_checks->{ping} || !$host_checks->{mysql})) {
            LogTrap("Daemon: State change($host_name): $host->{state} -> HARD_OFFLINE");
            $host->{state} = 'HARD_OFFLINE';
            $host->{state_change} = time();

            if ($failover_method ne 'auto') {
                next;
            }
            
            # Trying to send status to host
            my $res = SendStatusToAgent($host_name);
            if (!$res) {
                LogNotice("Can't send offline status notification to '$host_name'! Killing it!");
                $res = ExecuteBin('kill_host', $host_name);
                if (!$res) {
                    LogTrap("Daemon: Host '$host_name' went down! We could not reach the agent on it nor kill the host! There may be some duplicate ips now!!!");
                }
            }
            
            $cnt++;
            next;
        }

        # REPLICATION_FAIL -> REPLICATION_DELAY
        if ($host->{state} eq 'REPLICATION_FAIL'
         && $host_checks->{ping} > 0 && $host_checks->{mysql} > 0 && $host_checks->{rep_threads} > 0 
         && !$host_checks->{rep_backlog}) {
            LogTrap("Daemon: State change($host_name): REPLICATION_FAIL -> REPLICATION_DELAY");
            $host->{state} = 'REPLICATION_DELAY';
            $host->{state_change} = time();
            
            $cnt++;
            next;
        }

        # REPLICATION_DELAY -> REPLICATION_FAIL
        if ($host->{state} eq 'REPLICATION_DELAY' 
         && $host_checks->{ping} > 0 && $host_checks->{mysql} > 0 && !$host_checks->{rep_threads}) {
            LogTrap("Daemon: State change($host_name): REPLICATION_DELAY -> REPLICATION_FAIL");
            $host->{state} = 'REPLICATION_FAIL';
            $host->{state_change} = time();
            
            $cnt++;
            next;
        }

        # ONLINE -> HARD_OFFLINE
        if ($host->{state} eq 'ONLINE' && 
           (!$host_checks->{ping} || !$host_checks->{mysql})) {
            LogTrap("Daemon: State change($host_name): ONLINE -> HARD_OFFLINE");
            
            # Server is offline and has no roles
            $host->{state} = 'HARD_OFFLINE';
            $host->{state_change} = time();

            if ($failover_method ne 'auto') {
#                OrphanBalancedRoles($host_name) if $failover_method ne 'wait';
                next;
            }

            # Clear roles list and get list of affected children
            my $affected_children = ClearServerRoles($host_name);
            foreach my $child (@$affected_children) {
                my $res = SendStatusToAgent($child);
                if (!$res) {
                    LogWarn("Warning: Can't notify affected child host '$child' about parent state change");
                }
            }
            
            # Notify host about its state
            my $res = SendStatusToAgent($host_name);
            if (!$res) {
                LogNotice("Can't send offline status notification to '$host_name'! Killing it!");
                $res = ExecuteBin('kill_host', $host_name);
                if (!$res) {
                    LogTrap("Daemon: Host '$host_name' went down! We could not reach the agent on it nor kill the host! There may be some duplicate ips now!!!");
                }
            }
            
            $cnt++;
            next;
        }

        # ONLINE -> REPLICATION_FAIL
        if ($host->{state} eq 'ONLINE' && $peer->{state} eq 'ONLINE' && $host_checks->{ping} && $host_checks->{mysql} && !$host_checks->{rep_threads}) {
            # Prefer the active master even if any of its replication threads fail
            if ($host_name eq GetActiveMaster()) {
                LogTrap("Daemon: State change ignored, we prefer the active master($host_name): ONLINE -> REPLICATION_FAIL");
                next;
            }
            LogTrap("Daemon: State change($host_name): ONLINE -> REPLICATION_FAIL");

            # Server is offline and has no roles
            $host->{state} = 'REPLICATION_FAIL';
            $host->{state_change} = time();

            if ($failover_method ne 'auto') {
#                OrphanBalancedRoles($host_name) if $failover_method ne 'wait';
                next;
            }

            # Clear roles list and get list of affected children
            my $affected_children = ClearServerRoles($host_name);
            foreach my $child (@$affected_children) {
                my $res = SendStatusToAgent($child);
                if (!$res) {
                    LogWarn("Can't notify affected child host '$child' about parent state change");
                }
            }

            # Notify host about its state
            my $res = SendStatusToAgent($host_name);
            
            $cnt++;
            next;
        }

        # ONLINE -> REPLICATION_DELAY
        if ($host->{state} eq 'ONLINE' 
         && $peer->{state} eq 'ONLINE' 
         && $host_checks->{ping} 
         && $host_checks->{mysql} 
         && $host_checks->{rep_threads} 
         && !$host_checks->{rep_backlog} 
        ) {
            # Prefer the active master even if its replication threads fail
            if ($host_name eq GetActiveMaster()) {
                LogTrap("Daemon: State change ignored, we prefer the active master($host_name): ONLINE -> REPLICATION_DELAY");
                next;
            }
            LogTrap("Daemon: State change($host_name): ONLINE -> REPLICATION_DELAY");
            
            # Server is offline and has no roles
            $host->{state} = 'REPLICATION_DELAY';
            $host->{state_change} = time();

            if ($failover_method ne 'auto') {
#                OrphanBalancedRoles($host_name) if $failover_method ne 'wait';
                next;
            }

            # Clear roles list and get list of affected children
            my $affected_children = ClearServerRoles($host_name);
            foreach my $child (@$affected_children) {
                my $res = SendStatusToAgent($child);
                if (!$res) {
                    LogWarn("Can't notify affected child host '$child' about parent state change");
                }
            }
            
            # Notify host about its state
            my $res = SendStatusToAgent($host_name);
            
            $cnt++;
            next;
        }
        
        # REPLICATION_DELAY | REPLICATION_FAIL -> ONLINE
        if (($host->{state} eq 'REPLICATION_DELAY' || $host->{state} eq 'REPLICATION_FAIL')
         && $host_checks->{ping} > 0
         && $host_checks->{mysql} > 0
         && (($host_checks->{rep_backlog} > 0 && $host_checks->{rep_threads} > 0) || $peer->{state} ne 'ONLINE')
        ) {
            LogTrap("Daemon: State change($host_name): $host->{state} -> ONLINE");
            
            # Server is online now
            $host->{state} = 'ONLINE';
            $host->{state_change} = time();

            # Notify host about its state
            my $res = SendStatusToAgent($host_name);
            
            $cnt++;
            next;
        }
    }

    if ($failover_method eq 'wait') {
        my $master_one = $roles->{$config->{active_master_role}}->{hosts}->[0];
        my $master_two = $roles->{$config->{active_master_role}}->{hosts}->[1];
        if ($servers_status->{$master_one}->{state} eq 'ONLINE' 
         && $servers_status->{$master_two}->{state} eq 'ONLINE') {

            LogNotice("Nodes $master_one and $master_two are ONLINE, switching failover_method from 'wait' to 'auto'.");
            $failover_method = 'auto';
        }
        elsif (defined($config->{wait_for_other_master}) && $config->{wait_for_other_master} > 0
           && ($servers_status->{$master_one}->{state} eq 'ONLINE' || $servers_status->{$master_two}->{state} eq 'ONLINE')) {

            my $dead_master = ($servers_status->{$master_one}->{state} eq 'ONLINE') ? $master_two : $master_one;
            my $living_master = ($servers_status->{$master_one}->{state} eq 'ONLINE') ? $master_one : $master_two;
            if ($config->{wait_for_other_master} <= time() - $servers_status->{$living_master}->{state_change}) {

                $failover_method = 'auto';

                # Clear roles list and get list of affected children
                my $affected_children = ClearServerRoles($dead_master);
                foreach my $child (@$affected_children) {
                    my $res = SendStatusToAgent($child);
                    if (!$res) {
                       LogWarn("Warning: Can't notify affected child host '$child' about parent state change");
                    }
                }
            
                # Notify host about its state
                my $res = SendStatusToAgent($dead_master);
                if (!$res) {
                    LogNotice("Can't send offline status notification to '$dead_master'! Killing it!");
                    $res = ExecuteBin('kill_host', $dead_master);
                    if (!$res) {
                        LogTrap("Daemon: Host '$dead_master' went down! We could not reach the agent on it nor kill the host! There may be some duplicate ips now!!!");
                    }
                }
            }
        }
    }

    LogDebug("CheckServersStates(): $cnt");
    return $cnt;
}

#-----------------------------------------------------------------
sub SendStatusToAgent($) {
    my $host_name = shift;
    
    $status = $servers_status->{$host_name};
    LogDebug("Sending status to '$host_name'");
    # Don't send status to a host that has not yet been seen
    if ($status->{state} eq 'PENDING') {
         LogDebug("Sending status operation was cancelled because '$host_name' has not yet been seen");
         return;
    }

    my $roles_info = GetServerRoles($host_name);
    my @roles = ();
        
    foreach my $role (@$roles_info) {
        push(@roles, sprintf("%s(%s;%s)", $role->{name}, $role->{ip}, $role->{parent_host}));
    }

    my $master_host = GetActiveMaster();
    my $res = SendAgentCommand($host_name, 'SET_STATUS', $host_name, $status->{version}, $status->{state}, join(',', @roles), $master_host);
    if (!$res) {
        LogError("Daemon: Error sending status command to $host_name.");
    }

    if ($res =~ /(.*)\|.*UP\:(.*)/) {
        $res = $1;
        my $uptime = $2;
        LogDebug("Daemon: Got uptime from $host_name: $uptime");

        $status->{uptime} = 0 + $uptime;
        if ($status->{state} eq 'ONLINE') {
            $status->{last_uptime} = $status->{uptime};
        }

        LogDebug(Dumper($status));
    }

    return $res;
}

#-----------------------------------------------------------------
sub SendStatusToAgents() {
    foreach my $host_name (keys(%$servers_status)) {
         SendStatusToAgent($host_name);
    }
}


1;
