#!/bin/bash
#
#

libexec=/abd/app/nagios-plugins/current/libexec

 ora_sid=orcl
ora_user=top10
ora_pass=top10

nrpe=oracle-health-nrpe-${ora_sid}.cfg

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

header > $nrpe

IFS="
"
for line in $( grep -v '^#' ./list2.txt )
do

    command=$( echo $line | awk '{print $1}')
       desc=$( echo $line | awk -F'(' '{print $2}' | sed -e 's/)//' )
    printf "Generating %-40s [$desc]\n" $command
#   printf "command[$command]=%-110s --connect=%-10s --user=%-10s --password=%-10s --unit=GB --mode=%-s\n" $libexec/check_oracle_health $ora_sid $ora_user $ora_pass $command >> $nrpe
    printf "command[$command]=%s --connect=%s --user=%s --password=%s --unit=GB --mode=%-s\n" $libexec/check_oracle_health $ora_sid $ora_user $ora_pass $command >> $nrpe

done

cat >>$nrpe <<CAT

# vim: set ft=nagios:

CAT


