my $PROGRAM_NAME = 'MySQL Multi-Master Replication Manager';
my $PROGRAM_SHORT = 'MMM';
my $PROGRAM_VERSION_MAJOR = 1;
my $PROGRAM_VERSION_MINOR = 2;
my $PROGRAM_VERSION_PATCH = 5;

sub PrintVersion()
{
  printf("%s\n", $PROGRAM_NAME);
  printf("Version: %d.%d.%d\n", $PROGRAM_VERSION_MAJOR, $PROGRAM_VERSION_MINOR, $PROGRAM_VERSION_PATCH);
}

sub GetVersion()
{
  my $version;
  sprintf($version, "Version: %d.%d.%d\n", $PROGRAM_VERSION_MAJOR, $PROGRAM_VERSION_MINOR, $PROGRAM_VERSION_PATCH);
  return $version;
}

1;
