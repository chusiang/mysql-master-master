use threads;
use threads::shared;

my $is_threaded = defined(&share);

#-----------------------------------------------------------------
sub ReadConfig($) {
    my $conf_file = shift;

    # Use project's config directory if config file is not absolute
    $conf_file = $SELF_DIR . "/etc/" . $conf_file unless ($conf_file =~ /^\/.*/);
    $conf_file .= '.conf' unless ($conf_file =~ /\.conf$/);
    
    #print "Reading config file ($conf_file)...\n";
    
    open(CONF, "<$conf_file") || die("Can't read config file ($conf_file)\n");
    
    # configuration values
    my $config = ($is_threaded)? &share({}) : {};
    
    my $line = 0;
    my $section_name = "";
    my $section_type = "";
    
    while (<CONF>) {
        chomp;
        # strip whitespace from end of line
        s/\s*$//g;
        $line++;
        
        # comments and empty lines handling
        next if (/^\s*#/ || /^\s*$/);
        
        # config value handling
        if (/^(\S+)\s*(\S+)\s*$/) {
            $section_type = $1;
            $section_name = $2;
            unless (ref($config->{$section_type}) eq 'HASH') {
                $config->{$section_type} = $section_name;
            } else {
                $config->{$section_type}->{$section_name} = ($is_threaded)? &share({}) : {};
            }

            next;
        } 
        
        if (/^\s+(\S+)\s+(.*)$/) {
            unless (ref($config->{$section_type}) eq 'HASH') {
                $config->{$section_type} = ($is_threaded)? &share({}) : {};
                $config->{$section_type}->{$section_name} = ($is_threaded)? &share({}) : {};
            }
            $config->{$section_type}->{$section_name}->{$1} = $2;
            next;
        }
        
        # unresolved config line
        die("Invalid config line #$line!\n");
    }
    
    close(CONF);
    
    return $config;
}

#-----------------------------------------------------------------
sub CheckPidFile() {
    $unclean_start = 0;
    
    # Stale or active pid file
    if (-f $config->{pid_path}) {
        # Read old pid
        open(PID, $config->{pid_path}) || die "Can't open pid file '$config->{pid_path}' for reading!\n";
        chomp(my $pid = <PID>);
        if (kill(0, $pid)) {
            print "Can't run second copy of MMMD!\n";
            exit(1);
        }
        close(PID);
        $unclean_start = 1;
        print "Core: Warning: Unclean start - found stale pid file!\n";
    }

    return $unclean_start;
}

#-----------------------------------------------------------------
sub CreatePidFile() {
    # Save new pid
    open(PID, ">" . $config->{pid_path}) || die "Can't open pid file '$config->{pid_path}' for writing!\n";
    print(PID $$);
    close(PID);
}

#-----------------------------------------------------------------
sub ExecuteBin {
    my $command = shift;
    my $params = shift;
    my $return_all = shift;
    
    my $path = "$config->{bin_path}/$command";
    
    return undef unless (-x $path);
    LogDebug("Core: Execute_bin('$path $params')");
    my $res = `$path $params`;

    unless ($return_all) {
        my @lines = split /\n/, $res;
        return pop(@lines);
    }
    
    return $res
}

#-----------------------------------------------------------------
sub ExecuteLimitedBin {
    my $limit = shift;
    my $command = shift;
    my $params = shift;
    my $return_all = shift;
    
    my $path = "$config->{bin_path}/$command";
    
    return undef unless (-x $path);
    #print("Core: ExecuteLimitBin('$path $params')\n");
    my $res = `$config->{bin_path}/limit_run $limit $path $params`;

    unless ($return_all) {
        my @lines = split /\n/, $res;
        return pop(@lines);
    }
    
    return $res
}

#-----------------------------------------------------------------
sub CreateRolesList() {
    my $roles = &share({});
    
    my $cfg_roles = $config->{role};
    foreach my $role (sort(keys(%$cfg_roles))) {
        $roles->{$role} = &share({});
        $roles->{$role}->{mode} = $cfg_roles->{$role}->{mode};
	
	    # Parse servers
        my @role_servers : shared = split(/\s*\,\s*/, $cfg_roles->{$role}->{servers});
        $roles->{$role}->{hosts} = \@role_servers; 
        
	    # Link with parent role
        $roles->{$role}->{child_roles} = &share({});
	    my $parent_role = $cfg_roles->{$role}->{parent_role};
	    $roles->{$role}->{parent_role} = $parent_role;
	    if ($parent_role) {
	        $roles->{$parent_role}->{child_roles}->{$role} = 1;
	    }

        # Parse IPs
        my @ips = split(/\s*\,\s*/, $cfg_roles->{$role}->{ip});
        $roles->{$role}->{ips} = &share({});
	
        foreach my $ip (@ips) {
            my $role_ip = &share({});
            $role_ip->{ip} = $ip;
            $role_ip->{assigned_to} = ""; # orphaned by default
            $roles->{$role}->{ips}->{$ip} = $role_ip;
        }
    }

    return $roles;
}

#-----------------------------------------------------------------
sub GetServerRoles($) {
    my $host = shift;
    
    my @roles_info = ();
    foreach my $role_name (keys(%$roles)) {
        my $role = $roles->{$role_name};
        my $ips = $role->{ips};

        foreach my $ip (keys(%$ips)) {
            next unless ($ips->{$ip}->{assigned_to} eq $host);
            
            my $role_info = {};
            $role_info->{name} = $role_name;
            $role_info->{ip} = $ip;
            $role_info->{parent_host} = ($role->{parent_role} ne '')? GetExclusiveRoleOwner($role->{parent_role}) : "";
            
            push(@roles_info, $role_info);
        }
    }
    
    return \@roles_info;
}

#-----------------------------------------------------------------
sub GetActiveMaster() {
    $role = $roles->{$config->{active_master_role}};
    return '' unless $role;

    my $role_ips = $role->{ips};
        
    foreach my $ip (keys(%$role_ips)) {
        return $role_ips->{$ip}->{assigned_to};
    }
}

#-----------------------------------------------------------------
sub UpdateStatusFile() {
    open(STATUS, ">" . $config->{status_path} . '.tmp') || die "Can't open temporary status file '$config->{status_path}.tmp' for writing!\n";
    foreach my $server (keys(%$servers_status)) {
        $status = $servers_status->{$server};
        next unless $status;
        
        my $roles_info = GetServerRoles($server);
        my @roles = ();
        
        foreach my $role (@$roles_info) {
            push(@roles, sprintf("%s(%s;%s)", $role->{name}, $role->{ip}, $role->{parent_host}));
        }
        
        printf(STATUS "%s:%s:%s:%s\n", $server, $status->{version}, $status->{state}, join(',', @roles));
    }
    close(STATUS);
    rename($config->{status_path} . '.tmp', $config->{status_path}) || die "Can't savely overwrite status file '$config->{status_path}'!\n";
}


#-----------------------------------------------------------------
sub LoadServersStatus() {
    open(F, $config->{status_path}) || return {};
    my $saved_status = {};
    while (<F>) {
        chomp;
        my ($server, $version, $state, $roles) = split /:/;
        my @saved_roles = split(/\,/, $roles);
        $saved_status->{$server} = {
            'version' => $version,
            'state' => $state,
            'roles' => \@saved_roles
        };
    }
    close(F);
    return $saved_status;
}


#-----------------------------------------------------------------
sub CreateServersStatus() {
    my $saved_status = LoadServersStatus();
    
    print Dumper($saved_status);
    
    my $hosts = $config->{host};
    my $servers_status = &share({});
    
    foreach my $host (keys(%$hosts)) {
        $servers_status->{$host} = &share({});
        $servers_status->{$host}->{mode} = $hosts->{$host}->{mode};
        $servers_status->{$host}->{uptime} = 0;
        $servers_status->{$host}->{last_uptime} = 0;
        
        if ($saved_status->{$host}) {
            $servers_status->{$host}->{state} = $saved_status->{$host}->{state};
            $servers_status->{$host}->{version} = $saved_status->{$host}->{version};
            my $saved_roles = $saved_status->{$host}->{roles};
            foreach my $role (@$saved_roles) {
                AssignRole($role, $host);
            }
        } else {
            $servers_status->{$host}->{state} = HARD_OFFLINE;
            $servers_status->{$host}->{version} = 0;
        }
    }
    
    return $servers_status;
}

#-----------------------------------------------------------------
sub AssignRole($$) {
    my ($role, $host) = @_;
    print "Role: '$role'\n";
    return unless ($role);
    
    # Parse role
    $role =~ /(.*)\((.*);(.*)\)/;
    my $role_name = $1;
    my $ip = $2;
    my $parent_host = $3;
    
    unless (defined($roles->{$role_name}->{ips}->{$ip})) {
        print "Detected role change: ip '$ip' was removed from role '$role_name'\n";
        return;
    }
    print "Adding role: '$role_name' with ip '$ip'\n";
    
    $roles->{$role_name}->{ips}->{$ip}->{assigned_to} = $host;
}

#-----------------------------------------------------------------
sub ClearChildRoles($) {
    my $role_name = shift;
    my $role = $roles->{$role_name};

    # Get list of child roles
    my $child_roles = $role->{child_roles};

    my @affected_hosts;

    # And check all of them
    foreach my $child (keys(%$child_roles)) {
        my $child_ips = $roles->{$child}->{ips};
	    my @child_hosts;

	    # Check all ips of child role
	    foreach my $child_ip (keys(%$child_ips)) {
	        # And select not null records
	        next if ($child_ips->{$child_ip}->{assigned_to} eq '');
	        push(@child_hosts, $child_ips->{$child_ip}->{assigned_to});
	        $child_ips->{$child_ip}->{assigned_to} = "";
	    }
		
        LogNotice("Found dependent child role '$child'. Clearing it too. Affected hosts: " . join(',', @child_hosts));
        push(@affected_hosts, @child_hosts);
    }
    
    return \@affected_hosts;
}

#-----------------------------------------------------------------
sub ClearServerRoles($) {
    my $host = shift;
    
    my @affected_hosts;
    
    # Look through all roles
    foreach my $role_name (keys(%$roles)) {
        my $role = $roles->{$role_name};
        my $role_ips = $role->{ips};
        
	    # Check all ips
        foreach my $ip (keys(%$role_ips)) {
            my $ip_info = $role_ips->{$ip};

            # skip if assigned not to requested host
            next unless ($ip_info->{assigned_to} eq $host);
            LogNotice("Clearing role '$role_name($ip)' from host '$host'. Role '$role_name($ip)' is orphaned now!");

            my $child_hosts = ClearChildRoles($role_name);
            push(@affected_hosts, @$child_hosts);
	    
            $ip_info->{assigned_to} = "";
        }

        # Notify all slave hosts on master changes
        if ($role_name eq $config->{active_master_role}) {
            my $slaves = GetSlavesList();
    	    push(@affected_hosts, @$slaves);
        }
    }

    # find unique elements set
    my %unique;
    @unique{@affected_hosts} = ();
    @affected_hosts = keys(%unique);
    
    return \@affected_hosts;
}

#-----------------------------------------------------------------
sub GetSlavesList() {
    my @slaves;
    my $hosts = $config->{host};
    foreach my $host (keys(%$hosts)) {
        if ($hosts->{$host}->{mode} eq 'slave') {
	        push (@slaves, $host);
	    }
    }
    
    return \@slaves;
}


#-----------------------------------------------------------------
sub CountHostRoles($) {
    my $host = shift;

    my $cnt = 0;
    foreach my $role_name (keys(%$roles)) {
        my $role = $roles->{$role_name};
        my $role_ips = $role->{ips};
        
        foreach my $ip (keys(%$role_ips)) {
            my $ip_info = $role_ips->{$ip};
            next unless ($ip_info->{assigned_to} eq $host);
            $cnt++;
        }
    }
    
    return $cnt;
}

#-----------------------------------------------------------------
sub FindEligibleHost($$) {
    my ($role_name, $ip) = @_;

    my $role_hosts = $roles->{$role_name}->{hosts};

    my $min_name = "";
    my $min_count = 0;

    foreach my $host (@$role_hosts) {
        next unless ($servers_status->{$host}->{state} eq 'ONLINE');
        my $cnt = CountHostRoles($host);
        if ($cnt < $min_count || $min_name eq "") {
            $min_name = $host;
            $min_count = $cnt;
        }
    }
    
    return $min_name;
}

#-----------------------------------------------------------------
sub NotifyAffectedHosts($) {
    my $role_name = shift;
    my $role = $roles->{$role_name};
    
    # Process all child roles
    my $child_roles = $role->{child_roles};
    foreach my $child (keys(%$child_roles)) {
        LogNotice("Found dependent child role '$child'. Notifying all affected hosts...");
	    my $child_ips = $roles->{$child}->{ips};

	    # Find assigned ips
	    foreach my $child_ip (keys(%$child_ips)) {
	        next if ($child_ips->{$child_ip}->{assigned_to} eq '');
		    
	        # Notify affected host
	        LogNotice("Notifying host $child_ips->{$child_ip}->{assigned_to} about parent state change.");
	        SendStatusToAgent($child_ips->{$child_ip}->{assigned_to});
	    }
    }
}

#-----------------------------------------------------------------
sub ProcessOrphanedRoles() {
    my $cnt = 0;
    
    foreach my $role_name (keys(%$roles)) {
        my $role = $roles->{$role_name};
        my $role_ips = $role->{ips};

        # Skip child roles with orphaned parents        
	    next if (IsOrphanedRole($role->{parent_role}));
	
        foreach my $ip (keys(%$role_ips)) {
            my $ip_info = $role_ips->{$ip};
            next unless ($ip_info->{assigned_to} eq "");
            
            # Find for eligible host
            my $host = FindEligibleHost($role_name, $ip);
            
            # Skip this role if no eligible hosts found
            last unless ($host);
            
            # Assign this ip to host
            $ip_info->{assigned_to} = $host;
            LogNotice("Role '$role_name($ip)' is not orphaned now. It has beed attached to '$host'.");
	    
	        # Send notification to all affected hosts
	        NotifyAffectedHosts($role_name);	    
	    
            # Notify all slave hosts on master changes
	        if ($role_name eq $config->{active_master_role}) {
                my $slaves = GetSlavesList();
		        foreach my $slave (@$slaves) {
                    # Notify affected host
	                LogDebug("Notifying host $slave about master state change.");
	                SendStatusToAgent($slave);
		        }
            }

            $cnt++;
        }
    }
    
    return $cnt;
}

#-----------------------------------------------------------------
sub FindAllEligibleHosts($) {
    my ($role_name) = @_;

    my $role_hosts = $roles->{$role_name}->{hosts};

    my $eligible_hosts = {};

    foreach my $host (@$role_hosts) {
        next unless ($servers_status->{$host}->{state} eq 'ONLINE');
        my $cnt = CountHostRoles($host);
        $eligible_hosts->{$host} = $cnt;
    }
    
    return $eligible_hosts;
}

#-----------------------------------------------------------------
sub MoveOneRoleIP($$$) {
    my ($role_name, $host1, $host2) = @_;
    
    my $role = $roles->{$role_name};
    my $role_ips = $role->{ips};
    
    foreach my $ip (keys(%$role_ips)) {
        my $ip_info = $role_ips->{$ip};
        next unless ($ip_info->{assigned_to} eq $host1);
        LogNotice("Moving role '$role_name($ip)' from $host1 to $host2");
        $ip_info->{assigned_to} = $host2;
        last;
    }

    # Send notification to all affected hosts
    NotifyAffectedHosts($role_name);

    # Notify all slave hosts on master changes
    if ($role_name eq $config->{active_master_role}) {
        my $slaves = GetSlavesList();
        foreach my $slave (@$slaves) {
            # Notify affected host
	        LogNotice("Notifying host $slave about master state change.");
	        SendStatusToAgent($slave);
	    }
    }
}


#-----------------------------------------------------------------
sub BalanceRoles() {
    my $cnt = 0;
    
    foreach my $role_name (keys(%$roles)) {
        my $role = $roles->{$role_name};
        my $role_ips = $role->{ips};
        
        next unless ($role->{mode} eq 'balanced');

        # Skip child roles with orphaned parents
	    next if (IsOrphanedRole($role->{parent_role}));

        my $hosts = FindAllEligibleHosts($role_name);
        next if (scalar(keys(%$hosts)) < 2);
        
        while(1) {
            my $max_name = "";
            my $min_name = "";
            
            foreach my $host (keys(%$hosts)) {
                if ($max_name eq "" || $hosts->{$host} > $hosts->{$max_name}) {
                    $max_name = $host;
                }
                if ($min_name eq "" || $hosts->{$host} < $hosts->{$min_name}) {
                    $min_name = $host;
                }
            }
            
            print "MAX: $max_name = $hosts->{$max_name}\n";
            print "MIN: $min_name = $hosts->{$min_name}\n";
            
            if ($hosts->{$max_name} - $hosts->{$min_name} < 2) {
                last;
            }
            
            MoveOneRoleIP($role_name, $max_name, $min_name);
            $hosts->{$max_name}--;
            $hosts->{$min_name}++;
        }
    }
    
    return $cnt;
}

#-----------------------------------------------------------------
sub GetExclusiveRoleOwner($) {
    my ($role) = @_;
    
    my $role = $roles->{$role};
    my $role_ips = $role->{ips};
    my @all_ips = keys(%$role_ips);
    my $ip = $all_ips[0];
    return $role_ips->{$ip}->{assigned_to};
}


#-----------------------------------------------------------------
sub MoveExclusiveRole($$) {
    my ($role, $host) = @_;
    
    my $role = $roles->{$role};
    my $role_ips = $role->{ips};
    my @all_ips = keys(%$role_ips);
    my $ip = $all_ips[0];
    $role_ips->{$ip}->{assigned_to} = $host;

    # Send notification to all affected hosts
    NotifyAffectedHosts($role);

    # Notify all slave hosts on master changes
    if ($role eq $config->{active_master_role}) {
        my $slaves = GetSlavesList();
        foreach my $slave (@$slaves) {
            # Notify affected host
	        LogNotice("Notifying host $slave about master state change.");
	        SendStatusToAgent($slave);
	    }
    }
}

#-----------------------------------------------------------------
sub OrphanExclusiveRole($) {
    my $role = shift;
    
    my $role = $roles->{$role};
    my $role_ips = $role->{ips};
    my @all_ips = keys(%$role_ips);
    my $ip = $all_ips[0];
    my $old_owner = $role_ips->{$ip}->{assigned_to};
    $role_ips->{$ip}->{assigned_to} = "";

    my $child_hosts = ClearChildRoles($role);
    foreach my $child (@$child_hosts) {
        LogNotice("Notifying affected host $child about role clear.");
        SendStatusToAgent($child);
    }

    # Notify all slave hosts on master changes
    if ($role eq $config->{active_master_role}) {
        my $slaves = GetSlavesList();
        foreach my $slave (@$slaves) {
            # Notify affected host
	        LogNotice("Notifying host $slave about master state change.");
	        SendStatusToAgent($slave);
	    }
    }
    
    return $old_owner;
}

#-----------------------------------------------------------------
sub IsOrphanedRole($) {
    my $role = shift;
    
    return 0 if ($role eq '');
    
    my $role = $roles->{$role};
    my $role_ips = $role->{ips};
    my @all_ips = keys(%$role_ips);
    my $ip = $all_ips[0];
    my $old_owner = $role_ips->{$ip}->{assigned_to};

    return ($old_owner eq "");
}

1;
