#!/usr/bin/env perl

use strict;
use Config;
use Getopt::Long;

#-----------------------------------------------------------------
# Parse options

our $prefix = "/usr/local/mmm";
our $symlinks_dir = "/usr/local/sbin";
our $disable_symlinks = 0;
our $show_help = 0;
our $skip_checks = 0;

GetOptions("prefix=s" => \$prefix,
           "disable-symlinks" => \$disable_symlinks,
           "symlinks-dir=s", \$symlinks_dir,
           "help" => \$show_help,
           "skip-checks", \$skip_checks);
           
ShowUsage() if ($show_help);

#-----------------------------------------------------------------
# Checking prerequisitres (required modules, options, etc)

CheckPrerequisites() unless ($skip_checks);

#-----------------------------------------------------------------
# Performing installation (file copying, symlinking, etc)
PerformInstallation();

print "\nInstallation is done!\n\n";

exit(0);

#-----------------------------------------------------------------
sub ShowUsage() {
    print "Usage: $0 [--options]\n";
    print "Options:\n";
    print "  --help              Show options list\n";
    print "  --prefix=PREFIX     Specifies installation directory\n";
    print "  --disable-symlinks  Disables symlinks creation for mmm binaries\n";
    print "  --symlinks-dir=DIR  Specifies target directory for mmm binaries symlinks\n";
    print "  --skip-checks       Skip all prerequisites checks and force installation\n";
    print "\n";
    exit(0);
}

#-----------------------------------------------------------------
sub CheckPrerequisites() {
    print "Checking platform support... $^O ";
    unless ($^O eq 'linux') {
        print "- This platform is not supported yet. Sorry.\n\n";
        exit(1);
    }
    print "Ok!\n";
    
    unless ($Config{useithreads}) {
        print "Error: This Perl hasn't been configured and built properly for the threads module to work.\n";
        print "To use this software on this system you will need to recompile Perl with threads support.\n\n";
        exit(1);
    }

    my @modules = (
        'Data::Dumper',
        'POSIX',
        'Cwd',
        'threads',
        'threads::shared',
        'Thread::Queue',
        'Thread::Semaphore',
        'IO::Socket',
        'Proc::Daemon',
        'Time::HiRes',
        'DBI',
        'DBD::mysql',
        'Algorithm::Diff'
    );
    
    foreach my $module (@modules) {
        print "Checking required module '$module'...";
        my $res = CheckModule($module);
        if ($res) {
            print "Ok!\n";
            next;
        }
        
        print "\n------------------------------------------------------------\n";
        print "Required module '$module' is not found on this system!\n";
        print "Install it (e.g. run command 'cpan $module') and try again.\n\n";
        exit(1);
    }
}

#-----------------------------------------------------------------
sub CheckModule($) {
    my $module = shift;
    
    eval "use $module";
    
    return 1 unless $@;
    print "Error!\n $@";
    return 0;
}

#-----------------------------------------------------------------
sub PerformInstallation() {
    print "Installing mmm files...\n";
    print "Confgiuration:\n";
    print "  - installation directory: '$prefix'\n";
    print "  - create symlinks: " . ($disable_symlinks ? 'off' : 'on') . "\n";
    print "  - symlinks directory: '$symlinks_dir'\n" unless ($disable_symlinks);
    print "\n";
    
    CopyFiles();
    CreateSymlinks() unless $disable_symlinks;
}

#-----------------------------------------------------------------
sub CopyFiles() {
    print "Copying files to '$prefix' directory...";
    system("mkdir -p '$prefix'");
    # FIXME: Maybe we need to copy only required files?
    system("cp -Rf * '$prefix/'");
    print "Ok!\n\n";
}

#-----------------------------------------------------------------
sub CreateSymlinks() {
    # FIXME: Maybe we need to symlink only required scripts?
    opendir(DIR, "$prefix/sbin") || die "Can't open sbin directory in mmm!";
    my @scripts = readdir(DIR);
    closedir(DIR);
    
    system("mkdir -p '$symlinks_dir'");
    
    foreach my $script (@scripts) {
        my $script_name = "$prefix/sbin/$script";
        next unless (-f $script_name);
        chmod(0755, $script_name);
        
        my $symlink_name = "$symlinks_dir/$script";
        print "Creating symlink: '$script_name' -> '$symlink_name'...";
        unlink($symlink_name);
        symlink($script_name, $symlink_name);
        print "Ok!\n";
    }
}
