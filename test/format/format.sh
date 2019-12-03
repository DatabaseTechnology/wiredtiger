#! /bin/bash

[ -z $BASH_VERSION ] && {
	echo "$0 is a bash script: \$BASH_VERSION not set, exiting"
	exit 1
}

# Enable job control so child processes we create appear in their own process groups and we can
# individually terminate (and clean up) running jobs and their children.
set -m

name=$(basename $0)

quit=0
force_quit=0
onintr()
{
	echo "$name: interrupted, cleaning up..."
	force_quit=1
}
trap 'onintr' 2

usage() {
	echo "usage: $0 [-aFSv] [-c config] "
	echo "    [-h home] [-j parallel-jobs] [-n total-jobs] [-t minutes] [format-configuration]"
	echo
	echo "    -a           abort/recovery testing (defaults to off)"
	echo "    -c config    format configuration file (defaults to CONFIG.stress)"
	echo "    -F           quit on first failure (defaults to off)"
	echo "    -h home      run directory (defaults to .)"
	echo "    -j parallel  jobs to execute in parallel (defaults to 8)"
	echo "    -n total     total jobs to execute (defaults to no limit)"
	echo "    -S           run smoke-test configurations (defaults to off)"
	echo "    -t minutes   minutes to run (defaults to no limit)"
	echo "    -v           verbose output (defaults to off)"
	echo "    --           separates $name arguments from format arguments"

	exit 1
}

# Smoke-tests.
smoke_base_1="data_source=table rows=100000 threads=6 timer=4"
smoke_base_2="$smoke_base_1 leaf_page_max=9 internal_page_max=9"
smoke_list=(
	# Three access methods.
	"$smoke_base_1 file_type=fix"
	"$smoke_base_1 file_type=row"
	"$smoke_base_1 file_type=var"

	# Huffman key/value encoding.
	"$smoke_base_1 file_type=row huffman_key=1 huffman_value=1"
	"$smoke_base_1 file_type=var huffman_key=1 huffman_value=1"

	# Abort/recovery test.
	"$smoke_base_1 file_type=row abort=1"

	# LSM
	"$smoke_base_1 file_type=row data_source=lsm"

	# Force tree rebalance and the statistics server.
	"$smoke_base_1 file_type=row statistics_server=1 rebalance=1"

	# Overflow testing.
	"$smoke_base_2 file_type=var value_min=256"
	"$smoke_base_2 file_type=row key_min=256"
	"$smoke_base_2 file_type=row key_min=256 value_min=256"
)
smoke_next=0

abort_test=0
build=""
config="CONFIG.stress"
first_failure=0
format_args=""
home="."
minutes=0
parallel_jobs=8
smoke_test=0
total_jobs=0
verbose=0

while :; do
	case "$1" in
	-a)
		abort_test=1
		shift ;;
	-c)
		config="$2"
		shift ; shift ;;
	-F)
		first_failure=1
		shift ;;
	-h)
		home="$2"
		shift ; shift ;;
	-j)
		parallel_jobs="$2"
		[[ "$parallel_jobs" =~ ^[1-9][0-9]*$ ]] || {
			echo "$name: -j option argument must be a non-zero integer"
			exit 1
		}
		shift ; shift ;;
	-n)
		total_jobs="$2"
		[[ "$total_jobs" =~ ^[1-9][0-9]*$ ]] || {
			echo "$name: -n option argument must be an non-zero integer"
			exit 1
		}
		shift ; shift ;;
	-S)
		smoke_test=1
		shift ;;
	-t)
		minutes="$2"
		[[ "$minutes" =~ ^[1-9][0-9]*$ ]] || {
			echo "$name: -t option argument must be a non-zero integer"
			exit 1
		}
		shift ; shift ;;
	-v)
		verbose=1
		shift ;;
	--)
		shift; break;;
	-*)
		usage ;;
	*)
		break ;;
	esac
done
format_args="$*"

verbose()
{
	[[ $verbose -ne 0 ]] && echo "$@"
}

verbose "$name: run starting at $(date)"

# Find a component we need.
# $1 name to find
find_file()
{
	# Get the directory path to format.sh, which is always in wiredtiger/test/format, then
	# use that as the base for all the other places we check.
	d=$(dirname $0)

	# Check wiredtiger/test/format/, likely location of the format binary and the CONFIG file.
	f="$d/$1"
	if [[ -f "$f" ]]; then
		echo "$f"
		return
	fi

	# Check wiredtiger/build_posix/test/format/, likely location of the format binary and the
	# CONFIG file.
	f="$d/../../build_posix/test/format/$1"
	if [[ -f "$f" ]]; then
		echo "$f"
		return
	fi

	# Check wiredtiger/, likely location of the wt binary.
	f="$d/../../$1"
	if [[ -f "$f" ]]; then
		echo "$f"
		return
	fi

	# Check wiredtiger/build_posix/, likely location of the wt binary.
	f="$d/../../build_posix/$1"
	if [[ -f "$f" ]]; then
		echo "$f"
		return
	fi

	echo "./$1"
}

