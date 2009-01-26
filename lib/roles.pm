#-----------------------------------------------------------------
sub ClearIP($) {
    my $ip = shift;
    return ExecuteBin("clear_ip", "$ip $config->{cluster_interface}");
}

#-----------------------------------------------------------------
sub CheckIP($) {
    my $ip = shift;
    return ExecuteBin("check_ip",  "$ip $config->{cluster_interface}");
}

#-----------------------------------------------------------------
sub AllowWrite() {
    return ExecuteBin("mysql_allow_write");
}

#-----------------------------------------------------------------
sub DenyWrite() {
    return ExecuteBin("mysql_deny_write");
}

#-----------------------------------------------------------------
sub SyncWithMaster() {
    return ExecuteBin("sync_with_master");
}

1;
