
./configure \
    --prefix=/abd/app/nagios-plugins/current \
    --with-nagios-user=nagios \
    --with-nagios-group=nagios \
    --with-mymodules-dir=/abd/app/nagios-plugins/current/libexec \
    --with-mymodules-dyn-dir=/abd/app/nagios-plugins/current/libexec \
    --with-perl=/usr/bin/perl
#   --with-statefiles-dir=PATH sets directory for the state files (default=/var/tmp/check_oracle_health)

