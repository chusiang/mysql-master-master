use DBI;

sub PerformCheck($$) {
    my $timeout = shift;
    my $host = shift;
    
    # get connection info
    my $peer = $config->{host}->{$host};
    if (ref($peer) ne 'HASH') {
        return "ERROR: Invalid host!";
    }

    my $host = $peer->{ip};
    my $port = $peer->{port};
    my $user = $peer->{user};
    my $pass = $peer->{password};

    my $res = eval {
        local $SIG{ALRM} = sub { die "TIMEOUT"; };
        alarm($timeout);
        
        # connect to server
        my $dsn = "DBI:mysql:host=$host;port=$port;mysql_connect_timeout=$timeout";
        my $dbh = DBI->connect($dsn, $user, $pass, { PrintError => 0 });

        # destroy the password once it is not needed to prevent it from showing up in the alert messages
        $pass =~ s/./x/g;

        return "UNKNOWN: Connect error (host = $host:$port, user = $user, pass = '$pass')! " . DBI::errstr unless ($dbh);
    
        # Check server (replication backlog)
        my $sth = $dbh->prepare("SHOW SLAVE STATUS");
        my $res = $sth->execute;

        if ($dbh->err) {
            my $ret = "UNKNOWN: Unknown state. Execute error: " . $dbh->errstr;
            $sth->finish;
            $dbh->disconnect();
            $dbh = undef;
            return $ret;
        }

        unless($res) {
            $sth->finish;
            $dbh->disconnect();
            $dbh = undef;
            return "ERROR: Replication is not running";
        }
    
        my $status = $sth->fetchrow_hashref;
        $sth->finish;
        $dbh->disconnect();
        $dbh = undef;
    
        # Check backlog size
        my $backlog = $status->{Seconds_Behind_Master};

        return "OK: Backlog is null" if ($backlog eq '');
        return "ERROR: Backlog is too big" if ($backlog > $config->{check}->{rep_backlog}->{max_backlog});
        return 0;
    };
    alarm(0);

    return $res if ($res);
    return 'ERROR: Timeout' if ($@ =~ /^TIMEOUT/);    
    return "ERROR: Error occurred: $@" if ($@ =~ /^ERROR/);
    return "UNKNOWN: Problem occurred: $@" if $@;
    return "OK";
}

1;
