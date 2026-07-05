#!/usr/bin/env bash

source_dir=`dirname ${BASH_SOURCE}`
source "$source_dir/utils.sh"


if [[ `check_dir` -eq 1 ]]; then
    exit 1
fi

port=`get_port`

if [[ port -eq 1 ]]; then
    exit 1
fi

batch=$1
threads=$2


outs=outs/
auditlog=auditlog
requests=oliver.out
stdout=stdout.txt

new_files="$outs $auditlog $requests $stdout"

# Start up server.
./httpserver -t $threads $port >$stdout 2>$auditlog&
pid=$!


# Wait until we can connect.
wait_for_listen $port
wait_rc=$?

if [[ $wait_rc -eq 1 ]]; then
    echo "Server didn't listen on $port in time"
    kill -9 $pid
    wait $pid &>/dev/null
    cleanup $new_files
    exit 1
fi

# Oliver sends our test
1>&2 echo "Oliver going to work"
./test_scripts/olivertwist.py -o localhost -d $outs -p $port $batch > $requests
oliversays=$?
1>&2 echo "Oliver leaving work"

# Clean up.
## TSan-instrumented runs only (test_scripts/san_stress.sh thread,
## DECISIONS.md D20/D21): give in-flight audit writes a moment to land before
## the hard kill. The server sends each response *before* writing its audit
## line (see src/httpserver.c, conn_send_response -> audit_send_response), so
## oliver can have observed the final responses while their audit lines are
## still microseconds away from log_audit's fprintf+fflush; an immediate
## kill -9 can then truncate the tail of the audit log, and watson flags the
## missing lines as replay mismatches. Under TSan (~5-20x slowdown) that
## window was hit in practice (one conflict_stress_mix run failed watson with
## zero sanitizer reports); 0.3s is orders of magnitude wider than it.
## Deliberately NOT unconditional: on ordinary un-instrumented runs the gate
## must keep its full sharpness -- a server bug that delayed the audit write
## by up to 300ms under contention would be absorbed by an unconditional
## sleep. Detection matches threads_custom.sh's: __tsan_init only exists in
## a TSan-instrumented binary.
if grep -q __tsan_init ./httpserver; then
    sleep 0.3
fi
## Make sure the server is dead.
kill -9 $pid
wait $pid &>/dev/null


rc=0
# is oliver happy?
if [ $oliversays -ne 0 ]; then
    msg="Oliver is not happy with you"
    rc=1
fi

# Sherlock tells us if the audit log is valid given Oliver's reported log.
./test_scripts/sherlock.py --audit-log=$auditlog --oliver-log=$requests
if [[ $? -ne 0 ]]; then
    msg=$"${msg}sherlock: audit log contains invalid total ordering"$'\n'
    rc=1
fi

# Watsons tells us if the replayed log matches the state of the recorded responses.
./test_scripts/watson.py --audit-log=$auditlog --oliver-events=$batch --response-dir=$outs
if [[ $? -ne 0 ]]; then
    msg=$"${msg}watson: outputs are inconsistent with audit log"$'\n'
    rc=1
fi

if [[ $rc -eq 0 ]]; then
    echo "It worked!"
else
    echo "--------------------------------------------------------------------------------"
    echo "$msg"
    echo "--------------------------------------------------------------------------------"
    echo "stdout:"
    cat $stdout
    echo "--------------------------------------------------------------------------------"
fi

cleanup $new_files
exit $rc
