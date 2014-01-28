#!/bin/bash

# This script managed by Puppet, in the ElasticSearch module
# credits: http://tech.superhappykittymeow.com/?p=296

# It is highly recommended that you diable the ability to
# accidentally delete all of your indices, should one of
# these variables get borked.
# Set 'action.disable_delete_all_indices' to be true!

KEEPDAYS="60days"
INDEXPREFIX="logstash"
DATAROOT="/usr/local/elasticsearch"
INDEXDIRS=("data1" "data2") # Some folks have multiple data locations
BACKUPCMD="/usr/local/backupTools/s3cmd --config=/usr/local/backupTools/s3cfg put"
BACKUPDIR="/mnt/es-backups"
S3ROOT="s3://backups/elasticsearch"
DRYRUN=false
NOS3=false
WEIRDOS=true

while test $# -gt 0; do
    case "$1" in
        -h|--help)
            echo "Dark Crystal - Back up ElasticSearch Indices"
            echo " "
            echo "darkcrystal [options]"
            echo " "
            echo "options:"
            echo "-h, --help                show brief help"
            echo "-d, --dryrun              don't really do anything"
            echo "-s, --skips3              don't send anything to S3"
            echo "-w, --weirdos             leave weirdos alone"

            exit 0
            ;;
        -d|--dryrun)
            shift
            DRYRUN=true
            echo "Dry Run selected, no action will be taken."
            shift
            ;;
        -s|--skips3)
            shift
            NOS3=true
            echo "S3 Backup will be skipped."
            shift
            ;;
        -w|--weirdos)
            shift
            WEIRDOS=false
            echo "Weirdo indices won't be deleted."
            shift
            ;;
        *)
            echo "Not an option."
            break
            ;;
    esac
done

if $WEIRDOS; then
    ## First we delete any weirdo indexes:
    TIMESTAMPFAIL=`curl -s localhost:9200/_status?pretty=true |grep index |grep log |sort |uniq |awk -F\" '{print $4}' |grep 1970 |wc -l`
    if [ -n $TIMESTAMPFAIL ]
    then
        curl -s localhost:9200/_status?pretty=true |grep index |grep log |sort |uniq |awk -F\" '{print $4}' |grep 1970 | while read line
    do
        echo "Indices with screwed-up timestamps found; removing"
        echo -n "Deleting index $line... "
        if $DRYRUN; then
            echo
            echo "curl -s -XDELETE http://localhost:9200/$line/"
        else
            curl -s -XDELETE http://localhost:9200/$line/
        fi
        echo "DONE!"
    done
    fi
else
    echo "Weirdo indices left to their own devices."
fi

# Herein we backup our indexes! This script should run at like 6pm or something, after logstash
# rotates to a new ES index and theres no new data coming in to the old one.  We grab metadatas,
# compress the data files, create a restore script, and push it all up to S3.

# This will give us a sorted array of all indices, oldest first"
ALLINDICES=( `curl -s localhost:9200/_status?pretty=true |grep index |grep log |sort |uniq |awk -F\" '{print $4}'` )

# Find the oldest index we want to keep:
now=`date`
KEEPUNTIL=`date --date="$now-$KEEPDAYS" "+$INDEXPREFIX-%Y.%m.%d"`
echo "You've elected to keep indices up until $KEEPUNTIL."

# Start an array of all indices for use later
declare -a INDICES=($KEEPUNTIL)

# Does that index actually exist?
if [[ "$(declare -p ALLINDICES)" =~ '['([0-9]+)']="'$KEEPUNTIL'"' ]]; then
    echo "Found $KEEPUNTIL at offset ${BASH_REMATCH[1]}"
    arrayindex=${BASH_REMATCH[1]}
else
    echo "Couldn't find $KEEPUNTIL, stopping."
    exit 1
fi

# Create backup directory
if $DRYRUN; then
    echo "mkdir -p $BACKUPDIR"
else
    mkdir -p $BACKUPDIR
fi

