
require $SELF_DIR . '/lib/socket.pm';

#-----------------------------------------------------------------
sub SendMonitorCommand {
    my $cmd = shift;
    my @params = @_;
    
    my $ip = $config->{monitor_ip};
    if (!$ip) {
        LogError("Invalid configration! Can't find monitor ip!");
        exit(0);
    }
    
    LogDebug("Sending command '$cmd(" . join(', ', @params) . ")' to $ip");
    my $sock = CreateSender($config, host => $ip);
    return 0 unless ($sock && $sock->connected);
    
    print $sock join(':', $cmd, @params) . "\n";
    my $res = <$sock>;
    close($sock);
    
    return $res;
}

#-----------------------------------------------------------------
sub SendAgentCommand {
    my $host = shift;
    my $cmd = shift;
    my @params = @_;
    
    my $status = $servers_status->{$host};
    my $check_status = $checks_status->{$host};
    
    if ($status->{state} =~ /_OFFLINE$/ && !$check_status->{ping}) {
        LogNotice("Daemon: Skipping SendAgentCommand to $host because of $status->{state} status and ping check failed");
        return "OK: Skipped!";
    }
        
    my $ip = $config->{host}->{$host}->{ip};
    if (!$ip) {
        LogError("Invalid configration! Can't find agent ip!");
        exit(0);
    }
    
    LogDebug("Sending command '$cmd(" . join(', ', @params) . ")' to $ip");
    my $sock = CreateSender($config,
        host => $ip,
        port => $config->{agent_port},
        timeout => 10,
    );
    return 0 unless ($sock && $sock->connected);
    
    print $sock join(':', $cmd, @params) . "\n";
    my $res = <$sock>;
    close($sock);
    
    return $res;
}


1;
