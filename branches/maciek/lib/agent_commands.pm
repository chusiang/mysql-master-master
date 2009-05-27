use Algorithm::Diff;

#-----------------------------------------------------------------
sub CommandMain() {
    # shortcut
    my $this = $config->{this};

    my $new_master = '';
    my $new_roles_str;

    LogNotice('Scanning network interfaces for the existing roles...');
    my $ips= GetMyIPs();
    my $cfg_roles = $config->{role};
    foreach my $role (sort(keys(%$cfg_roles))) {
        my $my_roles = ();
        foreach $ip (@$ips) {
            next unless $cfg_roles->{$role}->{ip} =~ /[^0-9.]?$ip[^0-9.]?/;
            push(@{$my_roles->{$role}}, $ip);
        }
        if ($cfg_roles->{$role}->{mode} eq 'exclusive') {
            if ($#{$my_roles->{$role}} >= 0) {
                ExecuteBin("mysql_allow_write", "'$MMM_CONFIG'");
            } else {
                ExecuteBin("mysql_deny_write", "'$MMM_CONFIG'");
            }
        }
        $new_roles_str .= $role . '(' . join(';', @{$my_roles->{$role}}) . ';),' if $#{$my_roles->{$role}} >= 0;
    }

    if ($new_roles_str) {
        chop($new_roles_str);
        LogNotice('Restoring the following roles: ' . $new_roles_str);
        my %cmd = ('params' => [$this, 0, 'ONLINE', $new_roles_str, $new_master]);
        SetStatusCommand(\%cmd);
    }

    # Create listening socket for commands receiving
    my $sock = new IO::Socket::INET (
        LocalHost => $config->{host}->{$this}->{ip}, 
        LocalPort => $config->{bind_port}, 
        Proto => 'tcp', 
        Listen => 10, 
        Reuse => 1
    ) || die "Can't bind socket ($config->{host}->{$this}->{ip}:$config->{bind_port})!\n";
    $sock->timeout(3);
    
    die "Listener: Can't create command socket!\n" unless ($sock);
    
    while (!$shutdown) {
        LogDebug("Listener: Waiting for connection...");

        my $new_sock = $sock->accept();
        next unless ($new_sock);
        
        LogDebug("Listener: Connect!");
        while (my $cmd = <$new_sock>) {
            chomp($cmd);
            my $res = HandleCommand($cmd);
            my $uptime = GetUptime();
            $new_sock->send("$res|UP:$uptime\n");
            LogDebug("Daemon: Answer = '$res'");
            return 0 if ($shutdown);
        }
        
        close($new_sock);
        
        CheckRoles();
        
        LogDebug("Listener: Disconnect!");
    }
    
    return 0;
}


#-----------------------------------------------------------------
sub CheckRoles() {
    # Check all my roles
    foreach my $role (@server_roles) {
        ExecuteBin("agent/check_role", "'$MMM_CONFIG' '$role'");
    }
}

#-----------------------------------------------------------------
sub ParseCommand($) {
    my $cmd = shift;
    $cmd =~ /^(.*?):(.*)/;

    $command = {};
    $command->{name} = $1;

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
    $commands->{PING} = \&PingCommand;
    $commands->{SET_STATUS} = \&SetStatusCommand;
    $commands->{GET_STATUS} = \&GetStatusCommand;
    
    # Handle command
    if ($commands->{$command->{name}}) {
        return $commands->{$command->{name}}($command);
    }
    
    return "ERROR: Unknown command!";
}

#-----------------------------------------------------------------
sub PingCommand($) {
    return "OK: Pinged!";
}

#-----------------------------------------------------------------
sub GetStatusCommand($) {
    my $answer = join (':', (
        $config->{this},
        $server_version,
        $server_state,
        join(',', @server_roles),
        $active_master
    ));
    LogDebug("GetStatusCommand - result: $answer");
    return "OK: Returning status!|$answer";
}

