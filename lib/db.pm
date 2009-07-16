use DBI;

#-----------------------------------------------------------------
sub MysqlConnect($$$$) {
    my ($host, $port, $user, $pass) = @_;
    
    my $dsn = "DBI:mysql:host=$host;port=$port";
    return DBI->connect($dsn, $user, $pass, { PrintError => 0 });
}

#-----------------------------------------------------------------
sub MysqlDisconnect($) {
    my ($dbh) = @_;

    $dbh->disconnect();    
}

#-----------------------------------------------------------------
sub MysqlQuery($$) {
    my ($dbh, $query) = @_;

    LogDebug("MYSQL QUERY: $query");

    my $sth = $dbh->prepare($query);
    my $res = $sth->execute;
    return $res unless($res);

    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    return $row;
}

#-----------------------------------------------------------------
sub ExecuteQuery($$) {
    my ($dbh, $query) = @_;

    LogDebug("MYSQL EXEC: $query");

    my $sth = $dbh->prepare($query);
    return $sth->execute;
}

1;
