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
    
    eval {
        local $SIG{ALRM} = sub { die "TIMEOUT"; };
        alarm($timeout);
        
        # connect to server
        my $dsn = "DBI:mysql:host=$host;port=$port;mysql_connect_timeout=$timeout";
        my $dbh = DBI->connect($dsn, $user, $pass, { PrintError => 0 });
        
        unless ($dbh) {
            alarm(0);
            return "ERROR: Connect error (host = $host:$port, user = $user, pass = '$pass')! " . DBI::errstr;
        }
    
        # Check server (simple)
        my $sth = $dbh->prepare("SELECT NOW()");
        my $res = $sth->execute;
        unless($res) {
            alarm(0);
            return "ERROR: SQL Query Error: " . $dbh->errstr;
        }

        $sth->finish;
        $dbh->disconnect();
        $dbh = undef;

        alarm(0);
    };

    alarm(0);
    return 'ERROR: Timeout' if ($@ =~ /^TIMEOUT/);
    return "OK";
}

1;