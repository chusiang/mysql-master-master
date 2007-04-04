sub PerformCheck($$) {
    my ($timeout, $host) = @_;

    my $ip = $config->{host}->{$host}->{ip};
    return "ERROR: Invalid host" unless ($ip);
    
    my $res = `$SELF_DIR/bin/sys/fping -q -u -t 500 -C 1 $ip 2>&1`;
    return "ERROR" if ($res =~ /$ip.*\-$/);
    return "OK";
}

1;
