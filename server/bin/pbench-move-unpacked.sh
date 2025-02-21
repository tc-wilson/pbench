#! /bin/bash
# -*- mode: shell-script -*-

# This script will run only on production environment as unpacking to incoming
# is relatively slower than unpacking tarballs in a tmp directory and then
# move it to incoming.

# load common things
. $dir/pbench-base.sh
. $dir/job_pool.sh

# check that all the directories exist
test -d $ARCHIVE || doexit "Bad ARCHIVE=$ARCHIVE"
test -d $INCOMING || doexit "Bad INCOMING=$INCOMING"

UNPACK_PATH=$(getconf.py pbench-unpack-dir pbench-server)
test -d $UNPACK_PATH || doexit "Bad UNPACK_PATH=$UNPACK_PATH"

if [ "$(readlink -e $INCOMING)" = "$(readlink -e $UNPACK_PATH)" ]; then
    echo "$TS: the unpack path, $UNPACK_PATH, is the same as the incoming path, $INCOMING; nothing to do"
    exit 0
fi

# make sure only one copy is running.
# Use 'flock -n $LOCKFILE /home/pbench/bin/pbench-move-unpacked' in the
# crontab to ensure that only one copy is running. The script itself
# does not use any locking.

# the link source and destination for this script
linksrc=UNPACKED
linkdest=MOVED-UNPACKED

tmp=$TMP/$PROG.$$
trap 'rm -rf $tmp' EXIT INT QUIT

mkdir -p $tmp || doexit "Failed to create $tmp"

log_init $PROG

echo $TS

# Accumulate errors and logs in files for reporting at the end.
mail_content=$tmp/mail_content.log
index_content=$tmp/index_mail_contents

# get the list of files we'll be operating on - sort them by size
list=$tmp/$PROG.list

# Find all the links in all the $ARCHIVE/<controller>/$linksrc
# directories, emitting a list of their full paths with the size
# in bytes of the file the link points to, and then sort them so
# that we process the smallest tar balls first.
> ${list}.unsorted
# First we find all the $linksrc directories
for linksrc_dir in $(find $ARCHIVE/ -maxdepth 2 -type d -name $linksrc); do
    # Find all the links in a given $linksrc directory that are
    # links to actual files (bad links are not emitted!).
    find -L $linksrc_dir -type f -name '*.tar.xz' -printf "%s %p\n" 2>/dev/null >> ${list}.unsorted
    # Find all the links in the same $linksrc directory that don't
    # link to anything so that we can count them as errors below.
    find -L $linksrc_dir -type l -name '*.tar.xz' -printf "%s %p\n" 2>/dev/null >> ${list}.unsorted
done
sort -n ${list}.unsorted > ${list}
rm -f ${list}.unsorted

# If there is nothing to be done, exit now: do not create the job
# pool.

# This is a workaround for a job pool problem: it seems that a
# job termination message gets lost, so occasionally the script hangs with
# a job pool process trying to read the next job from the job pool
# queue, but there *is* no next job. This seems to happen *only* when
# there is no work to be done.

if [[ ! -s $list ]] ;then
    echo "$TS: Processed 0 tarballs"
    log_finish
    exit 0
fi

# Initialize report content
> $mail_content
> $index_content