#
#my $res = SendAgentCommand($host_name, 'SET_STATUS', $host_name, $status->{version}, $status->{state}, join(',', @roles), $master_host);
#-----------------------------------------------------------------
sub SetStatusCommand($) {
    my $cmd = shift;

    # Get params
    my $params = $cmd->{params};
    my ($host_name, $version, $new_state, $new_roles_str, $new_master) = @$params;

    LogDebug("SET_STATUS $version, $new_state, $new_roles_str, $new_master");

    # Check host name
    return "ERROR: Invalid hostname in command ($host_name)! My name is '$config->{this}'!" if ($config->{this} ne $host_name);
    
    # Check version
    if ($version < $server_version) {
        LogWarn("SetStatus: Version in command ($version) is older, than mine ($server_version)!");
    }
    
    if ($config->{host}->{$host_name}->{mode} eq 'slave' && $active_master ne $new_master && $new_state eq 'ONLINE' && $new_master ne "") {
        LogNotice("Changing active master: $new_master");
        $res = ExecuteBin("agent/set_active_master", "'$MMM_CONFIG' '$new_master'");
        LogDebug("Result: $res");
        if ($res) {
            $active_master = $new_master;
        }
    }
    
    # Parse roles
    my @new_roles = sort(split(/\,/, $new_roles_str));
    LogDebug("Old roles: " . Dumper(\@server_roles));
    LogDebug("New roles: " . Dumper(\@new_roles));
    
    # Process roles
    my @added_roles = ();
    my @deleted_roles = ();
    my $changes_count = 0;
    
    my $diff = Algorithm::Diff->new(\@server_roles, \@new_roles);
    while ($diff->Next) {
        next if ($diff->Same);

        $changes_count++;
        push (@deleted_roles, $diff->Items(1)) if ($diff->Items(1));
        push (@added_roles, $diff->Items(2)) if ($diff->Items(2));
    }
    
    if ($changes_count) {
        LogNotice("We have some new roles added or old deleted!");
        
        LogNotice("Deleted: " . Dumper(\@deleted_roles));
        LogNotice("Added: " . Dumper(\@added_roles));

        foreach my $role (@deleted_roles) {
            LogDebug("Deleting role: $role");
            $res = ExecuteBin("agent/del_role", "'$MMM_CONFIG' '$role'");
            LogDebug("Result: $res");
            if ($res =~ /^ERROR/) {
                return "ERROR: Could not delete '$role'!\n";
            }
        }

        foreach my $role (@added_roles) {
            LogDebug("Adding role: $role");
            $res = ExecuteBin("agent/add_role", "'$MMM_CONFIG' '$role'");
            if ($res =~ /^ERROR:[ ]*(.*)$/) {
                LogError("Could not add '$role'! Error message: $1");
                return "ERROR: Could not add '$role'! Error message: $1\n";
            }
        }
        
        @server_roles = @new_roles;
        LogDebug("New Server roles: " . Dumper(\@server_roles));
    }
    
    # Process state change if any
    if ($new_state ne $server_state) {
        LogNotice("Changed state! $server_state -> $new_state");
        $res = ExecuteBin("agent/set_state", "'$MMM_CONFIG' $server_state $new_state");
        LogDebug("Result: $res");

        $server_state = $new_state;
    }
    
    LogDebug("State: $server_state");
    
    return "OK: Status applied successfully!";
}

#-----------------------------------------------------------------
sub GetUptime() {
    if ($^O eq 'linux') {
        chomp(my $uptime = `cat /proc/uptime | cut -d ' ' -f 1 -`);
        return $uptime;
    }
    
    if ($^O eq 'solaris') {
        my $uptime_path = "$SELF_DIR/bin/sys/uptime_sec";
        return 0 unless (-f $uptime_path && -x $uptime_path);
        chomp(my $uptime = `$uptime_path`);
        $uptime = 0 + $uptime;
        return $uptime;
    }
    
    die("Unsupported platform - can't get uptime!\n");
}

1;