# Find the format and wt binaries (the latter is only required for abort/recovery testing),
# the configuration file and the run directory.
format_binary=$(find_file "t")
[[ ! -x "$format_binary" ]] && {
	echo "$name: format program \"$format_binary\" not found"
	exit 1
}
[[ $abort_test -ne 0 ]] || [[ $smoke_test -ne 0 ]] && {
	wt_binary=$(find_file "wt")
	[[ ! -x "$wt_binary" ]] && {
		echo "$name: wt program \"$wt_binary\" not found"
		exit 1
	}
}
config=$(find_file "$config")
[[ -f "$config" ]] || {
	echo "$name: configuration file \"$config\" not found"
	exit 1
}
[[ -d "$home" ]] || {
	echo "$name: directory \"$home\" not found"
	exit 1
}

verbose "$name configuration: $format_binary [-c $config]\
[-h $home] [-j $parallel_jobs] [-n $total_jobs] [-t $minutes] $format_args"

failure=0
success=0
running=0
status="format.sh-status"

# Report a failure.
# $1 directory name
report_failure()
{
	dir=$1
	log="$dir.log"

	echo "$name: failure status reported" > $dir/$status
	failure=$(($failure + 1))

	# Forcibly quit if first-failure configured.
	[[ $first_failure -ne 0 ]] && force_quit=1

	echo "$name: job in $dir failed"
	echo "$name: $dir log:"
	sed 's/^/    > /' < $log
}

# Resolve/cleanup completed jobs.
resolve()
{
	running=0
	list=$(ls $home | grep '^RUNDIR.[0-9]*$')
	for i in $list; do
		dir="$home/$i"
		log="$dir.log"

		# Skip directories that aren't ours.
		[[ ! -f "$log" ]] && continue

		# Skip failures we've already reported.
		[[ -f "$dir/$status" ]] && continue

		# Get the process ID, ignore any jobs that aren't yet running.
		pid=`grep -E 'process.*running' $log | awk '{print $3}'`
		[[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue

		# Leave any process waiting for a gdb attach running, but report it as a failure.
		grep -E 'waiting for debugger' $log > /dev/null && {
			report_failure $dir
			continue
		}

		# If the job is still running, ignore it unless we're forcibly quitting.
		kill -s 0 $pid > /dev/null 2>&1 && {
			[[ $force_quit -eq 0 ]] && {
				running=$((running + 1))
				continue
			}

			# Kill the process group to catch any child processes.
			kill -KILL -- -$pid
			wait $pid

			# Remove jobs we killed, they count as neither success or failure.
			rm -rf $dir $log
			verbose "$name: job in $dir killed"
			continue
		}

		# Wait for the job and get an exit status.
		wait $pid
		eret=$?

		# Remove successful jobs.
		grep 'successful run completed' $log > /dev/null && {
			rm -rf $dir $log
			success=$(($success + 1))
			verbose "$name: job in $dir successfully completed"
			continue
		}

		# Test recovery on jobs configured for random abort. */
		grep 'aborting to test recovery' $log > /dev/null && {
			cp -pr $dir $dir.RECOVER

			(echo
			 echo "$name: running recovery after abort test"
			 echo "$name: original directory copied into $dir.RECOVER"
			 echo) >> $log

			# Everything is a table unless explicitly a file.
			uri="table:wt"
			grep 'data_source=file' $dir/CONFIG > /dev/null && uri="file:wt"
						
			# Use the wt utility to recover & verify the object.
			if  $($wt_binary -R -h $dir verify $uri >> $log 2>&1); then
				rm -rf $dir $dir.RECOVER $log
				success=$(($success + 1))
				verbose "$name: job in $dir successfully completed"
			else
				echo "$name: job in $dir failed abort/recovery testing"
				report_failure $dir
			fi
			continue
		}

		# Check for the library abort message, or an error from format.
		grep -E \
		    'aborting WiredTiger library|format alarm timed out|run FAILED' \
		    $log > /dev/null && {
			report_failure $dir
			continue
		}

		# There's some chance we just dropped core. We have the exit status of the process,
		# but there's no way to be sure. There are reasons the process' exit status looks
		# like a core dump was created (format deliberately causes a segfault in the case
		# of abort/recovery testing, and does work that can often segfault in the case of a
		# snapshot-isolation mismatch failure), but those cases have already been handled,
		# format is responsible for logging a failure before the core can happen. If the
		# process exited with a likely failure, call it a failure.
		signame=""
		case $eret in
		$((128 + 3)))
			signame="SIGQUIT";;
		$((128 + 4)))
			signame="SIGILL";;
		$((128 + 6)))
			signame="SIGABRT";;
		$((128 + 7)))
			signame="SIGBUS";;
		$((128 + 8)))
			signame="SIGFPE";;
		$((128 + 11)))
			signame="SIGSEGV";;
		$((128 + 24)))
			signame="SIGXCPU";;
		$((128 + 25)))
			signame="SIGXFSZ";;
		$((128 + 31)))
			signame="SIGSYS";;
		esac
		[[ ! -z $signame ]] && {
			(echo
			 echo "$name: job in $dir killed with signal $signame"
			 echo "$name: there may be a core dump associated with this failure"
			 echo) >> $log

			echo "$name: job in $dir killed with signal $signame"
			echo "$name: there may be a core dump associated with this failure"

			report_failure $dir
			continue
		}

	done
	return 0
}

