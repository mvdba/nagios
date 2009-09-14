package DBD::Oracle::Server::Instance::SGA::RedoLogBuffer;

use strict;

our @ISA = qw(DBD::Oracle::Server::Instance::SGA);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    last_switch_interval => undef,
    redo_buffer_allocation_retries => undef,
    redo_entries => undef,
    retry_ratio => undef,
    redo_size => undef,
    redo_size_per_sec => undef,
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}


sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::sga::redologbuffer::switchinterval/) {
    if ($self->instance_rac()) {
      eval {
        # alles was jemals geswitcht hat, letzter switch, zweitletzter switch
        $self->{last_switch_interval} = $self->{handle}->fetchrow_array(q {
          WITH temptab AS
          (
            SELECT sequence#, first_time FROM sys.v_$log WHERE status = 'CURRENT'
                AND thread# = ?
            UNION ALL
            SELECT sequence#, first_time FROM sys.v_$log_history
                WHERE thread# = ?
          )
          SELECT (b.first_time - a.first_time) * 1440 * 60  seconds
          FROM 
          (
            SELECT MAX(first_time) AS first_time FROM temptab
          ) b,
          (
            SELECT MAX(first_time) AS first_time FROM temptab
            WHERE first_time < (SELECT MAX(first_time) AS first_time FROM temptab) 
          ) a
        }, $self->instance_thread(), $self->instance_thread());
      };
    } else {
      eval {
        # alles was jemals geswitcht hat, letzter switch, zweitletzter switch
        $self->{last_switch_interval} = $self->{handle}->fetchrow_array(q {
          WITH temptab AS
          (
            SELECT sequence#, first_time FROM sys.v_$log WHERE status = 'CURRENT'
            UNION ALL
            SELECT sequence#, first_time FROM sys.v_$log_history
          )
          SELECT (b.first_time - a.first_time) * 1440 * 60  seconds
          FROM 
          (
            SELECT MAX(first_time) AS first_time FROM temptab
          ) b,
          (
            SELECT MAX(first_time) AS first_time FROM temptab
            WHERE first_time < (SELECT MAX(first_time) AS first_time FROM temptab) 
          ) a
        });
      };
    }
    if (! defined $self->{last_switch_interval}) {
      $self->add_nagios_critical(
          sprintf "unable to get last switch interval");
    }
  } elsif ($params{mode} =~ /server::instance::sga::redologbuffer::retryratio/) {
    ($self->{redo_buffer_allocation_retries}, $self->{redo_entries}) = 
        $self->{handle}->fetchrow_array(q{
            SELECT a.value, b.value
            FROM v$sysstat a, v$sysstat b  
            WHERE a.name = 'redo buffer allocation retries'  
            AND b.name = 'redo entries'
    });
    if (! defined $self->{redo_buffer_allocation_retries}) {
      $self->add_nagios_critical("unable to get retry ratio");
    } else {
      $self->valdiff(\%params, qw(redo_buffer_allocation_retries redo_entries));
      $self->{retry_ratio} = $self->{delta_redo_entries} ? 
          100 * $self->{delta_redo_buffer_allocation_retries} / $self->{delta_redo_entries} : 0;
    }
  } elsif ($params{mode} =~ /server::instance::sga::redologbuffer::iotraffic/) {
    $self->{redo_size} = $self->{handle}->fetchrow_array(q{
        SELECT value FROM v$sysstat WHERE name = 'redo size'
    });
    if (! defined $self->{redo_size}) {
      $self->add_nagios_critical("unable to get redo size");
    } else {
      $self->valdiff(\%params, qw(redo_size));
      $self->{redo_size_per_sec} =
          $self->{delta_redo_size} / $self->{delta_timestamp};
      # Megabytes / sec
      $self->{redo_size_per_sec} = $self->{redo_size_per_sec} / 1048576;
    }
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~
        /server::instance::sga::redologbuffer::switchinterval/) {
      $self->add_nagios(
          # 10: minutes, 1: minute = 600:, 60:
          $self->check_thresholds($self->{last_switch_interval}, "600:", "60:"),
          sprintf "Last redo log file switch interval was %d minutes%s",
              $self->{last_switch_interval} / 60,
              $self->instance_rac() ? sprintf " (thread %d)", $self->instance_thread() : "");
      $self->add_perfdata(sprintf "redo_log_file_switch_interval=%ds;%s;%s",
          $self->{last_switch_interval},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ 
        /server::instance::sga::redologbuffer::retryratio/) {
      $self->add_nagios(
          $self->check_thresholds($self->{retry_ratio}, "1", "10"),
          sprintf "Redo log retry ratio is %.6f%%",$self->{retry_ratio});
      $self->add_perfdata(sprintf "redo_log_retry_ratio=%.6f%%;%s;%s",
          $self->{retry_ratio},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ 
        /server::instance::sga::redologbuffer::iotraffic/) {
      $self->add_nagios(
          $self->check_thresholds($self->{redo_size_per_sec}, "100", "200"),
          sprintf "Redo log io is %.6f MB/sec", $self->{redo_size_per_sec});
      $self->add_perfdata(sprintf "redo_log_io_per_sec=%.6f;%s;%s",
          $self->{redo_size_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    }
  }
}


1;
