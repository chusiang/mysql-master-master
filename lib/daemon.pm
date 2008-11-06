#-----------------------------------------------------------------
sub DaemonMain($$) {
    my ($command_queue, $status_queue) = @_;

    while (!$shutdown) {
        LogDebug("Daemon: New iteration...");
        
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
        
        # AWAITING_RECOVERY -> HARD_OFFLINE
        if ($host->{state} eq 'AWAITING_RECOVERY' && (!$host_checks->{ping} || !$host_checks->{mysql})) {
            LogTrap("Daemon: State change($host_name): AWAITING_RECOVERY -> HARD_OFFLINE");
            $host->{state} = 'HARD_OFFLINE';
            #FIXME: maybe we need to do something else?

            $cnt++;
            next;
        }
        
        # HARD_OFFLINE -> AWAITING_RECOVERY || ONLINE
        if ($host->{state} eq 'HARD_OFFLINE' && $host_checks->{ping} && $host_checks->{mysql}) {
            LogTrap("Daemon: State change($host_name): HARD_OFFLINE -> AWAITING_RECOVERY");
            $host->{state} = 'AWAITING_RECOVERY';
            #FIXME: maybe we need to do something else?

            $cnt++;
            next;
        }

        # AWAITING_RECOVERY -> ONLINE (if hard_offline period was short and uptime is not decreased)
        if ($host->{state} eq 'AWAITING_RECOVERY' && $host_checks->{ping} && $host_checks->{mysql} && $host_checks->{rep_backlog} && $host_checks->{rep_threads}) {
            my $uptime_diff = $host->{uptime} - $host->{last_uptime};
            LogDebug("AWAITING_RECOVERY state on $host_name... Uptime change is $uptime_diff");
            if ($host->{last_uptime} > 0 && $uptime_diff > 0 && $uptime_diff < 60) {
                # Server is online now
                $host->{state} = 'ONLINE';
    
                LogTrap("Daemon: State change($host_name): AWAITING_RECOVERY -> ONLINE. Uptime diff = $uptime_diff seconds");

                # Notify host about its state
                my $res = SendStatusToAgent($host_name);
            
                $cnt++;
                next;
            }
        }
        
        # REPLICATION_FAIL || REPLICATION_DELAY -> HARD_OFFLINE
        if (($host->{state} eq 'REPLICATION_FAIL' || $host->{state} eq 'REPLICATION_DELAY') && (!$host_checks->{ping} || !$host_checks->{mysql})) {
            LogTrap("Daemon: State change($host_name): $host->{state} -> HARD_OFFLINE");
            $host->{state} = 'HARD_OFFLINE';
            
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
        if ($host->{state} eq 'REPLICATION_FAIL' && $host_checks->{ping} && $host_checks->{mysql} && $host_checks->{rep_threads} && !$host_checks->{rep_backlog}) {
            LogTrap("Daemon: State change($host_name): REPLICATION_FAIL -> REPLICATION_DELAY");
            $host->{state} = 'REPLICATION_DELAY';
            
            $cnt++;
            next;
        }

        # REPLICATION_DELAY -> REPLICATION_FAIL
        if ($host->{state} eq 'REPLICATION_DELAY' && $host_checks->{ping} && $host_checks->{mysql} && $host_checks->{rep_backlog} && !$host_checks->{rep_threads}) {
            LogTrap("Daemon: State change($host_name): REPLICATION_DELAY -> REPLICATION_FAIL");
            $host->{state} = 'REPLICATION_FAIL';
            
            $cnt++;
            next;
        }

        # ONLINE -> HARD_OFFLINE
        if ($host->{state} eq 'ONLINE' && (!$host_checks->{ping} || !$host_checks->{mysql})) {
            LogTrap("Daemon: State change($host_name): ONLINE -> HARD_OFFLINE");
            
            # Server is offline and has no roles
            $host->{state} = 'HARD_OFFLINE';

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
            LogTrap("Daemon: State change($host_name): ONLINE -> REPLICATION_FAIL");
            
            # Server is offline and has no roles
            $host->{state} = 'REPLICATION_FAIL';

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
            LogTrap("Daemon: State change($host_name): ONLINE -> REPLICATION_DELAY");
            
            # Server is offline and has no roles
            $host->{state} = 'REPLICATION_DELAY';

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
         && $host_checks->{ping} 
         && $host_checks->{mysql} 
         && (($host_checks->{rep_backlog} && $host_checks->{rep_threads}) || $peer->{state} ne 'ONLINE')
        ) {
            LogTrap("Daemon: State change($host_name): $host->{state} -> ONLINE");
            
            # Server is online now
            $host->{state} = 'ONLINE';
            
            # Notify host about its state
            my $res = SendStatusToAgent($host_name);
            
            $cnt++;
            next;
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
