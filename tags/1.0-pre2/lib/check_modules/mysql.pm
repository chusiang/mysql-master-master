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
    
    # connect to server
    my $dsn = "DBI:mysql:host=$host;port=$port";
    my $dbh = DBI->connect($dsn, $user, $pass, { PrintError => 0 });
    
    return "ERROR: Connect error (host = $host:$port, user = $user, pass = '$pass')! " . DBI::errstr unless ($dbh);
    
    # Check server (simple)
    my $sth = $dbh->prepare("SELECT NOW()");
    my $res = $sth->execute;

    $sth->finish;
    $dbh->disconnect();
    $dbh = undef;

    return "ERROR: SQL Query Error: " . $dbh->errstr unless($res);
    return "OK";
}

1;
