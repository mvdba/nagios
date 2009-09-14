
./check_oracle_health -v \
    --connect=orcl --user=system --password=sys \
    --mode=list-tablespaces \
    --mode=tnsping \
    --mode=invalid-objects \
    --mode=tablespace-free  \
    --mode=list-sysstats    \
    --mode=list-events    \
    --units=GB

