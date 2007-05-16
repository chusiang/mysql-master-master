#-------------------------------------------------------
sub CheckInterfaceIP($$$) {
    my $if = shift;
    my $ip = shift;
    my $check_presence = shift;
    
    my $ips;
    if ($^O eq 'linux') {
        $ips = `/sbin/ip addr show`;
    } elsif ($^O eq 'solaris') {
        $ips = `/usr/sbin/ifconfig -a | grep inet`;
    } else {
        print "ERROR: Unsupported platform!\n";
        exit(1);
    }

    my $present = ($ips =~ /$ip/) ? 1 : 0;
    if ($check_presence == $present) {
        print "OK: IP address presence check result is '$present'\n";
        exit(0);
    }
}

#-------------------------------------------------------
sub ClearInterfaceIP($$) {
    my $if = shift;
    my $ip = shift;
    
    if ($^O eq 'linux') {
        `/sbin/ip addr del $ip/32 dev $if`;
    } elsif ($^O eq 'solaris') {
        `/usr/sbin/ifconfig $if removeif $ip`;
    } else {
        print "ERROR: Unsupported platform!\n";
        exit(1);
    }
}

#-------------------------------------------------------
sub AddInterfaceIP($$) {
    my $if = shift;
    my $ip = shift;
    
    if ($^O eq 'linux') {
        `/sbin/ip addr add $ip/32 dev $if`;
    } elsif ($^O eq 'solaris') {
        `/usr/sbin/ifconfig $if addif $ip`;
    } else {
        print "ERROR: Unsupported platform!\n";
        exit(1);
    }
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
        exit(1);
    }
    `$SELF_DIR/bin/sys/send_arp -i 100 -r 5 -p /tmp/send_arp $if $ip auto $if_bcast $if_mask`;
}

1;
