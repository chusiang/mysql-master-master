#-----------------------------------------------------------------
sub CommandMain($$) {
    my ($command_queue, $status_queue) = @_;

    # Create listening socket for commands receiving
    my $sock = new IO::Socket::INET (
        LocalHost => $config->{monitor_ip}, 
        LocalPort => $config->{bind_port}, 
        Proto => 'tcp', 
        Listen => 10, 
        Reuse => 1
    );
    $sock->timeout(3);
    
    die "Listener: Can't create command socket!\n" unless ($sock);
    
    while (!$shutdown) {
        LogNotice("Listener: Waiting for connection...");
        my $new_sock = $sock->accept();
        next unless ($new_sock);
        
        LogDebug("Listener: Connect!");
        while (my $cmd = <$new_sock>) {
            chomp($cmd);
            my $res = HandleCommand($cmd, $status_queue);
            $new_sock->send("$res\n");
            return 0 if ($shutdown);
        }
        
        close($new_sock);
        LogNotice("Listener: Disconnect!");
    }
    
    return 0;
}

#-----------------------------------------------------------------
sub ParseCommand($) {
    my $cmd = shift;
    $cmd =~ /^(.*?):(.*)/;

    $command = {};
    $command->{name} = lc($1);

    my @params = split(':', $2);
    $command->{params} = \@params;

    return $command;
}

#-----------------------------------------------------------------
sub HandleCommand($) {
    my $cmd = shift;
    
    # Parse command
    my $command = ParseCommand($cmd);
    return "ERROR: Invalid command format!" unless ($command);
    
    # Fill command handlers
    my $commands = {};
    $commands->{ping} = \&PingCommand;
    $commands->{set_online} = \&SetOnlineCommand;
    $commands->{set_offline} = \&SetOfflineCommand;
    $commands->{move_role} = \&MoveRoleCommand;
    
    # Handle command
    if ($commands->{$command->{name}}) {
        return $commands->{$command->{name}}($command);
    }
    
    return "ERROR: Unknown command!";
}

#-----------------------------------------------------------------
sub PingCommand($) {
    return "OK: Pinged successfully!" ;
}

#-----------------------------------------------------------------
sub SetOnlineCommand($) {
    my $cmd = shift;
    
    # Get params
    my $params = $cmd->{params};
    my ($host) = @$params;

    if (!defined($servers_status->{$host})) {
        return "ERROR: Unknown host name!";
    }
    
    my $peer_name = $config->{host}->{$host}->{peer};
    my $peer = $servers_status->{$peer_name};
    my $peer_checks = $checks_status->{$peer_name};
    
    if ($servers_status->{$host}->{state} eq 'ONLINE') {
        return "OK: This server is online. So skipping command.";
    }

    unless ($servers_status->{$host}->{state} eq 'ADMIN_OFFLINE' || $servers_status->{$host}->{state} eq 'AWAITING_RECOVERY') {
        return "ERROR: This server is '$servers_status->{$host}->{state}' now. It can't be switched to online.";
    }

    if ($peer->{state} eq 'ONLINE' && (!$peer_checks->{rep_backlog} || !$peer_checks->{rep_threads})) {
        return "ERROR: Some replication checks are failed on $peer_name. We can't set $host to online state now. Please, wait some time.";
    }
    
    my $res = SendAgentCommand($host, 'PING');
    if (!$res) {
        return "ERROR: Can't reach agent daemon on '$host'! Can't switch its state!";
    }
    
    LogTrap("Daemon: Admin State change($host): $servers_status->{$host}->{state} -> ONLINE");
            
    # Lock section
    $status_sem->down;

    # Server is offline and has no roles
    $servers_status->{$host}->{state} = 'ONLINE';
            
    # Notify host about its state
    my $res = SendStatusToAgent($host);

    # Unlock section
    $status_sem->up;
    
    return "OK: State of '$host' changed to ONLINE. Now you can wait some time and check its new roles!";
}


#-----------------------------------------------------------------
sub SetOfflineCommand($) {
    my $cmd = shift;
    
    # Get params
    my $params = $cmd->{params};
    my ($host) = @$params;
    
    if (!defined($servers_status->{$host})) {
        return "ERROR: Unknown host name!";
    }
    
    if ($servers_status->{$host}->{state} eq 'ADMIN_OFFLINE') {
        return "OK: This server is already admin_offline. So skipping command.";
    }

    unless ($servers_status->{$host}->{state} eq 'ONLINE' || $servers_status->{$host}->{state} =~ /^REPLICATION_/) {
        return "ERROR: This server is '$servers_status->{$host}->{state}' at the moment. It can't be switched to admin_offline.";
    }
    
    my $res = SendAgentCommand($host, 'PING');
    if (!$res) {
        return "ERROR: Can't reach agent daemon on '$host'! Can't switch its state!";
    }
    
    LogTrap("Daemon: Admin State change($host): $servers_status->{$host}->{state} -> ADMIN_OFFLINE");
            
    # Lock section
    $status_sem->down;

    # Server is offline and has no roles
    $servers_status->{$host}->{state} = 'ADMIN_OFFLINE';

    # Clear roles list and get list of affected children
    my $affected_children = ClearServerRoles($host);
    foreach my $child (@$affected_children) {
        my $res = SendStatusToAgent($child);
	    if (!$res) {
	        LogWarn("Can't notify affected child host '$child' about parent state change");
	    }
    }
            
    # Notify host about its state
    my $res = SendStatusToAgent($host);

    # Unlock section
    $status_sem->up;
    
    return "OK: State of '$host' changed to ADMIN_OFFLINE. Now you can wait some time and check all roles!";
}


#-----------------------------------------------------------------
sub MoveRoleCommand($) {
    my $cmd = shift;
    
    # Get params
    my $params = $cmd->{params};
    my ($role, $host) = @$params;
    
    if (!defined($servers_status->{$host})) {
        return "ERROR: Unknown host name ($host)!";
    }

    if (!defined($roles->{$role})) {
        return "ERROR: Unknown role name ($host)! Valid roles are: " . join(', ', keys(%$roles));
    }

    if ($roles->{$role}->{mode} ne 'exclusive') {
        return "ERROR: move_role may be used for exclusive roles only!";
    }

    unless ($servers_status->{$host}->{state} eq 'ONLINE') {
        return "ERROR: This server is '$servers_status->{$host}->{state}' at the moment. We can't move any roles there.";
    }
    
    my $role_servers = $roles->{$role}->{servers};
    unless (grep($_ == $host, @$role_servers)) {
        return "ERROR: Host '$host' can't handle role '$role'. Only following hosts could: " . join(', ', @$role_servers);
    }
    
    my $res = SendAgentCommand($host, 'PING');
    if (!$res) {
        return "ERROR: Can't reach agent daemon on '$host'! Can't move roles there!";
    }
    
    my $old_owner = GetExclusiveRoleOwner($role);
    if ($host eq $old_owner) {
        return "OK: Role is on '$host' already. So skipping command.";
    }
    
    LogTrap("Daemon: Admin Move role($role): $old_owner -> $host");
    
    # Lock section
    $status_sem->down;
        
    # Orphan role
    my $old_owner = OrphanExclusiveRole($role);
    my $res = SendStatusToAgent($old_owner);
    
    # Server is offline and has no roles
    MoveExclusiveRole($role, $host);
            
    # Notify host about its state
    $res = SendStatusToAgent($host);

    # Unlock section
    $status_sem->up;
    
    return "OK: Role '$role' has been moved from '$old_owner' to '$host'. Now you can wait some time and check new roles info!";
}


1;