function process_tarball {
    result=$1
    size=$2

    link=$(readlink -e $result)
    if [ -z "$link" ] ;then
        echo "$TS: symlink target for $result does not exist" | tee -a $mail_content >&4
        # FIXME: quarantine $result
        return 1
    fi
    resultname=$(basename $result)
    resultname=${resultname%.tar.xz}

    # XXXX - for now, if it's a duplicate name, just punt and avoid
    # producing the error
    if [ ${resultname%%.*} == "DUPLICATE__NAME" ] ;then
        # FIXME: quarantine $result
        return 2
    fi

    basedir=$(dirname $link)
    hostname=$(basename $basedir)

    # make sure that all the relevant state directories exist
    mk_dirs $hostname
    # ... and a couple of other necessities.
    if [[ $? -ne 0 ]] ;then
        echo "$TS: Creation of $hostname processing directories failed for $result: code $status" | tee -a $mail_content >&4
        # FIXME: quarantine $result
        return 1
    fi
    mkdir -p $INCOMING/$hostname
    if [[ $? -ne 0 ]] ;then
        echo "$TS: Creation of $INCOMING/$hostname failed for $result: code $status" | tee -a $mail_content >&4
        # FIXME: quarantine $result
        return 1
    fi
    incoming=$INCOMING/$hostname/$resultname
    if [ -L $incoming ]; then
        # assert $incoming is a symlink
        :
    elif [ -d $incoming ]; then
        echo "$TS: Incoming result, $INCOMING/$hostname/$resultname/, already exists as a directory, skipping $result" | tee -a $mail_content >&4
        # FIXME: quarantine $result
        return 1
    else
	# impossible!
	echo "$TS: Cannot happen - $incoming is not a symlink or does not exist!" | tee -a $mail_content >&4
        # FIXME: quarantine $result
	return 1
    fi

    let start_time=$(timestamp-seconds-since-epoch)

    # log the beginning process of tarball
    echo "Starting: $TS: $hostname/$resultname: size (bytes): $size"

    # copy the tarball contents to INCOMING - remove the link on failure
    cp -a $UNPACK_PATH/$hostname/$resultname ${incoming}.copy
    status=$?
    if [[ $status -ne 0 ]] ;then
        echo "$TS: Cannot copy $UNPACK_PATH/$hostname/$resultname to ${incoming}.copy: code $status" | tee -a $mail_content >&4
        rm -rf ${incoming}.copy
        return 1
    fi

    # Move the symlink to the side
    mv -T $incoming ${incoming}.link
    status=$?
    if [[ $status -ne 0 ]] ;then
        # move failed, $incoming.copy still exists, remove it
        rm -rf ${incoming}.copy
        echo "$TS: Cannot rename $incoming to ${incoming}.link: code $status" | tee -a $mail_content >&4
        return 1
    fi

    # NOTE: this is a window where the result symlink points to nothing.

    # Rename the copied result hierarchy to its original name.
    mv ${incoming}.copy $incoming
    status=$?
    if [[ $status -ne 0 ]] ;then
        # move failed, $incoming.copy still exists, remove it
        rm -rf ${incoming}.copy
        mv -f ${incoming}.link ${incoming}
        echo "$TS: Cannot rename $incoming.copy to $incoming: code $status" | tee -a $mail_content >&4
        return 1
    fi

    rm -f ${incoming}.link
    status=$?
    if [[ $status -ne 0 ]] ;then
        echo "$TS: WARNING, could not remove ${incoming}.link: code $status" | tee -a $mail_content >&4
    fi

    # remove the unpacked tarballs from UNPACK_PATH directory
    rm -R $UNPACK_PATH/$hostname/$resultname
    status=$?
    if [[ $status -ne 0 ]] ;then
        echo "$TS: Cannot remove $UNPACK_PATH/$hostname/$resultname: code $status" | tee -a $mail_content >&4
	return 1
    fi

    # move the link to $linkdest directory
    mv $ARCHIVE/$hostname/$linksrc/$resultname.tar.xz $ARCHIVE/$hostname/$linkdest/$resultname.tar.xz
    status=$?
    if [[ $status -ne 0 ]] ;then
        echo "$TS: Cannot move $ARCHIVE/$hostname/$resultname from $linksrc to $linkdest: code $status" | tee -a $mail_content >&4
        return 1
    fi
    let end_time=$(timestamp-seconds-since-epoch)
    let duration=end_time-start_time
    # log the success
    echo "$TS: $hostname/$resultname: success - elapsed time (secs): $duration - size (bytes): $size"
}

# get the concurrency factor from the config file if present - otherwise set it to 1
njobs=$(getconf.py njobs pbench-move-unpacked)
if [[ -z $njobs ]] ;then
    njobs=1
fi

# echo job pool commands
job_pool_echo_command=1

job_pool_init $njobs 0

typeset -i ntb=0
while read size result ;do
    # add a job to the pool for the item
    job_pool_run process_tarball $result $size
    ntb=$ntb+1
done < $list

# There is no need to call job_pool_wait: it only needs to be called
# when we want to wait for the current batch to finish and then start
# another batch.

# Shut down the job pool
job_pool_shutdown

echo "$TS: Processed $ntb tar balls"

log_finish

subj="$PROG.$TS($PBENCH_ENV) - $ntb tar balls"
cat << EOF > $index_content
$subj
Processed $ntb result tar balls

EOF
cat $mail_content >> $index_content
pbench-report-status --name $PROG --timestamp $(timestamp) --type status $index_content

exit 0