# Loop from the beginning (oldest) of the index names array until we reach KEEPUNTIL's array index.
# Back up all indices older than KEEPUNTIL
for (( indexnumber=0; indexnumber <= $arrayindex; indexnumber++ ))
do
    # Set up variables:
    indexname=${ALLINDICES[$indexnumber]} # This had better match the index name in ES!
    echo "##################################################"
    echo "Working with index $indexname"

    INDICES=("${INDICES[@]}" $indexname)

    # Create mapping file with index settings. This metadata is required by ES to use index file data.
    echo -n "Backing up metadata... "

    if $DRYRUN; then
        echo
        echo "curl -XGET -o /tmp/mapping \"http://localhost:9200/$indexname/_mapping?pretty=true\" > /dev/null 2>&1"
        echo "sed -i '1,2d' /tmp/mapping #strip the first two lines of the metadata"
        echo "echo '{\"settings\":{\"number_of_shards\":5,\"number_of_replicas\":2},\"mappings\":{' > /tmp/mappost"
        echo "cat /tmp/mapping >> /tmp/mappost"
    else
        curl -XGET -o /tmp/mapping "http://localhost:9200/$indexname/_mapping?pretty=true" > /dev/null 2>&1
        sed -i '1,2d' /tmp/mapping #strip the first two lines of the metadata
        echo '{"settings":{"number_of_shards":5,"number_of_replicas":2},"mappings":{' > /tmp/mappost
        # Prepend hardcoded settings metadata to index-specific metadata
        cat /tmp/mapping >> /tmp/mappost
    fi
    echo "DONE!"

    # Now lets tar up our data files. These are huge, so lets be nice.
    echo "Archiving data files (this may take some time)... "

    for indexdir in $INDEXDIRS
    do
        indexpath="$DATAROOT/$indexdir/logstash/nodes/0/indices/"
        echo -n "Using data directory $indexpath... "
        cd $indexpath
        # Replace slashes with hypens
        indexdir=${indexdir//\//-}
        if $DRYRUN; then
            echo
            echo "nice -n 19 tar czf $BACKUPDIR/$indexdir_$indexname.tar.gz $indexname"
        else
            nice -n 19 tar czf $BACKUPDIR/$indexdir_$indexname.tar.gz $indexname
        fi
        echo "DONE!"
    done

    echo -n "Creating restore script for $indexname... "
    # Time to create our restore script! Oh glob, scripts creating scripts, this never ends well...
    if $DRYRUN; then
        echo
        echo "cat << EOF >> $BACKUPDIR/$indexname-restore.sh"
    else
        cat << EOF >> $BACKUPDIR/$indexname-restore.sh
        #!/bin/bash
        # This script requires $indexname.tar.gz and will restore it into elasticsearch
        # it is ESSENTIAL that the index you are restoring does NOT exist in ES. Delete it
        # if it does BEFORE trying to restore data.

        # Create index and mapping.
        echo -n "Creating index and mappings... "
        curl -XPUT 'http://localhost:9200/$indexname/' -d '`cat /tmp/mappost`' > /dev/null 2>&1
        echo "DONE!"

        # Extract our data files into place.
        echo -n "Restoring index (this may take a while)... "
        cd $indexdir
        tar xzf $BACKUPDIR/$indexname.tar.gz
        echo "DONE!"

        # Restart ES to allow it to open the new dir and file data.
        echo -n "Restarting Elasticsearch... "
        service elasticsearch restart
        echo "DONE!"
EOF
    fi
echo "##################################################"
echo
done

echo
if $NOS3; then
    echo "Upload to S3 declined, skipping..."
else
    # Push both index tarball and restore script to S3
    echo "Saving to S3 (this may take some time)... "

    for indexname in "${INDICES[@]}"
    do
        indexdate=`echo $indexname | awk -F- '{print $2}'`
        indexyear=`echo $indexdate | awk -F\. '{print $1}'`
        indexmonth=`echo $indexdate | awk -F\. '{print $2}'`
        s3target="$S3ROOT/$indexyear/$indexmonth"
        restorescript="$indexname-restore.sh"

        echo "Saving restore script $restorescript to $s3target... "
        if $DRYRUN; then
            echo "$BACKUPCMD $BACKUPDIR/$restorescript $s3target/$restorescript"
        else
            $BACKUPCMD $BACKUPDIR/$restorescript $s3target/$restorescript
        fi

        echo "DONE!"

        for indexdir in $INDEXDIRS
        do
            indexdir=${indexdir//\//-}
            indexfilename="$indexdir_$indexname.tar.gz"

            echo -n "Saving index $indexfilename to $s3target... "
            if $DRYRUN; then
                echo
                echo "$BACKUPCMD $BACKUPDIR/$indexfilename $s3target/$indexfilename"
            else
                $BACKUPCMD $BACKUPDIR/$indexfilename $s3target/$indexfilename
            fi
            echo "DONE!"
        done
    done
    echo "DONE uploading to S3!"
fi

# Cleanup tmp files.
if $DRYRUN; then
    echo "rm /tmp/mappost"
    echo "rm /tmp/mapping"
else
    rm /tmp/mappost
    rm /tmp/mapping
fi

exit 0
