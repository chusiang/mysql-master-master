package MMM::Common::Log;

use strict;
use warnings FATAL => 'all';
use Log::Log4perl qw(:easy);

our $VERSION = '0.01';


sub init($) {
	my $filename = shift;

	# TODO look for config file in several paths, if not present use default config.
	my $conf = q(
		log4perl.logger = INFO, FileInfo, FileWarn, FileError, FileFatal, MailFatal

		log4perl.appender.FileInfo            = Log::Log4perl::Appender::File
		log4perl.appender.FileInfo.filename   = mmmd_mon.info
		log4perl.appender.FileInfo.layout     = SimpleLayout
		log4perl.appender.FileInfo.Threshold  = INFO 
		log4perl.appender.FileInfo.recreate   = 1

		log4perl.appender.FileWarn            = Log::Log4perl::Appender::File
		log4perl.appender.FileWarn.filename   = mmmd_mon.warn
		log4perl.appender.FileWarn.layout     = SimpleLayout
		log4perl.appender.FileWarn.Threshold  = WARN 
		log4perl.appender.FileWarn.recreate   = 1

		log4perl.appender.FileError           = Log::Log4perl::Appender::File
		log4perl.appender.FileError.filename  = mmmd_mon.error
		log4perl.appender.FileError.layout    = SimpleLayout
		log4perl.appender.FileError.Threshold = ERROR 
		log4perl.appender.FileError.recreate  = 1

		log4perl.appender.FileFatal           = Log::Log4perl::Appender::File
		log4perl.appender.FileFatal.filename  = mmmd_mon.fatal
		log4perl.appender.FileFatal.layout    = SimpleLayout
		log4perl.appender.FileFatal.Threshold = FATAL 
		log4perl.appender.FileFatal.recreate  = 1

		log4perl.appender.MailFatal           = Log::Dispatch::Email::MailSend
		log4perl.appender.MailFatal.to        = root
		log4perl.appender.MailFatal.subject   = FATAL error in MMM Monitor
		log4perl.appender.MailFatal.layout    = SimpleLayout
		log4perl.appender.MailFatal.Threshold = FATAL 
	);
	Log::Log4perl->init(\$conf);

}

sub debug() {
	my $stdout_appender =  Log::Log4perl::Appender->new(
		'Log::Log4perl::Appender::Screen',
		name      => "screenlog",
		stderr    => 0
	);
	Log::Log4perl::Logger->get_root_logger()->add_appender($stdout_appender);
	Log::Log4perl::Logger->get_root_logger()->level($DEBUG);
}
