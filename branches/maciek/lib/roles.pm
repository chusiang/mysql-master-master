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
    return ExecuteBin("mysql_allow_write", "'$MMM_CONFIG'");
}

#-----------------------------------------------------------------
sub DenyWrite() {
    return ExecuteBin("mysql_deny_write", "'$MMM_CONFIG'");
}

#-----------------------------------------------------------------
sub SyncWithMaster() {
    return ExecuteBin("sync_with_master", "'$MMM_CONFIG'");
}

1;
