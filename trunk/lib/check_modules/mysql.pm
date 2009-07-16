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
        
        unless ($dbh) {
            alarm(0);
            # We don't want to trigger any action because of a simple 'too many connections' error
            if (DBI::err == 1040) {
                return "UNKNOWN: Connect error (host = $host:$port, user = $user, pass = '$pass')! " . DBI::errstr;
            }
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
