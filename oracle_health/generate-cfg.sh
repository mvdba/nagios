#!/bin/bash
#
#

libexec=/abd/app/nagios-plugins/current/libexec

 svc=oracle-health-service.cfg
 cmd=oracle-health-commands.cfg

header() {
cat >&1 <<CAT
#
# $svc
# Generate by $0 at $( date "+%Y-%m-%d %X")
#
# Oracle via check_oracle_health
#

CAT
}

svc() {

cat >>$svc <<CAT
#
define service{
        use                 local-service
        hostgroup_name      abd-oracle
        check_command       $1
        service_description $2
        servicegroups       abd-oracle-health
}
CAT
}

cmd() {

cat >>$cmd <<CAT
# check_oracle_health: $2
define command{
        command_name        $1
        command_line        \$USER1$/check_nrpe -n -H \$HOSTADDRESS$ -c $1
        }

CAT
}

header > $svc
header > $cmd

IFS="
"
for line in $( grep -v '^#' ./list3.txt )
do

    command=$( echo $line | awk '{print $1}')
       desc=$( echo $line | awk -F'(' '{print $2}' | sed -e 's/)//' )
    printf "Generating %-40s [$desc]\n" $command
    svc $command $desc
    cmd $command $desc

done

cat >>$cmd <<CAT

# vim: set ft=nagios:

CAT

cat >>$svc <<CAT
###
### Service group
###

define servicegroup{
        servicegroup_name               abd-oracle-health
        alias                           Abril Digital Oracle Health
}

# vim: set ft=cfg:

CAT

