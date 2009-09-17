<?php

// a forking agent to listen for commands to pass to nameserver
// to be used with MMM


// load config
$config = parse_ini_file('mmm_ns_agent.conf');
$port = $config['port'];
$zoneFile = $config['zoneFile'];

$sock = socket_create_listen($port);

if ($sock)
{
	print("Daemon started, listening on $port\n");
	
	while ($new_socket = socket_accept($sock))
	{
		// fork so child handles connection
		$pid = pcntl_fork();
		if ($pid==-1)
		{
			print("ERROR: fork failed on receiving command, quitting\n");
			exit(1);
		}
		elseif ($pid)
		{
			// parent, close new socket and keep listening
			socket_close($new_socket);
			
			// clear any previously exited children that are still zombie
			while( pcntl_waitpid(-1, $status, WNOHANG) > 0 )
			{
			}
		}
		else
		{
			// child, let's handle the socket command
			$cmd = socket_read($new_socket,4096,PHP_NORMAL_READ);
			$cmd = trim($cmd);
			print("Command Received: $cmd \n");
			$cmd = explode(':',$cmd);

			switch ($cmd[0])
			{
				case 'ADDIP':
					AddIp($cmd[1],$cmd[2]);
					break;
				case 'CLEARIP':
					ClearIp($cmd[1],$cmd[2]);
					break;
				default:
					print("ERROR: Command not recognized \n");
			}
			// close socket we're done processing
			socket_close($new_socket);
			// and exit so child terminates
			exit(0);
		}
	}
	// close master
	print("Done");
	socket_close($sock);
}
else
{
	print("ERROR: Failed initializing daemon\n");
}

function AddIp($hostname,$ip)
{
	RemoveHostFromZoneFile($hostname);
	AddHostAndIpToZoneFile($hostname,$ip);
	ReloadNameserver();
}

function ClearIp($hostname,$ip)
{
	RemoveHostFromZoneFile($hostname);
	ReloadNameserver();
}

function AddHostAndIpToZoneFile($hostname,$ip)
{
	// is it safe to assume we can just echo the new host to the zone file?
	// for now let's say yes.

	global $zoneFile;

	$hostPart = GetHostPart($hostname);
	
	print("Executing: echo '$hostPart IN A $ip' >> $zoneFile \n");
	$execRet = shell_exec("echo '$hostPart IN A $ip\n' >> $zoneFile ");
	
}

function RemoveHostFromZoneFile($hostname)
{
	global $zoneFile;
	
	$hostPart = GetHostPart($hostname);

	print("Executing: sed -i.last '/$hostPart.*/d' $zoneFile \n");
    $execRet = shell_exec("sed -i.last '/$hostPart.*/d' $zoneFile");
	
}

function ReloadNameserver()
{
	// read fresh zone file contents
	global $zoneFile;
	$zoneFileContents = file_get_contents($zoneFile);
	
	// replace serial
	$newSerial = date("ymHis");
	print("Updating $zoneFile with new serial:" . $newSerial . "\n");
	$zoneFileContents = preg_replace("/(\([\s\n]+)(\d+)([\s\n]+)/",'${1}' . $newSerial . '${3}',$zoneFileContents);
	
	// take the opportunity to remove empty lines
	$zoneFileContents = preg_replace("/\n+/","\n",$zoneFileContents);
	
	// write the new zoneFile
	$putRet = file_put_contents($zoneFile,$zoneFileContents);
	
	// and reload named
	$rndcRet = shell_exec("rndc reload");
}

function GetHostPart($hostname)
{
	return preg_replace("/^([^\.]+).*/i","$1",$hostname);
}

// deprecated
function SearchHostAndIpInZoneFile($hostname,$ip)
{
	// read fresh zone file contents
	global $zoneFile;
	$zoneFileContents = file_get_contents($zoneFile);
	$hostPart = GetHostPart($hostname);

	print("Searching for $hostPart and $ip ... ");

	$presence = preg_match("/" . $hostPart . "\s+IN\s+A\s+" . $ip . "/i",$zoneFileContents);

	echo $presence ? "Found" : "Not Found";
	echo "\n";
	return $presence;
}

