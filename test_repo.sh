#!/usr/bin/env bash

# Track whether any per-script run failed. Without this the script had no exit
# statement at all, so it always returned 0 and could never fail CI even when a
# gate script (e.g. threads_custom.sh) reported FAILED.
overall_rc=0

for test in `ls test_scripts/*.sh`; do
    if [ "$test" != "test_scripts/utils.sh" ]; then
	if [ "$test" != "test_scripts/test_workload.sh" ]; then
	    echo "------------------------------------------------------------------------"
	    printf "$test:\n"
	    echo "------------------------------------------------------------------------"

	    output=$(./$test)
	    return_code=$?
	    if [ $return_code -eq 0 ]; then
		printf "SUCCESS\n\n"
	    else
		printf "FAILED\n\n"
		printf "Return code: $return_code\n"
		printf "Output:\n$output\n\n"
		overall_rc=1
	    fi
	fi
    fi

done

exit $overall_rc
