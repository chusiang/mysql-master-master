#-------------------------------------------------------
sub CheckInterfaceIP($$$) {
    my $if = shift;
    my $ip = shift;
    my $check_presence = shift;
    
    my $ips;
    if ($^O eq 'linux') {
        $ips = `/sbin/ip addr show`;
        if ($? != 0) {
            print "ERROR: Checking IP address failed!\n";
            return(1);
        }
    } elsif ($^O eq 'solaris') {
        $ips = `/usr/sbin/ifconfig -a | grep inet`;
    } else {
        print "ERROR: Unsupported platform!\n";
        return(1);
    }

    my $present = ($ips =~ /$ip/) ? 1 : 0;
    if ($check_presence == $present) {
        print "OK: IP address presence check result is '$present'\n";
        return(1);
    }
}

#-------------------------------------------------------
sub ClearInterfaceIP($$) {
    my $if = shift;
    my $ip = shift;
    
    if ($^O eq 'linux') {
        `/sbin/ip addr del $ip/32 dev $if`;
        if ($? != 0) {
            print "ERROR: IP address removal failed!\n";
            return(1);
        }
    } elsif ($^O eq 'solaris') {
        `/usr/sbin/ifconfig $if removeif $ip`;
    } else {
        print "ERROR: Unsupported platform!\n";
        return(1);
    }
}

#-------------------------------------------------------
sub AddInterfaceIP($$) {
    my $if = shift;
    my $ip = shift;
    
    if ($^O eq 'linux') {
        `/sbin/ip addr add $ip/32 dev $if`;
        if ($? != 0) {
            print "ERROR: Adding IP address failed!\n";
            return(1);
        }
    } elsif ($^O eq 'solaris') {
        `/usr/sbin/ifconfig $if addif $ip`;
        my $logical_if = FindSolarisIF($ip);
        unless ($logical_if) {
            print "ERROR: Can't find logical interface with IP = $ip\n";
            exit(1);
        }
        `/usr/sbin/ifconfig $logical_if up`;
    } else {
        print "ERROR: Unsupported platform!\n";
        return(1);
    }
}

#---------------------------------------------------------------------------------
sub FindSolarisIF {
    my $ip = shift;
    my $ifconfig = `/usr/sbin/ifconfig -a`;
    $ifconfig =~ s/\n/ /g;

    while ($ifconfig =~ s/([a-z0-9\:]+)(\:\s+.*?)inet\s*([0-9\.]+)//) {
        return $1 if ($3 eq $ip);
    }
    return undef;
}


#-------------------------------------------------------
sub SendArpNotification($$) {
    my $if = shift;
    my $ip = shift;

    my $if_bcast;    
    my $if_mask;   
    
    if ($^O eq 'linux') {
        # Get path to arping
        my $arp_util = `which arping`;
        chomp($arp_util);

        if ($arp_util eq '') {
            print "ERROR: Could not find arping (result: $arp_util)!\n";
            return(1);
        }

        # Get params for arping
        my $ipaddr = `/sbin/ifconfig $if`;
        if ($? != 0) {
            print "ERROR: Could not read $if information!\n";
            return(1);
        }

        # Get broadcast address and netmask
        $ipaddr =~ /Bcast:\s*([\d\.]+)/i;
        $if_bcast = $1;

        # Execute the arping command
        my $arp_param = "";
        # Check parameters for arping
        if (`$arp_util 2>&1` =~ /\[ -S <host\/ip> \]/) {
            `$arp_util -c 3 -i $if -S $ip $if_bcast`;
            if ($? != 0) {
                print "ERROR: $arp_util failed!\n";
                return(1);
            }
        }
        elsif (`$arp_util 2>&1` =~ /\[-s source\]/) {
            `$arp_util -c 3 -U -I $if -s $ip $if_bcast`;
            if ($? != 0) {
                print "ERROR: $arp_util failed!\n";
                return(1);
            }
            `$arp_util -c 3 -A -I $if -s $ip $if_bcast`;
            if ($? != 0) {
                print "ERROR: $arp_util failed!\n";
                return(1);
            }
        } else {
            print "ERROR: Unknown arping version!\n";
            return(1);
        }
    } elsif ($^O eq 'solaris') {
        # Get params for send_arp
        my $ipaddr = `/usr/sbin/ifconfig $if`;

        # Get broadcast address and netmask
        $ipaddr =~ /netmask\s*([0-9a-f]+)\s*broadcast\s*([\d\.]+)/i;
        $if_bcast = $1;
        $if_mask = $2;
        `$SELF_DIR/bin/sys/send_arp -i 100 -r 5 -p /tmp/send_arp $if $ip auto $if_bcast $if_mask`;
    } else {
        print "ERROR: Unsupported platform!\n";
        return(1);
    }
}

#-----------------------------------------------------------------
sub GetMyIPs() {
    my @ips;

    open(IP, '/sbin/ip ad sho|');
    while(<IP>) {
        last if /^[0-9]+: $config->{cluster_interface}:/;
    }
    while(<IP>) {
        last if /^[0-9]+:/;
        next if not /inet ([0-9.]+)\//;
        push(@ips, $1);
    }
    close(IP);
    return \@ips;
}

1;
