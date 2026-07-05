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

# Start up server.
./httpserver -t 2 $port > output.txt 2>error.txt &
pid=$!

# Wait until we can connect.
wait_for_listen $port
wait_rc=$?

if [[ $wait_rc -eq 1 ]]; then
    echo "Server didn't listen on $port in time"
    kill -9 $pid
    wait $pid &>/dev/null
    exit 1
fi

# Count OS threads robustly via /proc/<pid>/task (one entry per thread,
# including the main dispatcher). The old `ps -o thcount | cut -d' ' -f5`
# yielded an empty string for 2-digit counts (mis-tokenized columns) and
# never gated. Convention: N workers (-t value) + 1 dispatcher(main) = N+1.
rc=0
count=`ls /proc/$pid/task | wc -l`
if [ "$count" -ne 3 ]; then
    msg="Server created $count threads instead of 3 (-t 2 => 2 workers + 1 dispatcher)\n"
    rc=1
fi

# Clean up.
## Make sure the server is dead.
kill -9 $pid
wait $pid &>/dev/null



port=`get_port`

if [[ port -eq 1 ]]; then
    exit 1
fi

# Start up server.
./httpserver $port > output.txt 2>error.txt &
pid=$!

# Wait until we can connect.
wait_for_listen $port
wait_rc=$?

if [[ $wait_rc -eq 1 ]]; then
    echo "Server didn't listen on $port in time"
    kill -9 $pid
    wait $pid &>/dev/null
    exit 1
fi

# NB: do NOT reset rc here -- resetting made only the last check gate.
count=`ls /proc/$pid/task | wc -l`
if [ "$count" -ne 4 ]; then
    msg="${msg}Server created $count threads instead of 4 (default => 3 workers + 1 dispatcher)\n"
    rc=1
fi

# Clean up.
## Make sure the server is dead.
kill -9 $pid
wait $pid &>/dev/null



port=`get_port`

if [[ port -eq 1 ]]; then
    exit 1
fi

# Start up server.
./httpserver -t 8 $port > output.txt 2>error.txt &
pid=$!

# Wait until we can connect.
wait_for_listen $port
wait_rc=$?

if [[ $wait_rc -eq 1 ]]; then
    echo "Server didn't listen on $port in time"
    kill -9 $pid
    wait $pid &>/dev/null
    exit 1
fi

# NB: do NOT reset rc here either (see above).
count=`ls /proc/$pid/task | wc -l`
if [ "$count" -ne 9 ]; then
    msg="${msg}Server created $count threads instead of 9 (-t 8 => 8 workers + 1 dispatcher)\n"
    rc=1
fi

# Clean up.
## Make sure the server is dead.
kill -9 $pid
wait $pid &>/dev/null


if [[ $rc -eq 0 ]]; then
    echo "It worked!"
else
    echo "--------------------------------------------------------------------------------"
    echo "$msg"
    echo "--------------------------------------------------------------------------------"
    echo "stdout:"
    cat output.txt
    echo "--------------------------------------------------------------------------------"
    echo "stderr:"
    cat error.txt
    echo "--------------------------------------------------------------------------------"
fi


exit $rc
