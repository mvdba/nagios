package DBD::Oracle::Server;

use strict;
use Time::HiRes;
use IO::File;
use File::Copy 'cp';
use Data::Dumper;

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  our $verbose = 0;
  our $scream = 0; # scream if something is not implemented
  our $access = "dbi"; # how do we access the database. 
  our $my_modules_dyn_dir = ""; # where we look for self-written extensions

  my @servers = ();
  my $initerrors = undef;

  sub add_server {
    push(@servers, shift);
  }

  sub return_servers {
    return @servers;
  }
  
  sub return_first_server() {
    return $servers[0];
  }

}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    access => $params{method} || "dbi",
    connect => $params{connect},
    user => $params{user},
    password => $params{password},
    timeout => $params{timeout},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    version => 'unknown',
    instance => undef,
    database => undef,
    handle => undef,
  };
  bless $self, $class;
  $self->init_nagios();
  if ($self->dbconnect(%params)) {
    $self->{version} = $self->{handle}->fetchrow_array(
        q{ SELECT version FROM v$instance });
    $self->{os} = $self->{handle}->fetchrow_array(
        q{ SELECT dbms_utility.port_string FROM dual });
    $self->{dbuser} = $self->{handle}->fetchrow_array(
        q{ SELECT sys_context('userenv', 'session_user') FROM dual });
    $self->{thread} = $self->{handle}->fetchrow_array(
        q{ SELECT thread# FROM v$instance });
    $self->{parallel} = $self->{handle}->fetchrow_array(
        q{ SELECT parallel FROM v$instance });
    DBD::Oracle::Server::add_server($self);
    $self->init(%params);
  }
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $params{handle} = $self->{handle};
  if ($params{mode} =~ /^server::instance/) {
    $self->{instance} = DBD::Oracle::Server::Instance->new(%params);
  } elsif ($params{mode} =~ /^server::database/) {
    $self->{database} = DBD::Oracle::Server::Database->new(%params);
  } elsif ($params{mode} =~ /^server::sql/) {
    @{$self->{genericsql}} =
        $self->{handle}->fetchrow_array($params{selectname});
    if (! (defined $self->{genericsql} &&
        (scalar(grep { /^\s*\d+\.{0,1}\d*\s*$/ } @{$self->{genericsql}})) ==
        scalar(@{$self->{genericsql}}))) {
      $self->add_nagios_unknown(sprintf "got no valid response for %s",
          $params{selectname});
    } else {
      # name2 in array
      # units in array
    }
  } elsif ($params{mode} =~ /^server::connectiontime/) {
    $self->{connection_time} = $self->{tac} - $self->{tic};
  } elsif ($params{mode} =~ /^my::([^:.]+)/) {
    my $class = $1;
    my $loaderror = undef;
    substr($class, 0, 1) = uc substr($class, 0, 1);
    foreach my $libpath (split(":", $DBD::Oracle::Server::my_modules_dyn_dir)) {
      foreach my $extmod (glob $libpath."/CheckOracleHealth*.pm") {
        eval {
          $self->trace(sprintf "loading module %s", $extmod);
          require $extmod;
        };
        if ($@) {
          $loaderror = $extmod;
          $self->trace(sprintf "failed loading module %s: %s", $extmod, $@);
        }
      }
    }
    my $obj = {
        handle => $params{handle},
        warningrange => $params{warningrange},
        criticalrange => $params{criticalrange},
    };
    bless $obj, "My$class";
    $self->{my} = $obj;
    if ($self->{my}->isa("DBD::Oracle::Server")) {
      my $dos_init = $self->can("init");
      my $dos_nagios = $self->can("nagios");
      my $my_init = $self->{my}->can("init");
      my $my_nagios = $self->{my}->can("nagios");
      if ($my_init == $dos_init) {
          $self->add_nagios_unknown(
              sprintf "Class %s needs an init() method", ref($self->{my}));
      } elsif ($my_nagios == $dos_nagios) {
          $self->add_nagios_unknown(
              sprintf "Class %s needs a nagios() method", ref($self->{my}));
      } else {
        $self->{my}->init_nagios(%params);
        $self->{my}->init(%params);
      }
    } else {
      $self->add_nagios_unknown(
          sprintf "Class %s is not a subclass of DBD::Oracle::Server%s", 
              ref($self->{my}),
              $loaderror ? sprintf " (syntax error in %s?)", $loaderror : "" );
    }
  } else {
    printf "broken mode %s\n", $params{mode};
  }
}

sub dump {
  my $self = shift;
  my $message = shift || "";
  printf "%s %s\n", $message, Data::Dumper::Dumper($self);
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /^server::instance/) {
      $self->{instance}->nagios(%params);
      $self->merge_nagios($self->{instance});
    } elsif ($params{mode} =~ /^server::database/) {
      $self->{database}->nagios(%params);
      $self->merge_nagios($self->{database});
    } elsif ($params{mode} =~ /^server::connectiontime/) {
      $self->add_nagios(
          $self->check_thresholds($self->{connection_time}, 1, 5),
          sprintf "%.2f seconds to connect as %s",
              $self->{connection_time}, $self->{dbuser});
      $self->add_perfdata(sprintf "connection_time=%.4f;%d;%d",
          $self->{connection_time},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::sql/) {
      $self->add_nagios(
          # the first item in the list will trigger the threshold values
          $self->check_thresholds($self->{genericsql}[0], 1, 5),
              sprintf "%s: %s%s",
              $params{name2} ? lc $params{name2} : lc $params{selectname},
              # float as float, integers as integers
              join(" ", map {
                  (sprintf("%d", $_) eq $_) ? $_ : sprintf("%f", $_)
              } @{$self->{genericsql}}),
              $params{units} ? $params{units} : "");
      my $i = 0;
      # workaround... getting the column names from the database would be nicer
      my @names2_arr = split(/\s+/, $params{name2});
      foreach my $t (@{$self->{genericsql}}) {
        $self->add_perfdata(sprintf "\'%s\'=%s%s;%s;%s",
            $names2_arr[$i] ? lc $names2_arr[$i] : lc $params{selectname},
            # float as float, integers as integers
            (sprintf("%d", $t) eq $t) ? $t : sprintf("%f", $t),
            $params{units} ? $params{units} : "",
	    ($i == 0) ? $self->{warningrange} : "",
            ($i == 0) ? $self->{criticalrange} : ""
        );
        $i++;
      }
    } elsif ($params{mode} =~ /^my::([^:.]+)/) {
      $self->{my}->nagios(%params);
      $self->merge_nagios($self->{my});
    }
  }
}


