use IO::Socket::INET;
#-------------------------------------------------------
sub CheckInterfaceIP($$$) {
    my $if = shift;
    my $hostname = shift;
    my $check_presence = shift;
    
    my $ips;
#    if ($^O eq 'linux') {
#        $ips = `/sbin/ip addr show`;
#    } elsif ($^O eq 'solaris') {
#        $ips = `/usr/sbin/ifconfig -a | grep inet`;
#    } else {
#        print "ERROR: Unsupported platform!\n";
#        exit(1);
#    }
#
#    my $present = ($ips =~ /$ip/) ? 1 : 0;
#    if ($check_presence == $present) {
#        print "OK: IP address presence check result is '$present'\n";
#        exit(0);
#    }

	if ($^O eq 'linux') {
		$ips = `dig $hostname`;
	}
	my $current_ip = GetCurrentIPAddress($if);
	my $present = ($ips =~ /$current_ip/) ? 1 : 0;
    if ($check_presence == $present) {
        print "OK: IP address presence check result is '$present'\n";
        return(1);
    }

}

#-------------------------------------------------------
sub ClearInterfaceIP($$) {
    my $if = shift;
#    my $ip = shift;
    my $hostname = shift;
    my $ip = GetCurrentIPAddress($if);
    
#    if ($^O eq 'linux') {
#        `/sbin/ip addr del $ip/32 dev $if`;
#    } elsif ($^O eq 'solaris') {
#        `/usr/sbin/ifconfig $if removeif $ip`;
#    } else {
#        print "ERROR: Unsupported platform!\n";
#        exit(1);
#    }
	$result = SendNameserverCommand("CLEARIP:$hostname:$ip");
	return($result);
}

#-------------------------------------------------------
sub AddInterfaceIP($$) {
    my $if = shift;
#    my $ip = shift;
    my $hostname = shift;
    my $ip = GetCurrentIPAddress($if);

#    if ($^O eq 'linux') {
#        `/sbin/ip addr add $ip/32 dev $if`;
#    } elsif ($^O eq 'solaris') {
#        `/usr/sbin/ifconfig $if addif $ip`;
#        my $logical_if = FindSolarisIF($ip);
#        unless ($logical_if) {
#            print "ERROR: Can't find logical interface with IP = $ip\n";
#            exit(1);
#        }
#        `/usr/sbin/ifconfig $logical_if up`;
#    } else {
#        print "ERROR: Unsupported platform!\n";
#        exit(1);
#    }

	$result = SendNameserverCommand("ADDIP:$hostname:$ip");
	return($result);

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
        # Get params for send_arp
        my $ipaddr = `/sbin/ifconfig $if`;

        # Get broadcast address and netmask
        $ipaddr =~ /Bcast:\s*([\d\.]+)\s*Mask:\s*([\d\.]+)/i;
        $if_bcast = $1;
        $if_mask = $2;
    } elsif ($^O eq 'solaris') {
        # Get params for send_arp
        my $ipaddr = `/usr/sbin/ifconfig $if`;

        # Get broadcast address and netmask
        $ipaddr =~ /netmask\s*([0-9a-f]+)\s*broadcast\s*([\d\.]+)/i;
        $if_bcast = $1;
        $if_mask = $2;
    } else {
        print "ERROR: Unsupported platform!\n";
        return(1);
    }
    `$SELF_DIR/bin/sys/send_arp -i 100 -r 5 -p /tmp/send_arp $if $ip auto $if_bcast $if_mask`;
}


#-----------------------------------------------------------------
sub GetCurrentIPAddress($) {
	my $if = shift;
	my $current_ip = `ip ad show dev $if | grep 'inet ' | awk '{sub("/.*","",\$2);print \$2;}'`;
	chop $current_ip;
	return $current_ip;
}
#-----------------------------------------------------------------
sub SendNameserverCommand($) {

	$cmd = shift;
	
	# Determine installation dir name
        our $SELF_DIR = dirname(dirname(Cwd::abs_path(__FILE__)));

        # Include parts of the system
        require $SELF_DIR . '/lib/config.pm';

	$config = ReadConfig('mmm_agent.conf');	

	my $cfg_nameservers = $config->{nameserver};
		foreach my $nameserver (sort(keys(%$cfg_nameservers))) {

			my $ns_agent_ip = $config->{nameserver}->{$nameserver}->{ip};
			my $ns_agent_port = $config->{nameserver}->{$nameserver}->{port};
			
			print("Sending Nameserver $nameserver Command: '$cmd' \n");

			my $sock = IO::Socket::INET->new(
			    PeerAddr => $ns_agent_ip,
			    PeerPort => $ns_agent_port,
			    Proto => 'tcp',
			    Timeout => 10
			);
		    return 0 unless ($sock && $sock->connected);


		    $sock->send("$cmd" . "\n");
		    my $res = <$sock>;
		    close($sock);
		}

    return $res;	

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
