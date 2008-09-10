sub PerformCheck($$) {
    my ($timeout, $host) = @_;

    my $ip = $config->{host}->{$host}->{ip};
    return "ERROR: Invalid host" unless ($ip);

    # Find appropriate fping version
    my $fping_path = "$SELF_DIR/bin/sys/fping";
    chomp($fping_path = `which fping`) unless  (-f $fping_path && -x $fping_path && $^O eq 'linux');

    unless (-f $fping_path && -x $fping_path) {
        return "ERROR: fping is not functional - please, install your own version of fping on this server!";
    }
    
    my $res = `$fping_path -q -u -t 500 -C 1 $ip 2>&1`;
    return "ERROR" if ($res =~ /$ip.*\-$/);
    return "OK";
}

1;
