package MMM::Monitor::Commands;

use strict;
use warnings FATAL => 'all';
use Log::Log4perl qw(:easy);
use threads;
use threads::shared;

our $VERSION = '0.01';


sub main($$) {
	my $queue_in	= shift;
	my $queue_out	= shift;

	my $socket	= MMM::Common::Socket::create_listener($main::config->{monitor}->{ip}, $main::config->{monitor}->{port});

	while (!$main::shutdown) {
		DEBUG 'Listener: Waiting for connection...';
		my $client = $socket->accept();
		next unless ($client);

		DEBUG 'Listener: Connect!';
		while (my $cmd = <$client>) {	
			chomp($cmd);
			last if ($cmd eq 'quit');

			$queue_out->enqueue($cmd);
			my $res;
			until ($res) {
				lock($queue_in);
				cond_timedwait($queue_in, time() + 1); 
				$res = $queue_in->dequeue_nb();
				return 0 if ($main::shutdown);
			}
			print $client $res;
			return 0 if ($main::shutdown);
		}

		close($client);
		DEBUG 'Listener: Disconnect!';

	}	
}

sub ping() {
	return 'OK: Pinged successfully!';
}


sub show() {
	my $agents = MMM::Monitor::Agents->instance();
	return $agents->get_status_info();
}

sub set_online($) {
	my $host	= shift;

	my $agents	= MMM::Monitor::Agents->instance();

	return "ERROR: Unknown host name '$host'!" unless (defined($main::config->{host}->{$host}));

	my $host_state = $agents->state($host);
	return "OK: This host is already ONLINE. Skipping command." if ($host_state eq 'ONLINE');

	if ($host_state eq 'ADMIN_OFFLINE' || $host_state eq 'AWAITING_RECOVERY') {
		return "ERROR: Host '$host' is '$host_state' at the moment. It can't be switched to ONLINE.";
	}

	# Check peer replication state
	if ($main::config->{host}->{$host}->{peer}) {
		my $peer = $main::config->{host}->{$host}->{peer};
		my $checks	= MMM::Monitor::ChecksStatus->instance();
		if ($agents->state($peer) eq 'ONLINE' && (!$checks->rep_threads($peer) || !$checks->rep_backlog($peer))) {
			return "ERROR: Some replication checks failed on peer '$peer'. We can't set '$host' online now. Please, wait some time.";
		}
	}

	my $agent = new MMM::Monitor::Agent::($host);
	if (!$agent->ping()) {
		return "ERROR: Can't reach agent daemon on '$host'! Can't switch its state!";
	}

	FATAL "Admin changed state of '$host' from $host_state to ONLINE";
	$agents->set_state($host, 'ONLINE');
	MMM::Monitor->instance()->send_agent_status($host);

    return "OK: State of '$host' changed to ONLINE. Now you can wait some time and check its new roles!";
}

sub set_offline($) {
	my $host	= shift;

	my $agents	= MMM::Monitor::Agents->instance();

	return "ERROR: Unknown host name '$host'!" unless (defined($main::config->{host}->{$host}));

	my $host_state = $agents->state($host);
	return "OK: This host is already ADMIN_OFFLINE. Skipping command." if ($host_state eq 'ADMIN_OFFLINE');

	unless ($host_state eq 'ONLINE' || $host_state eq 'REPLICATION_FAIL' || $host_state eq 'REPLICATION_BACKLOG') {
		return "ERROR: Host '$host' is '$host_state' at the moment. It can't be switched to ADMIN_OFFLINE.";
	}

	my $agent = new MMM::Monitor::Agent::($host);
	return "ERROR: Can't reach agent daemon on '$host'! Can't switch its state!" unless ($agent->ping());

	FATAL "Admin changed state of '$host' from $host_state to ADMIN_OFFLINE";
	$agents->set_state($host, 'ADMIN_OFFLINE');
	MMM::Monitor::Roles->instance()->clear_host_roles($host);
	MMM::Monitor->instance()->send_agent_status($host);

    return "OK: State of '$host' changed to ADMIN_OFFLINE. Now you can wait some time and check all roles!";
}

sub set_ip($$) {
	my $ip		= shift;
	my $host	= shift;

	return "ERROR: This command is only allowed in passive mode" unless (MMM::Monitor->instance()->passive);

	my $agents	= MMM::Monitor::Agents->instance();
	my $roles	= MMM::Monitor::Roles->instance();

	my $role = $roles->find_by_ip($ip);

	return "ERROR: Unknown ip '$ip'!" unless (defined($role));
	return "ERROR: Unknown host name '$host'!" unless ($agents->exists($host));

	unless ($roles->can_handle($role, $host)) {
		return "ERROR: Host '$host' can't handle role '$role'. Following hosts could: " . join(', ', @{ $roles->get_valid_hosts($role) });
	}

	my $host_state = $agents->state($host);
#	unless ($host_state eq 'ONLINE' || $host_state eq 'REPLICATION_FAIL' || $host_state eq 'REPLICATION_BACKLOG') {
	unless ($host_state eq 'ONLINE') {
		return "ERROR: Host '$host' is '$host_state' at the moment. Can't move role with ip '$ip' there.";
	}

	FATAL "Admin set role '$role($ip)' to host '$host'";

	$roles->set_role($role, $ip, $host);
	return "OK: Set role '$role($ip)' to host '$host'.";
}

sub move_role($$) {
	my $role	= shift;
	my $host	= shift;
	

	my $agents	= MMM::Monitor::Agents->instance();
	my $roles	= MMM::Monitor::Roles->instance();

	return "ERROR: Unknown role name '$role'!" unless ($roles->exists($role));
	return "ERROR: Unknown host name '$host'!" unless ($agents->exists($host));
	return "ERROR: move_role may be used for exclusive roles only!" unless ($roles->is_exclusive($role));

	my $host_state = $agents->state($host);
	return "ERROR: Can't move role to host with state $host_state." unless ($host_state eq 'ONLINE');

	unless ($roles->can_handle($role, $host)) {
        return "ERROR: Host '$host' can't handle role '$role'. Only following hosts could: " . join(', ', @{ $roles->get_valid_hosts($role) });
	}
	
	my $old_owner = $roles->get_exclusive_role_owner($role);
	return "OK: Role is on '$host' already. Skipping command." if ($old_owner eq $host);

	my $agent = new MMM::Monitor::Agent::($host);
	return "ERROR: Can't reach agent daemon on '$host'! Can't move roles there!" unless ($agent->ping());


	FATAL "Admin moved role '$role' from '$old_owner' to '$host'";

	# Assign role new host
	$roles->assign($role, $host);

	# Notify old host (if is_active_master_role($role) this will make the host non writable)
	MMM::Monitor->instance()->send_agent_status($old_owner);

	# Notify old host (this will make them switch the master)
	MMM::Monitor->instance()->notify_slaves($host) if ($roles->is_active_master_role($role));

	# Notify new host (if is_active_master_role($role) this will make the host writable)
	MMM::Monitor->instance()->send_agent_status($host);
	
	return "OK: Role '$role' has been moved from '$old_owner' to '$host'. Now you can wait some time and check new roles info!";
	
}

sub set_active() {
	return "OK: Already in active mode" unless (MMM::Monitor->instance()->passive);
	# TODO check that there are no roles on non-ONLINE hosts
	MMM::Monitor->instance()->passive(0);
	return "OK: Switched into active mode.";
}

sub set_passive() {
	return "OK: Already in passive mode" if (MMM::Monitor->instance()->passive);

	MMM::Monitor->instance()->passive(1);
	return "OK: Switched into passive mode.";
}