# Start a single job.
count_jobs=0
format()
{
	count_jobs=$(($count_jobs + 1))
	dir="$home/RUNDIR.$count_jobs"
	log="$dir.log"

	if [[ $smoke_test -ne 0 ]]; then
		args=${smoke_list[$smoke_next]}
		smoke_next=$(($smoke_next + 1))
		echo "$name: starting smoke-test job in $dir"
	else
		args=$format_args

		# If abort/recovery testing is configured, do it 5% of the time.
		[[ $abort_test -ne 0 ]] && [[ $(($count_jobs % 20)) -eq 0 ]] && args="$args abort=1"

		echo "$name: starting job in $dir"
	fi

	cmd="$format_binary -c "$config" -h "$dir" -1 $args quiet=1"
	verbose "$name: $cmd"

	# Disassociate the command from the shell script so we can exit and let the command
	# continue to run.
	nohup $cmd > $log 2>&1 &
}

seconds=$((minutes * 60))
start_time="$(date -u +%s)"
while :; do
	# Check if our time has expired.
	[[ $seconds -ne 0 ]] && {
		now="$(date -u +%s)"
		elapsed=$(($now - $start_time))

		# If we've run out of time, terminate all running jobs.
		[[ $elapsed -ge $seconds ]] && {
			verbose "$name: run timed out at $(date)"
			force_quit=1
		}
	}

	# Start more jobs.
	while :; do
		# Check if we're only running the smoke-tests and we're done.
		[[ $smoke_test -ne 0 ]] && [[ $smoke_next -ge ${#smoke_list[@]} ]] && quit=1
	
		# Check if the total number of jobs has been reached.
		[[ $total_jobs -ne 0 ]] && [[ $count_jobs -ge $total_jobs ]] && quit=1

		# Check if less than 60 seconds left on any timer. The goal is to avoid killing
		# jobs that haven't yet configured signal handlers, because we rely on handler
		# output to determine their final status.
		[[ $seconds -ne 0 ]] && [[ $(($seconds - $elapsed)) -lt 60 ]] && quit=1

		# Don't create more jobs if we're quitting for any reason.
		[[ $force_quit -ne 0 ]] || [[ $quit -ne 0 ]] && break;

		# Check if the maximum number of jobs in parallel has been reached.
		[[ $running -ge $parallel_jobs ]] && break
		running=$(($running + 1))

		# Start another job, but don't pound on the system.
		format
		sleep 2
	done

	# Clean up and update status.
	success_save=$success
	failure_save=$failure
	resolve
	[[ $success -ne $success_save ]] || [[ $failure -ne $failure_save ]] &&
	    echo "$name: $success successful jobs, $failure failed jobs"

	# Quit if we're done and there aren't any jobs left to wait for.
	[[ $quit -ne 0 ]] || [[ $force_quit -ne 0 ]] && [[ $running -eq 0 ]] && break

	# Wait for awhile, unless we're killing everything or there are jobs to start.
	[[ $force_quit -eq 0 ]] && [[ $running -ge $parallel_jobs ]] && sleep 10
done

echo "$name: $success successful jobs, $failure failed jobs"

verbose "$name: run ending at $(date)"
[[ $failure -ne 0 ]] && exit 1
exit 0