sub init_nagios {
  my $self = shift;
  no strict 'refs';
  if (! ref($self)) {
    my $nagiosvar = $self."::nagios";
    my $nagioslevelvar = $self."::nagios_level";
    $$nagiosvar = {
      messages => {
        0 => [],
        1 => [],
        2 => [],
        3 => [],
      },
      perfdata => [],
    };
    $$nagioslevelvar = $ERRORS{OK},
  } else {
    $self->{nagios} = {
      messages => {
        0 => [],
        1 => [],
        2 => [],
        3 => [],
      },
      perfdata => [],
    };
    $self->{nagios_level} = $ERRORS{OK},
  }
}

sub check_thresholds {
  my $self = shift;
  my $value = shift;
  my $defaultwarningrange = shift;
  my $defaultcriticalrange = shift;
  my $level = $ERRORS{OK};
  $self->{warningrange} = defined $self->{warningrange} ?
      $self->{warningrange} : $defaultwarningrange;
  $self->{criticalrange} = defined $self->{criticalrange} ?
      $self->{criticalrange} : $defaultcriticalrange;
  if ($self->{warningrange} !~ /:/ && $self->{criticalrange} !~ /:/) {
    # warning = 10, critical = 20, warn if > 10, crit if > 20
    $level = $ERRORS{WARNING} if $value > $self->{warningrange};
    $level = $ERRORS{CRITICAL} if $value > $self->{criticalrange};
  } elsif ($self->{warningrange} =~ /(\d+):/ && 
      $self->{criticalrange} =~ /(\d+):/) {
    # warning = 98:, critical = 95:, warn if < 98, crit if < 95
    $self->{warningrange} =~ /(\d+):/;
    $level = $ERRORS{WARNING} if $value < $1;
    $self->{criticalrange} =~ /(\d+):/;
    $level = $ERRORS{CRITICAL} if $value < $1;
  }
  return $level;
  #
  # syntax error must be reported with returncode -1
  #
}

sub add_nagios {
  my $self = shift;
  my $level = shift;
  my $message = shift;
  push(@{$self->{nagios}->{messages}->{$level}}, $message);
  # recalc current level
  foreach my $llevel qw(CRITICAL WARNING UNKNOWN OK) {
    if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$llevel}}})) {
      $self->{nagios_level} = $ERRORS{$llevel};
    }
  }
}

sub add_nagios_ok {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{OK}, $message);
}

sub add_nagios_warning {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{WARNING}, $message);
}

sub add_nagios_critical {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{CRITICAL}, $message);
}

sub add_nagios_unknown {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{UNKNOWN}, $message);
}

sub add_perfdata {
  my $self = shift;
  my $data = shift;
  push(@{$self->{nagios}->{perfdata}}, $data);
}

sub merge_nagios {
  my $self = shift;
  my $child = shift;
  foreach my $level (0..3) {
    foreach (@{$child->{nagios}->{messages}->{$level}}) {
      $self->add_nagios($level, $_);
    }
    #push(@{$self->{nagios}->{messages}->{$level}},
    #    @{$child->{nagios}->{messages}->{$level}});
  }
  push(@{$self->{nagios}->{perfdata}}, @{$child->{nagios}->{perfdata}});
}


sub calculate_result {
  my $self = shift;
  if ($ENV{NRPE_MULTILINESUPPORT} && 
      length join(" ", @{$self->{nagios}->{perfdata}}) > 200) {
    foreach my $level ("CRITICAL", "WARNING", "UNKNOWN", "OK") {
      # first the bad news
      if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$level}}})) {
        $self->{nagios_message} .=
            "\n".join("\n", @{$self->{nagios}->{messages}->{$ERRORS{$level}}});
      }
    }
    $self->{nagios_message} =~ s/^\n//g;
    $self->{perfdata} = join("\n", @{$self->{nagios}->{perfdata}});
  } else {
    foreach my $level ("CRITICAL", "WARNING", "UNKNOWN", "OK") {
      # first the bad news
      if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$level}}})) {
        $self->{nagios_message} .= 
            join(", ", @{$self->{nagios}->{messages}->{$ERRORS{$level}}}).", ";
      }
    }
    $self->{nagios_message} =~ s/, $//g;
    $self->{perfdata} = join(" ", @{$self->{nagios}->{perfdata}});
  }
  foreach my $level ("OK", "UNKNOWN", "WARNING", "CRITICAL") {
    if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$level}}})) {
      $self->{nagios_level} = $ERRORS{$level};
    }
  }
}

