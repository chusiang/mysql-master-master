use FileHandle;
use IPC::Open2;

#-----------------------------------------------------------------
sub SpawnCheckers() {
    my $checkers = {};
    
    $checks = $config->{check};
    foreach my $check_name (keys(%$checks)) {
        $checkers->{$check_name} = SpawnChecker($check_name);
    }
    
    return $checkers;
}

#-----------------------------------------------------------------
sub ShutdownCheckers($) {
    my $checkers = shift;
    
    foreach my $check_name (keys(%$checkers)) {
        ShutdownChecker($checkers->{$check_name});
    }
}

#-----------------------------------------------------------------
sub SpawnChecker($) {
    my $name = shift;

    my ($reader, $writer);
    LogDebug("Spawning checker '$name'...");

    my $cluster = ($cluster_name ? '@' . $cluster_name : '');
    my $pid = open2($reader, $writer, "$SELF_DIR/bin/check/checker $cluster $name");
    if (!$pid) {
        LogError("Can't spawn checker! Error: $!");
        exit(1);
    }
    
    my $checker = {
        'pid' => $pid,
        'reader' => $reader,
        'writer' => $writer
    };

    return $checker;
}

#-----------------------------------------------------------------
sub PingChecker($$) {
    my ($checker, $name) = @_;

    my $reader = $checker->{reader};
    my $writer = $checker->{writer};

    LogDebug("Pinging checker '$name'");

    my $send_res = print ($writer "ping\n");
    chomp(my $recv_res = <$reader>);
    
    if (!$send_res || !($recv_res =~ /^OK/)) {
        LogWarn("Checker '$name' is dead!");
        $checker = SpawnChecker($name);
    }

    LogDebug("Checker '$name' is OK ($recv_res)");
    return $checker;
}

#-----------------------------------------------------------------
sub ShutdownChecker($) {
    my ($checker) = @_;

    my $reader = $checker->{reader};
    my $writer = $checker->{writer};

    my $send_res = print ($writer "quit\n");
    chomp(my $recv_res = <$reader>);
    
    return 0;
}

#-----------------------------------------------------------------
sub CheckService($$) {
    my ($checker, $host) = @_;

    my $reader = $checker->{reader};
    my $writer = $checker->{writer};

    my $send_res = print ($writer "check $host\n");
    chomp(my $res = <$reader>);
    return "UNKNOWN: Checker is dead!" unless ($send_res && $res);
    return $res;
}

#-----------------------------------------------------------------
sub CreateChecksStatus() {
    my $status = &share({});

    my $active_master_name = GetActiveMaster();

    # Shortcuts
    my $checks = $config->{check};
    my $hosts = $config->{host};

    my $checkers = SpawnCheckers();
  
    # Create check result entries for all checks and all hosts
    foreach my $host (keys(%$hosts)) {
        $status->{$host} = &share({});
        foreach my $check (keys(%$checks)) {
            LogDebug("Trying initial check '$check' on host '$host'...");
        
            my $res = CheckService($checkers->{$check}, $host);
            LogError("Eval Error: $@") if $@;
            LogDebug("$check('$host') = '$res'");
            
            if ($res =~ /^OK/) {
                $status->{$host}->{$check} = 1;
            } 
            elsif ($res =~ /^UNKNOWN/) {
                $status->{$host}->{$check} = -1;
            }
            else {
                $status->{$host}->{$check} = 0;
            }
        }
    }
    
    ShutdownCheckers($checkers);
    
    return $status;
}

#-----------------------------------------------------------------
sub StartCheckerThreads($$) {
    my ($command_queue, $status_queue) = @_;

    # Shortcuts
    my $checks = $config->{check};
    
    # Start threads for all checks
    my @threads;
    foreach my $check (keys(%$checks)) {
        my $thread = new threads(\&CheckerMain, $check, $command_queue, $status_queue);
        push(@threads, $thread);
    }
    
    return \@threads;
}

#-----------------------------------------------------------------
sub CheckerMain($$$) {
    my ($check_name, $command_queue, $status_queue) = @_;

    my $checker = SpawnChecker($check_name);
    LogNotice("Checker($check_name): Started!");
    
    # Shortcut
    my $options = $config->{check}->{$check_name};
    my $hosts = $config->{host};

    # Failure counters
    my $failures = {};
    foreach my $host (keys(%$hosts)) {
        $failures->{$host} = 0;
    }
    $max_failures = $options->{trap_period} / $options->{check_period};

    # While !shutdown, performing checks
    while (!$shutdown) {
        # For all hosts
        foreach my $host (keys(%$hosts)) {
            if ($shutdown) {
                ShutdownChecker($checker);
                LogNotice("Checker($check_name): Exiting...");
                return 0;
            }

            # Ping check
            $checker = PingChecker($checker, $check_name);
            
            # Run check
            $res = CheckService($checker, $host);
            LogDebug("CHECKER: $check_name: $res");
            
            # If success
            if ($res =~ /^OK/) {
                $failures->{$host} = 0;
                if ($checks_status->{$host}->{$check_name} <= 0) {
                    LogTrap("Check: CHECK_OK('$host', '$check_name')") if $checks_status->{$host}->{$check_name} == 0;
                    LogDebug("Check: CHECK_OK('$host', '$check_name')") if $checks_status->{$host}->{$check_name} < 0;
                    $command_queue->enqueue(CreateCommand('CHECK_OK', $host, $check_name));
                }
                next;
            }

            # If unknown let's keep the status quo
            if ($res =~ /^UNKNOWN/) {
                if ($checks_status->{$host}->{$check_name} > 0) {
                    LogDebug("Check: CHECK_UNKNOWN('$host', '$check_name')  Returned message: $res");
                    $command_queue->enqueue(CreateCommand('CHECK_UNKNOWN', $host, $check_name));
                }
                next;
            }
            
            # If failed
            if ($res =~ /^ERROR/) {
                if (!$failures->{$host}) {
                    $failures->{$host} = time();
                }
                my $failure_age = time() - $failures->{$host};
                
                if ($failure_age >= $max_failures && $checks_status->{$host}->{$check_name}) {
                    LogTrap("Check: CHECK_FAIL('$host', '$check_name')  Returned message: $res");
                    $command_queue->enqueue(CreateCommand('CHECK_FAIL', $host, $check_name));
                }
                next;
            }
        }
        
        sleep($options->{check_period});
    }
    
}

#-----------------------------------------------------------------
sub ShutdownCheckerThreads($) {
    my $threads = shift;
    foreach my $thread (@$threads) {
        $thread->join();
    }
}

1;
