package Cron::RunJob;

use 5.014002;
use strict;
use warnings;
use vars qw($AUTOLOAD);
use Scalar::Util 'refaddr';
use Mail::Mailer;
use IO::Select;
use IO::File;
use IPC::Open3;
use POSIX ":sys_wait_h";

require Exporter;

our @ISA = qw(Exporter);
our %EXPORT_TAGS = ( 'all' => [ qw() ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw();
our $VERSION = '0.02';


my ($job_pid, %_data);
$SIG{TERM} = $SIG{INT} = sub {
	kill 9, $job_pid if $job_pid;
	exit;
};

sub new {
	my ($self, %opt) = @_;
	$self = bless {}, $self;
	$_data{refaddr $self}{uc $_} = $opt{$_} 
        	for keys %opt; 
	return $self;
}

sub runfile_name {
	my ($self, $cmd) = @_;
	$cmd =~ s/.*\///;
	return $self->runfile_dir .'/'. $cmd . ".pid";
}

sub create_runfile {
	my ($self, $runfile) = @_;
	my $fh = new IO::File;
	$fh->open("> $runfile");
	die $! unless defined $fh;
	print $fh $self->pid;
	$fh->close;
}

sub unlink_runfile {
	my ($self, $runfile) = @_;
	unlink $runfile or die $!;
}

sub is_running {
	my ($self, $runfile) = @_;
	if (-e $runfile) {
		my $fh = new IO::File;
		die $! unless defined $fh; 
		$fh->open($runfile) or die "Open run file $runfile $!\n";
		my $pid = <$fh>;
		$fh->close;
		return if $pid == $$;
		$self->pid($pid);
		return kill 0, $pid;
	}
	return 0;	
}

sub run_command {
	my ($self, $cmd, @argv) = @_;
	
	if ($self->only_me and $self->is_running($self->runfile_name($cmd))) {
		$self->stderr("Proccess is already running ");
		$self->exitcode(1);
		return 0;
	}	
	
	my $select = IO::Select->new();
	my $chld_stderr = new IO::File;
	my $chld_stdin = new IO::File;
	my $chld_stdout = new IO::File;

	$job_pid = open3($chld_stdin, $chld_stdout, $chld_stderr, $cmd, @argv);
	$self->pid($job_pid);
	$self->create_runfile($self->runfile_name($cmd)) 
		if $self->only_me;
	
	$select->add($chld_stderr);
	$select->add($chld_stdout);

	my ($buff, $std_error, $std_out);
	foreach my $fh ($select->can_read) {
		while (my $buff = <$fh>) {
			if ($fh == $chld_stderr) {
				$std_error .= $buff;
			} elsif ($fh == $chld_stdout)  {
				$std_out .= $buff;		
			}
		}	
	}

	$chld_stderr->close;
	$chld_stdout->close;
	$chld_stdin->close;
	
	waitpid($job_pid, 0);

	if ($std_error) {
		$self->stderr($std_error);
		if ($self->mail_errors) {
			my $mailer = new Mail::Mailer 'sendmail';
			$mailer->open({
				To => $self->mailto,
				From => $self->from,
				Subject => $self->subject,
			});

			print $mailer "Error: $cmd failed with error(s): ".($std_error ? $std_error:'unknown errors')."\n";
			$mailer->close;
		}
		$self->exitcode(1);
	} else {
		$self->exitcode(0);
		$self->stdout($std_out);
		if ($self->mail_output) {
			my $mailer = new Mail::Mailer 'sendmail';
			$mailer->open({
				From => $self->from,
				To => $self->mailto,
				Subject => "$cmd output",
			});
			
			print $mailer $self->stdout;
		}
	}

	$self->unlink_runfile($self->runfile_name($cmd))
		if $self->only_me;
	
	return $self->exitcode;
}

sub AUTOLOAD {
	my $self = shift;
	(my $attr = $AUTOLOAD) =~ s/^.*:://;
	if (exists $self->{uc $attr} and $self->{uc $attr}) {
		return $self->{uc $attr};
	} else {
		my $value = shift;
		$self->{uc $attr} = $value if $value;
	}
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

Cron::RunJob - Monitor Cron Jobs

=head1 SYNOPSIS

	use Cron::RunJob;
  
  	my $cmd = shift;
	my $job = new CSU::Job 
		ONLY_ME => 1,
		RUNFILE_DIR => "/var/run/",
		MAIL_ERRORS => 1,
		MAILTO => 'user@domain.com',
		FROM => 'no-reply@domain.com',
		SUBJECT => "[crond] Error -- $cmd",
	;  
	
	$job->run_command($cmd, @args);
	
	if ($job->exitcode) {
		print $job->errstr. "\n\n" if $job->errstr;
	} else {
		print $job->output. "\n\n" if $job->output;
	}
	
=head1 DESCRIPTION


Run a cmd and email any error to the supplied email address


=head1 AUTHOR

Kiel R Stirling, E<lt>kielstr@cpan.org<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Kiel R Stirling

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.14.2 or,
at your option, any later version of Perl 5 you may have available.


=cut