sub debug {
  my $self = shift;
  my $msg = shift;
  if ($DBD::Oracle::Server::verbose) {
    printf "%s %s\n", $msg, ref($self);
  }
}

sub dbconnect {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  $self->{tic} = Time::HiRes::time();
  $self->{handle} = DBD::Oracle::Server::Connection->new(%params);
  if ($self->{handle}->{errstr}) {
    if ($params{mode} =~ /^server::tnsping/ &&
        $self->{handle}->{errstr} =~ /ORA-01017/) {
      $self->add_nagios($ERRORS{OK},
          sprintf "connection established to %s.", $self->{connect});
      $retval = undef;
    } elsif ($self->{handle}->{errstr} eq "alarm\n") {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "connection could not be established within %d seconds",
              $self->{timeout});
    } else {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "cannot connect to %s. %s",
          $self->{connect}, $self->{handle}->{errstr});
      $retval = undef;
    }
  } else {
    $retval = $self->{handle};
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub trace {
  my $self = shift;
  my $format = shift;
  $self->{trace} = -f "/tmp/check_oracle_health.trace" ? 1 : 0;
  if ($self->{verbose}) {
    printf("%s: ", scalar localtime);
    printf($format, @_);
  }
  if ($self->{trace}) {
    my $logfh = new IO::File;
    $logfh->autoflush(1);
    if ($logfh->open("/tmp/check_oracle_health.trace", "a")) {
      $logfh->printf("%s: ", scalar localtime);
      $logfh->printf($format, @_);
      $logfh->printf("\n");
      $logfh->close();
    }
  }
}

sub DESTROY {
  my $self = shift;
  my $handle1 = "null";
  my $handle2 = "null";
  if (defined $self->{handle}) {
    $handle1 = ref($self->{handle});
    if (defined $self->{handle}->{handle}) {
      $handle2 = ref($self->{handle}->{handle});
    }
  }
  $self->trace(sprintf "DESTROY %s with handle %s %s", ref($self), $handle1, $handle2);
  if (ref($self) eq "DBD::Oracle::Server") {
  }
  $self->trace(sprintf "DESTROY %s exit with handle %s %s", ref($self), $handle1, $handle2);
  if (ref($self) eq "DBD::Oracle::Server") {
    #printf "humpftata\n";
  }
}

sub save_state {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  if ($params{connect} =~ /(\w+)\/(\w+)@(\w+)/) {
    $params{connect} = $3;
  }
  mkdir $params{statefilesdir} unless -d $params{statefilesdir};
  my $statefile = sprintf "%s/%s_%s", 
      $params{statefilesdir}, $params{connect}, $params{mode};
  $extension .= $params{differenciator} ? "_".$params{differenciator} : "";
  $extension .= $params{tablespace} ? "_".$params{tablespace} : "";
  $extension .= $params{datafile} ? "_".$params{datafile} : "";
  $extension .= $params{name} ? "_".$params{name} : "";
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  $statefile .= $extension;
  $statefile = lc $statefile;
  open(STATE, ">$statefile");
  if ((ref($params{save}) eq "HASH") && exists $params{save}->{timestamp}) {
    $params{save}->{localtime} = scalar localtime $params{save}->{timestamp};
  }
  printf STATE Data::Dumper::Dumper($params{save});
  close STATE;
  $self->debug(sprintf "saved %s to %s",
      Data::Dumper::Dumper($params{save}), $statefile);
}

sub load_state {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  if ($params{connect} =~ /(\w+)\/(\w+)@(\w+)/) {
    $params{connect} = $3;
  }
  my $statefile = sprintf "%s/%s_%s", 
      $params{statefilesdir}, $params{connect}, $params{mode};
  $extension .= $params{differenciator} ? "_".$params{differenciator} : "";
  $extension .= $params{tablespace} ? "_".$params{tablespace} : "";
  $extension .= $params{datafile} ? "_".$params{datafile} : "";
  $extension .= $params{name} ? "_".$params{name} : "";
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  $statefile .= $extension;
  $statefile = lc $statefile;
  if ( -f $statefile) {
    our $VAR1;
    eval {
      require $statefile;
    };
    if($@) {
printf "rumms\n";
    }
    $self->debug(sprintf "load %s", Data::Dumper::Dumper($VAR1));
    return $VAR1;
  } else {
    return undef;
  }
}

sub valdiff {
  my $self = shift;
  my $pparams = shift;
  my %params = %{$pparams};
  my @keys = @_;
  my $last_values = $self->load_state(%params) || eval {
    my $empty_events = {};
    foreach (@keys) {
      $empty_events->{$_} = 0;
    }
    $empty_events->{timestamp} = 0;
    $empty_events;
  };
  foreach (@keys) {
    $self->{'delta_'.$_} = $self->{$_} - $last_values->{$_};
    $self->debug(sprintf "delta_%s %f", $_, $self->{'delta_'.$_});
  }
  $self->{'delta_timestamp'} = time - $last_values->{timestamp};
  $params{save} = eval {
    my $empty_events = {};
    foreach (@keys) {
      $empty_events->{$_} = $self->{$_};
    }
    $empty_events->{timestamp} = time;
    $empty_events;
  };
  $self->save_state(%params);
}

sub requires_version {
  my $self = shift;
  my $version = shift;
  my @instances = DBD::Oracle::Server::return_servers();
  my $instversion = $instances[0]->{version};
  if (! $self->version_is_minimum($version)) {
    $self->add_nagios($ERRORS{UNKNOWN}, 
        sprintf "not implemented/possible for Oracle release %s", $instversion);
  }
}

sub version_is_minimum {
  # the current version is newer or equal
  my $self = shift;
  my $version = shift;
  my $newer = 1;
  my @instances = DBD::Oracle::Server::return_servers();
  my @v1 = map { $_ eq "x" ? 0 : $_ } split(/\./, $version);
  my @v2 = split(/\./, $instances[0]->{version});
  if (scalar(@v1) > scalar(@v2)) {
    push(@v2, (0) x (scalar(@v1) - scalar(@v2)));
  } elsif (scalar(@v2) > scalar(@v1)) {
    push(@v1, (0) x (scalar(@v2) - scalar(@v1)));
  }
  foreach my $pos (0..$#v1) {
    if ($v2[$pos] > $v1[$pos]) {
      $newer = 1;
      last;
    } elsif ($v2[$pos] < $v1[$pos]) {
      $newer = 0;
      last;
    }
  }
  #printf STDERR "check if %s os minimum %s\n", join(".", @v2), join(".", @v1);
  return $newer;
}

sub instance_rac {
  my $self = shift;
  my @instances = DBD::Oracle::Server::return_servers();
  return (lc $instances[0]->{parallel} eq "yes") ? 1 : 0;
}

sub instance_thread {
  my $self = shift;
  my @instances = DBD::Oracle::Server::return_servers();
  return $instances[0]->{thread};
}

sub windows_server {
  my $self = shift;
  my @instances = DBD::Oracle::Server::return_servers();
  if ($instances[0]->{os} =~ /Win/i) {
    return 1;
  } else {
    return 0;
  }
}

sub system_vartmpdir {
  my $self = shift;
  if ($^O =~ /MSWin/) {
    return $self->system_tmpdir();
  } else {
    return "/var/tmp/check_oracle_health";
  }
}

sub system_oldvartmpdir {
  my $self = shift;
  return "/tmp";
}

sub system_tmpdir {
  my $self = shift;
  if ($^O =~ /MSWin/) {
    return $ENV{TEMP} if defined $ENV{TEMP};
    return $ENV{TMP} if defined $ENV{TMP};
    return File::Spec->catfile($ENV{windir}, 'Temp')
        if defined $ENV{windir};
    return 'C:\Temp';
  } else {
    return "/tmp";
  }
}


package DBD::Oracle::Server::Connection;

use strict;

our @ISA = qw(DBD::Oracle::Server);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    mode => $params{mode},
    timeout => $params{timeout},
    access => $params{method} || "dbi",
    connect => $params{connect},
    user => $params{user},
    password => $params{password},
    tnsadmin => $ENV{TNS_ADMIN},
    oraclehome => $ENV{ORACLE_HOME},
    handle => undef,
  };
  bless $self, $class;
  if ($params{method} eq "dbi") {
    bless $self, "DBD::Oracle::Server::Connection::Dbi";
  } elsif ($params{method} eq "sqlplus") {
    bless $self, "DBD::Oracle::Server::Connection::Sqlplus";
  } elsif ($params{method} eq "sqlrelay") {
    bless $self, "DBD::Oracle::Server::Connection::Sqlrelay";
  }
  $self->init(%params);
  return $self;
}


