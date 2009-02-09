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
        my $dsn = "DBI:mysql:host=$host;port=$port";
        my $dbh = DBI->connect($dsn, $user, $pass, { PrintError => 0 });
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

        # Check peer replication state
        if ($status->{Slave_IO_Running} eq 'No' || $status->{Slave_SQL_Running} eq 'No') {
            return "ERROR: Replication is broken";
        }
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
