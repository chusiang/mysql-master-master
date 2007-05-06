#-----------------------------------------------------------------
sub PingCommand() {
    my $res = SendMonitorCommand("PING");
    if (!$res) {
        print "\n\nWARNING!!! DAEMON IS NOT RUNNING. INFORMATION MAY NOT BE ACTUAL!!!\n\n\n";
    } else {
        print "Daemon is running!\n";
    }
}


#-----------------------------------------------------------------
sub ShowCommand() {
    PingCommand();
    
    my $saved_status = LoadServersStatus();
    print "Servers status:\n";
    
    foreach my $host_name (sort(keys(%$saved_status))) {
        my $host = $saved_status->{$host_name};
        my $roles = join(', ', sort(@{$host->{roles}}));
        $roles = 'None' unless ($roles);
        
        printf("  %s(%s): %s/%s. Roles: %s\n", $host_name, $config->{host}->{$host_name}->{ip}, $config->{host}->{$host_name}->{mode}, $host->{state}, $roles);
    }
}

#-----------------------------------------------------------------
sub SetOnlineCommand() {
    PingCommand();
    
    my $host = $ARGV[1];
    if (!$host) {
        print "Error! You should specify host name after command!\n";
        PrintUsage();
        exit(1);
    }
    
    $res = SendMonitorCommand('SET_ONLINE', $host);
    print "Command sent to monitoring host. Result: $res\n";
}

#-----------------------------------------------------------------
sub SetOfflineCommand() {
    PingCommand();
    
    my $host = $ARGV[1];
    if (!$host) {
        print "Error! You should specify host name after command!\n";
        PrintUsage();
        exit(1);
    }
    
    $res = SendMonitorCommand('SET_OFFLINE', $host);
    print "Command sent to monitoring host. Result: $res\n";
}


#-----------------------------------------------------------------
sub MoveRoleCommand() {
    PingCommand();
    
    my $role = $ARGV[1];
    my $host = $ARGV[2];
    if (!$role || !$host) {
        print "Error! You should specify role and host names after command!\n";
        PrintUsage();
        exit(1);
    }
    
    $res = SendMonitorCommand('MOVE_ROLE', $role, $host);
    print "Command sent to monitoring host. Result: $res\n";
}

1;