package DBD::Oracle::Server::Connection::Dbi;

use strict;
use Net::Ping;

our @ISA = qw(DBD::Oracle::Server::Connection);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  if ($self->{mode} =~ /^server::tnsping/) {
    if (! $self->{connect}) {
      $self->{errstr} = "Please specify a database";
    } else {
      $self->{sid} = $self->{connect};
      $self->{user} ||= time;  # prefer an existing user
      $self->{password} = time;
    }
  } else {
    if (! $self->{connect} || ! $self->{user} || ! $self->{password}) {
      if ($self->{connect} && $self->{connect} =~ /(\w+)\/(\w+)@(\w+)/) {
        $self->{connect} = $3;
        $self->{user} = $1;
        $self->{password} = $2;
        $self->{sid} = $self->{connect};
      } elsif ($self->{connect} && ! $self->{user} && ! $self->{password}) {
        # maybe this is a os authenticated user
        delete $ENV{TWO_TASK};
        $self->{sid} = $self->{connect};
        if ($^O ne "hpux") {       #hpux && 1.21 only accepts "DBI:Oracle:SID"
          $self->{connect} = "";   #linux 1.20 only accepts "DBI:Oracle:" + ORACLE_SID
        }
        $self->{user} = '/';
        $self->{password} = "";
      } else {
        $self->{errstr} = "Please specify database, username and password";
        return undef;
      }
    } else {
      $self->{sid} = $self->{connect};
    }
  }
  if (! exists $self->{errstr}) {
    $ENV{ORACLE_SID} = $self->{sid};
    eval {
      require DBI;
      use POSIX ':signal_h';
      local $SIG{'ALRM'} = sub {
        die "alarm\n";
      };
      my $mask = POSIX::SigSet->new( SIGALRM );
      my $action = POSIX::SigAction->new(
          sub { die "alarm\n" ; }, $mask);
      my $oldaction = POSIX::SigAction->new();
      sigaction(SIGALRM ,$action ,$oldaction );
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
      my $connecthash = $self->{user} eq "sys" ?
          { RaiseError => 0, AutoCommit => 0, PrintError => 0,
              #ora_session_mode => DBD::Oracle::ORA_SYSDBA  } :
              ora_session_mode => 0x0002  } :
          { RaiseError => 0, AutoCommit => 0, PrintError => 0 };
      if ($self->{handle} = DBI->connect(
          sprintf("DBI:Oracle:%s", $self->{connect}),
          $self->{user},
          $self->{password},
          $connecthash)) {
        $self->{handle}->do(q{
            ALTER SESSION SET NLS_NUMERIC_CHARACTERS=".," });
        $retval = $self;
      } else {
        $self->{errstr} = DBI::errstr();
      }
    };
    if ($@) {
      $self->{errstr} = $@;
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub tnsping {
  my $self = shift;
  my $retval = undef;
  if ($self->{tnsadmin}) {
    $self->{tnsfile} = $self->{tnsadmin}.'/tnanames.ora';
  } elsif ($self->{oraclehome}) {
    $self->{tnsfile} = $self->{oraclehome}.'/network/admin/tnsnames.ora';
  } else {
    $self->{tnsfile} = $ENV{HOME}.'/tnsnames.ora';
  }
  my $re_blank      = '^$';
  my $re_comment    = '^#';
  my $re_tns_sentry = '^'.$self->{sid}.'.*?=';                 # specific entry
  my $re_tns_gentry = '^\w.*?=';                    # generic entry
  my $re_tns_pair   = '\w+\s*\=\s*[\w\.]+';         # used to parse key=val
  my $re_keys       = 'host|port|sid';
  my @tnsfile = split(/\n/, do { local (@ARGV, $/) = $self->{tnsfile}; <> });
  my $found = 0;
  my $datastring = "";
  foreach (@tnsfile) {
    chomp;
    next if /$re_blank/;
    next if /$re_comment/;
    if (/$re_tns_sentry/) {
      $found = 1;
      s/$re_tns_sentry//;
      $datastring = $_;
    }
    if ($found) {
      last if /$re_tns_gentry/;
      $datastring .= $_;
    }
  }
  if ($found) {
    while ($datastring =~ m/($re_tns_pair)/g) {
      my ($key, $value) = split(/=/, $1);
      $key =~ s/^\s+//g;
      $value =~ s/^\s+//g;
      $key =~ s/\s+$//g;
      $value =~ s/\s+$//g;
      next unless $key =~ /$re_keys/i;
      if (lc $key eq "host") {
        $self->{hostname} = $value;
      } elsif (lc $key eq "port") {
        $self->{port} = $value;
      }
    }
  }
  if (exists $self->{hostname} && exists $self->{port}) {
    my $p = Net::Ping->new("tcp");
    $p->{port_num} = $self->{port};
    if ($p->ping($self->{hostname}, $self->{timeout} - 1)) {
      $self->{handle} = 1;
      $retval = $self;
    } else {
      $self->{errstr} = sprintf "tnsping timed out after %d seconds",
          $self->{timeout};
    }
  } else {
    $self->{errstr} = sprintf "could not find host and address for %s",
        $self->{sid};
  }
  return $retval;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  eval {
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    @row = $sth->fetchrow_array();
  }; 
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  if (-f "/tmp/check_oracle_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) = 
        "/tmp/check_oracle_health_simulation/".$self->{mode}; <> };
    @row = split(/\s+/, (split(/\n/, $simulation))[0]);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  eval {
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    $rows = $sth->fetchall_arrayref();
  }; 
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
  if (-f "/tmp/check_oracle_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) = 
        "/tmp/check_oracle_health_simulation/".$self->{mode}; <> };
    @{$rows} = map { [ split(/\s+/, $_) ] } split(/\n/, $simulation);
  }
  return @{$rows};
}

sub func {
  my $self = shift;
  $self->{handle}->func(@_);
}


sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub DESTROY {
  my $self = shift;
  $self->trace(sprintf "disconnecting DBD %s",
      $self->{handle} ? "with handle" : "without handle");
  $self->{handle}->disconnect() if $self->{handle};
}

package DBD::Oracle::Server::Connection::Sqlplus;

use strict;
use File::Temp qw/tempfile/;

our @ISA = qw(DBD::Oracle::Server::Connection);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  $self->{loginstring} = "traditional";
  ($self->{sql_commandfile_handle}, $self->{sql_commandfile}) =
      tempfile($self->{mode}."XXXXX", SUFFIX => ".sql", 
      DIR => $self->system_tmpdir() );
  close $self->{sql_commandfile_handle};
  ($self->{sql_resultfile_handle}, $self->{sql_resultfile}) =
      tempfile($self->{mode}."XXXXX", SUFFIX => ".out", 
      DIR => $self->system_tmpdir() );
  close $self->{sql_resultfile_handle};
  if ($self->{mode} =~ /^server::tnsping/) {
    if (! $self->{connect}) {
      $self->{errstr} = "Please specify a database";
    } else {
      $self->{sid} = $self->{connect};
      $self->{user} ||= time;  # prefer an existing user
      $self->{password} = time;
    }
  } else {
    if ($self->{connect} && ! $self->{user} && ! $self->{password} &&
        $self->{connect} =~ /(\w+)\/(\w+)@(\w+)/) {
      # --connect nagios/oradbmon@bba
      $self->{connect} = $3;
      $self->{user} = $1;
      $self->{password} = $2;
      $self->{sid} = $self->{connect};
      if ($self->{user} eq "sys") {
        delete $ENV{TWO_TASK};
        $self->{loginstring} = "sys";
      } else {
        $self->{loginstring} = "traditional";
      }
    } elsif ($self->{connect} && ! $self->{user} && ! $self->{password} &&
        $self->{connect} =~ /sysdba@(\w+)/) {
      # --connect sysdba@bba
      $self->{connect} = $1;
      $self->{user} = "/";
      $self->{sid} = $self->{connect};
      $self->{loginstring} = "sysdba";
    } elsif ($self->{connect} && ! $self->{user} && ! $self->{password} &&
        $self->{connect} =~ /(\w+)/) {
      # --connect bba
      $self->{connect} = $1;
      # maybe this is a os authenticated user
      delete $ENV{TWO_TASK};
      $self->{sid} = $self->{connect};
      if ($^O ne "hpux") {       #hpux && 1.21 only accepts "DBI:Oracle:SID"
        $self->{connect} = "";   #linux 1.20 only accepts "DBI:Oracle:" + ORACLE_SID
      }
      $self->{user} = '/';
      $self->{password} = "";
      $self->{loginstring} = "extauth";
    } elsif ($self->{user} &&
        $self->{user} =~ /^\/@(\w+)/) {
      # --user /@ubba1
      $self->{user} = $1;
      $self->{sid} = $self->{connect};
      $self->{loginstring} = "passwordstore";
    } elsif ($self->{connect} && $self->{user} && ! $self->{password} &&
        $self->{user} eq "sysdba") {
      # --connect bba --user sysdba
      $self->{connect} = $1;
      $self->{user} = "/";
      $self->{sid} = $self->{connect};
      $self->{loginstring} = "sysdba";
    } elsif ($self->{connect} && $self->{user} && $self->{password}) {
      # --connect bba --user nagios --password oradbmon
      $self->{sid} = $self->{connect};
      $self->{loginstring} = "traditional";
    } else {
      $self->{errstr} = "Please specify database, username and password";
      return undef;
    }
  }
  if (! exists $self->{errstr}) {
    eval {
      $ENV{ORACLE_SID} = $self->{sid};
      $ENV{PATH} = $ENV{ORACLE_HOME}."/bin".
          (defined $ENV{PATH} ? 
          ":".$ENV{PATH} : "");
      $ENV{LD_LIBRARY_PATH} = $ENV{ORACLE_HOME}."/lib".
          (defined $ENV{LD_LIBRARY_PATH} ? 
          ":".$ENV{LD_LIBRARY_PATH} : "");
      # am 30.9.2008 hat perl das /bin/sqlplus in $ENV{ORACLE_HOME}.'/bin/sqlplus' 
      # eiskalt evaluiert und 
      # /u00/app/oracle/product/11.1.0/db_1/u00/app/oracle/product/11.1.0/db_1/bin/sqlplus 
      # draus gemacht. Leider nicht in Mini-Scripts reproduzierbar, sondern nur hier.
      # Das ist der Grund fuer die vielen ' und .
      my $sqlplus = $ENV{ORACLE_HOME}.'/'.'bin'.'/'.'sqlplus';
      if ((-x $ENV{ORACLE_HOME}.'/'.'sqlplus') && ( -f $ENV{ORACLE_HOME}.'/'.'sqlplus')) {
          $sqlplus = $ENV{ORACLE_HOME}.'/'.'sqlplus';
      }
      my $tnsping = $ENV{ORACLE_HOME}.'/'.'bin'.'/'.'tnsping';
      if (! -x $sqlplus) {
        die "nosqlplus\n";
      }
      if ($self->{mode} =~ /^server::tnsping/) {
        if ($self->{loginstring} eq "traditional") {
          $self->{sqlplus} = sprintf "%s -S %s/%s@%s < /dev/null",
              $sqlplus,
              $self->{user}, $self->{password}, $self->{sid};
        } elsif ($self->{loginstring} eq "extauth") {
          $self->{sqlplus} = sprintf "%s -S / < /dev/null",
              $sqlplus;
        } elsif ($self->{loginstring} eq "passwordstore") {
          $self->{sqlplus} = sprintf "%s -S /@%s < /dev/null",
              $sqlplus,
              $self->{user};
        } elsif ($self->{loginstring} eq "sysdba") {
          $self->{sqlplus} = sprintf "%s -S / as sysdba < /dev/null",
              $sqlplus;
        } elsif ($self->{loginstring} eq "sys") {
          $self->{sqlplus} = sprintf "%s -S %s/%s@%s as sysdba < /dev/null",
              $sqlplus,
              $self->{user}, $self->{password}, $self->{sid};
        }
      } else {
        if ($self->{loginstring} eq "traditional") {
          $self->{sqlplus} = sprintf "%s -S %s/%s@%s < %s > %s",
              $sqlplus,
              $self->{user}, $self->{password}, $self->{sid},
              $self->{sql_commandfile}, $self->{sql_resultfile};
        } elsif ($self->{loginstring} eq "extauth") {
          $self->{sqlplus} = sprintf "%s -S / < %s > %s",
              $sqlplus,
              $self->{sql_commandfile}, $self->{sql_resultfile};
        } elsif ($self->{loginstring} eq "passwordstore") {
          $self->{sqlplus} = sprintf "%s -S /@%s < %s > %s",
              $sqlplus,
              $self->{user},
              $self->{sql_commandfile}, $self->{sql_resultfile};
        } elsif ($self->{loginstring} eq "sysdba") {
          $self->{sqlplus} = sprintf "%s -S / as sysdba < %s > %s",
              $sqlplus,
              $self->{sql_commandfile}, $self->{sql_resultfile};
        } elsif ($self->{loginstring} eq "sys") {
          $self->{sqlplus} = sprintf "%s -S %s/%s@%s as sysdba < %s > %s",
              $sqlplus,
              $self->{user}, $self->{password}, $self->{sid},
              $self->{sql_commandfile}, $self->{sql_resultfile};
        }
      }
  
      use POSIX ':signal_h';
      local $SIG{'ALRM'} = sub {
        die "alarm\n";
      };
      my $mask = POSIX::SigSet->new( SIGALRM );
      my $action = POSIX::SigAction->new(
          sub { die "alarm\n" ; }, $mask);
      my $oldaction = POSIX::SigAction->new();
      sigaction(SIGALRM ,$action ,$oldaction );
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
  
      if ($self->{mode} =~ /^server::tnsping/) {
        if (-x $tnsping) {
          my $exit_output = `$tnsping $self->{sid}`;
          if ($?) {
          #  printf STDERR "tnsping exit bumm \n";
          # immer 1 bei misserfolg
          }
          if ($exit_output =~ /^OK \(\d+/m) {
            die "ORA-01017"; # fake a successful connect with wrong password
          } elsif ($exit_output =~ /^(TNS\-\d+)/m) {
            die $1;
          } else {
            die "TNS-03505";
          }
        } else {
          my $exit_output = `$self->{sqlplus}`;
          if ($?) {
            printf STDERR "ping exit bumm \n";
          }
          $exit_output =~ s/\n//g;
          $exit_output =~ s/at $0//g;
          chomp $exit_output;
          die $exit_output;
        }
      } else {
        my $answer = $self->fetchrow_array(
            q{ SELECT 42 FROM dual});
        die unless defined $answer and $answer == 42;
      }
      $retval = $self;
    };
    if ($@) {
      $self->{errstr} = $@;
      $self->{errstr} =~ s/at $0 .*//g;
      chomp $self->{errstr};
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}


sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->create_commandfile($sql);
  my $exit_output = `$self->{sqlplus}`;
  if ($?) {
    printf STDERR "fetchrow_array exit bumm \n";
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @oerrs = map {
      /(ORA\-\d+:.*)/ ? $1 : ();
    } split(/\n/, $output);
    $self->{errstr} = join(" ", @oerrs);
  } else {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    @row = map { convert($_) } 
        map { s/^\s+([\.\d]+)$/$1/g; $_ }         # strip leading space from numbers
        map { s/\s+$//g; $_ }                     # strip trailing space
        split(/\|/, (split(/\n/, $output))[0]);
  }
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  unlink $self->{sql_commandfile};
  unlink $self->{sql_resultfile};
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }

  $self->create_commandfile($sql);
  my $exit_output = `$self->{sqlplus}`;
  if ($?) {
    printf STDERR "fetchrow_array exit bumm %s\n", $exit_output;
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @oerrs = map {
      /(ORA\-\d+:.*)/ ? $1 : ();
    } split(/\n/, $output);
    $self->{errstr} = join(" ", @oerrs);
  } else {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @rows = map { [ 
        map { convert($_) } 
        map { s/^\s+([\.\d]+)$/$1/g; $_ }
        map { s/\s+$//g; $_ }
        split /\|/
    ] } grep { ! /^\d+ rows selected/ } 
        grep { ! /^\d+ [Zz]eilen ausgew / }
        grep { ! /^Elapsed: / }
        grep { ! /^\s*$/ } split(/\n/, $output);
    $rows = \@rows;
  }
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  unlink $self->{sql_commandfile};
  unlink $self->{sql_resultfile};
  return @{$rows};
}

sub func {
  my $self = shift;
  my $function = shift;
  $self->{handle}->func(@_);
}

sub convert {
  my $n = shift;
  # mostly used to convert numbers in scientific notation
  if ($n =~ /^\s*\d+\s*$/) {
    return $n;
  } elsif ($n =~ /^\s*([-+]?)(\d*[\.,]*\d*)[eE]{1}([-+]?)(\d+)\s*$/) {
    my ($vor, $num, $sign, $exp) = ($1, $2, $3, $4);
    $n =~ s/E/e/g;
    $n =~ s/,/\./g;
    $num =~ s/,/\./g;
    my $sig = $sign eq '-' ? "." . ($exp - 1 + length $num) : '';
    my $dec = sprintf "%${sig}f", $n;
    $dec =~ s/\.[0]+$//g;
    return $dec;
  } elsif ($n =~ /^\s*([-+]?)(\d+)[\.,]*(\d*)\s*$/) {
    return $1.$2.".".$3;
  } elsif ($n =~ /^\s*(.*?)\s*$/) {
    return $1;
  } else {
    return $n;
  }
}


sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub DESTROY {
  my $self = shift;
  $self->trace("try to clean up command and result files");
  unlink $self->{sql_commandfile} if -f $self->{sql_commandfile};
  unlink $self->{sql_resultfile} if -f $self->{sql_resultfile};
}

sub create_commandfile {
  my $self = shift;
  my $sql = shift;
  open CMDCMD, "> $self->{sql_commandfile}"; 
  printf CMDCMD "SET HEADING OFF\n";
  printf CMDCMD "SET PAGESIZE 0\n";
  printf CMDCMD "SET LINESIZE 32767\n";
  printf CMDCMD "SET COLSEP '|'\n";
  printf CMDCMD "SET TAB OFF\n";
  printf CMDCMD "SET FEEDBACK OFF\n";
  printf CMDCMD "SET TRIMSPOOL ON\n";
  printf CMDCMD "SET NUMFORMAT 9.999999EEEE\n";
  printf CMDCMD "SPOOL %s\n", $self->{sql_resultfile};
#  printf CMDCMD "ALTER SESSION SET NLS_NUMERIC_CHARACTERS='.,';\n/\n";
  printf CMDCMD "%s\n/\n", $sql;
  printf CMDCMD "EXIT\n";
  close CMDCMD;
}

package DBD::Oracle::Server::Connection::Sqlrelay;

use strict;
use Net::Ping;

our @ISA = qw(DBD::Oracle::Server::Connection);


sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  if ($self->{mode} =~ /^server::tnsping/) {
    if (! $self->{connect}) {
      $self->{errstr} = "Please specify a database";
    } else {
      if ($self->{connect} =~ /([\.\w]+):(\d+)/) {
        $self->{host} = $1;
        $self->{port} = $2;
        $self->{socket} = "";
      } elsif ($self->{connect} =~ /([\.\w]+):([\w\/]+)/) {
        $self->{host} = $1;
        $self->{socket} = $2;
        $self->{port} = "";
      }
    }
  } else {
    if (! $self->{connect} || ! $self->{user} || ! $self->{password}) {
      if ($self->{connect} && $self->{connect} =~ /(\w+)\/(\w+)@([\.\w]+):(\d+)/) {
        $self->{user} = $1;
        $self->{password} = $2;
        $self->{host} = $3; 
        $self->{port} = $4;
        $self->{socket} = "";
      } elsif ($self->{connect} && $self->{connect} =~ /(\w+)\/(\w+)@([\.\w]+):([\w\/]+)/) {
        $self->{user} = $1;
        $self->{password} = $2;
        $self->{host} = $3; 
        $self->{socket} = $4;
        $self->{port} = "";
      } else {
        $self->{errstr} = "Please specify database, username and password";
        return undef;
      }
    } else {
      if ($self->{connect} =~ /([\.\w]+):(\d+)/) {
        $self->{host} = $1;
        $self->{port} = $2;
        $self->{socket} = "";
      } elsif ($self->{connect} =~ /([\.\w]+):([\w\/]+)/) {
        $self->{host} = $1;
        $self->{socket} = $2;
        $self->{port} = "";
      } else {
        $self->{errstr} = "Please specify database, username and password";
        return undef;
      }
    }
  }
  if (! exists $self->{errstr}) {
    eval {
      require DBI;
      use POSIX ':signal_h';
      local $SIG{'ALRM'} = sub {
        die "alarm\n";
      };
      my $mask = POSIX::SigSet->new( SIGALRM );
      my $action = POSIX::SigAction->new(
      sub { die "alarm\n" ; }, $mask);
      my $oldaction = POSIX::SigAction->new();
      sigaction(SIGALRM ,$action ,$oldaction );
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
      if ($self->{handle} = DBI->connect(
          sprintf("DBI:SQLRelay:host=%s;port=%d;socket=%s", $self->{host}, $self->{port}, $self->{socket}),
          $self->{user},
          $self->{password},
          { RaiseError => 1, AutoCommit => 0, PrintError => 1 })) {
        $self->{handle}->do(q{
            ALTER SESSION SET NLS_NUMERIC_CHARACTERS=".," });
        $retval = $self;
        if ($self->{mode} =~ /^server::tnsping/ && $self->{handle}->ping()) {
          # database connected. fake a "unknown user"
          $self->{errstr} = "ORA-01017";
        }
      } else {
        $self->{errstr} = DBI::errstr();
      }
    };
    if ($@) {
      $self->{errstr} = $@;
      $self->{errstr} =~ s/at [\w\/\.]+ line \d+.*//g;
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  $self->trace(sprintf "fetchrow_array: %s", $sql);
  eval {
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    @row = $sth->fetchrow_array();
  };
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  if (-f "/tmp/check_oracle_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) =
        "/tmp/check_oracle_health_simulation/".$self->{mode}; <> };
    @row = split(/\s+/, (split(/\n/, $simulation))[0]);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  $self->trace(sprintf "fetchall_array: %s", $sql);
  eval {
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    $rows = $sth->fetchall_arrayref();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
  if (-f "/tmp/check_oracle_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) =
        "/tmp/check_oracle_health_simulation/".$self->{mode}; <> };
    @{$rows} = map { [ split(/\s+/, $_) ] } split(/\n/, $simulation);
  }
  return @{$rows};
}

sub func {
  my $self = shift;
  $self->{handle}->func(@_);
}


sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub DESTROY {
  my $self = shift;
  #$self->trace(sprintf "disconnecting DBD %s",
  #    $self->{handle} ? "with handle" : "without handle");
  #$self->{handle}->disconnect() if $self->{handle};
}

1;



