#!/bin/bash

# Check if directory exists
if [ -d /tmp/mydir ]; then
    cd /tmp/mydir
fi

# Unquoted variables
FILE_LIST=`ls -l`
echo $FILE_LIST

# Mixed quotes
echo "Today's date is `date`"

# Missing quotes around variables
TARGET_DIR=/tmp/backup
if [ -d $TARGET_DIR ]
then
    rm -rf $TARGET_DIR/*
fi

# Problematic command substitution and word splitting
FILES=`ls *.txt`
for file in $FILES; do
    cp $file $TARGET_DIR
done

# Unquoted array access
MY_ARRAY=(one two three)
echo $MY_ARRAY[1]

# Path concatenation without quotes
FOLDER="my folder"
DATA_FILE="data.txt"
cat $FOLDER/$DATA_FILE

# Problematic test conditions
if [ "$VAR" == "value" ]; then
    echo "matched"
fi

# Unchecked command substitution
USER_HOME=`cat /etc/passwd | grep $USER | cut -d: -f6`

# Poor error handling
rm -rf ${TARGET}

# Uninitialized variable
echo $UNDEFINED_VAR

# Command that will fail in some locales
echo "Processing..." > file
sz=`wc -c < file`

# Missing error checking
mkdir /tmp/newdir
cd /tmp/newdir

# Redirect that might fail
cat file.txt >& output.log

