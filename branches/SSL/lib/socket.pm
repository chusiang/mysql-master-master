#-----------------------------------------------------------------
sub CreateListener {
    my ($conf, %args) = @_;

    # Create listening socket

    my $socket_class = 'IO::Socket::INET';
    my $err = sub {''};
    my %socket_opts;

    if($conf->{socket_type} and my $opt = $conf->{socket_type}{ssl}) {
        require IO::Socket::SSL;
        $socket_class = 'IO::Socket::SSL';
        %socket_opts = (
          map({'SSL_' . $_ => $opt->{$_}} keys %$opt),
          SSL_verify_mode => 0x03,
        );
        $err = sub {"\n  ", IO::Socket::SSL::errstr()};
    }
    my $sock = $socket_class->new(
        LocalHost => $args{host},
        LocalPort => $args{port} || $conf->{bind_port}, 
        Proto => 'tcp', 
        Listen => 10, 
        Reuse => 1,
        %socket_opts,
    ) or die "Listener: Can't create socket!", $err->(), "\n";

    $sock->timeout(3);
    
    return($sock);
}

#-----------------------------------------------------------------
sub CreateSender {
    my ($conf, %args) = @_;

    my $socket_class = 'IO::Socket::INET';
    my %socket_opts;

    if($conf->{socket_type} and my $opt = $conf->{socket_type}{ssl}) {
        require IO::Socket::SSL;
        $socket_class = 'IO::Socket::SSL';
        %socket_opts = (
          SSL_use_cert => 1,
          map({'SSL_' . $_ => $opt->{$_}} keys %$opt),
        );
    }

    return $socket_class->new(
        PeerAddr => $args{host},
        PeerPort => $args{port} || $config->{bind_port},
        Proto => 'tcp',
        ($args{timeout} ? (Timeout => $args{timeout}) : ()),
        %socket_opts,
    );
}

# vim:ts=4:sw=4:et:sta
1;
