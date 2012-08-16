#!/bin/bash

###############################################################
# mysqlbackup.sh
#
# Parameters:
#   $1 - backup type ( full | inc )
#
# example: mysqlbackup.sh
#
###############################################################

# get config variables
runningscript=`basename "$0"`
basedir=`echo "$0" | awk -F"$runningscript" '{ print $1 }'`
configdir=$basedir/config
. $configdir/mysqlbackup.conf

INITDATE=`date "+%Y-%m-%d %H:%M:%S"`


# backup type
BCK_TYPE=$1

echo "============================================" > $LOG
echo "=== BACKING UP MYSQL DATABASES" >> $LOG
echo " " >> $LOG


# backup databases

# --- CHANGE THIS (one line for each database)
mysqlhotcopy -u ${MYSQL_USER} -p ${MYSQL_PASS} mydatabase ${MYSQL_BCK_DIR} --allowold --keepold >> $LOG


echo " " >> $LOG
echo "============================================" >> $LOG
echo "=== CHECK FOR CHANGES IN DATABASES  " >> $LOG
echo " " >> $LOG

# check for changes in databases

md5sum ${MYSQL_BCK_DIR}/*/* | grep -v _old | sort -k2 > ${BASE_DIR}/latest.md5
md5sum ${MYSQL_BCK_DIR}/*/* | grep _old | sort -k2 | sed 's/_old//g' > ${BASE_DIR}/old.md5
diff ${BASE_DIR}/old.md5 ${BASE_DIR}/latest.md5 | grep "< " | awk -F"< " '{ print $2 }' | awk '{ print $2 }' > ${BASE_DIR}/diff.md5

NUM_TABLES=`wc -l ${BASE_DIR}/diff.md5`
Y=`expr "$NUM_TABLES" : '\([0-9]*\)'`
NUM_TABLES=$Y

# end if there are no diff tables to backup

if [[ "${NUM_TABLES}" -eq "0" ]]; then

  MAIL_FILE=${BASE_DIR}/tmp.mail
  ENDDATE=`date "+%Y-%m-%d %H:%M:%S"`

  echo "Backup started:" $INITDATE > ${MAIL_FILE}
  echo "Backup ended:" $ENDDATE >> ${MAIL_FILE}
  echo " " >> ${MAIL_FILE}
  echo "No changes since last backup!" >> ${MAIL_FILE}
  cat  ${MAIL_FILE} | mail -s "mysqlbackup.sh: ${BCK_TYPE} backup completed" github.contact@paapereira.com
  rm ${MAIL_FILE}

  unset PASSPHRASE

  exit 0
fi

# copy latest tables

cd ${MYSQL_BCK_DIR}
rsync \
  --verbose --recursive --times --perms --links --archive --checksum \
  --update --delete --delete-excluded \
  --exclude="*_old" \
  * \
  ${BCK_LATEST} >> $LOG
cd -

# copy changed tables

rm -Rf ${BCK_DIFF}/*

X=0

while [ "$X" -lt "${NUM_TABLES}" ]
do

  let X=X+1

  TABLE=`head -n $X ${BASE_DIR}/diff.md5 | tail -n 1`
  cp ${TABLE} ${BCK_DIFF}

done

# tar changed tables

tar -cvf ${BCK_ARCHIVE}/mysqlbackup.`date "+%Y%m%d.%H%M%S"`.tar ${BCK_DIFF}* >> $LOG

# remove older backups

find ${BCK_ARCHIVE}/mysqlbackup.*.tar -mtime +120 -exec rm {} \;


echo " " >> $LOG
echo "============================================" >> $LOG
echo "=== RSYNC.NET: CURRENT BACKUP " >> $LOG
echo " " >> $LOG

# current rsync.net backup

echo " " >> $LOG
echo "---> cleanup: `date "+%Y-%m-%d %H:%M:%S"`" >> $LOG
duplicity cleanup -v4 --encrypt-key="${RSYNC_PUB_KEY}" ${RSYNC_DIR} >> $LOG
echo " " >> $LOG
echo "---> remove older backups: `date "+%Y-%m-%d %H:%M:%S"`" >> $LOG
duplicity remove-older-than 120D --force -v4 --encrypt-key="${RSYNC_PUB_KEY}" ${RSYNC_DIR} >> $LOG
echo " " >> $LOG
echo "---> backup: `date "+%Y-%m-%d %H:%M:%S"`" >> $LOG
duplicity ${BCK_TYPE} --encrypt-key="${RSYNC_PUB_KEY}" ${BCK_LATEST} ${RSYNC_DIR} >> $LOG
echo " " >> $LOG
echo "---> verify: `date "+%Y-%m-%d %H:%M:%S"`" >> $LOG
duplicity verify --encrypt-key="${RSYNC_PUB_KEY}" ${RSYNC_DIR} ${BCK_LATEST} >> $LOG


# archived rsync.net backups

echo " " >> $LOG
echo "============================================" >> $LOG
echo "=== RSYNC.NET: ARCHIVE " >> $LOG
echo " " >> $LOG

echo " " >> $LOG
echo "---> cleanup: `date "+%Y-%m-%d %H:%M:%S"`" >> $LOG
duplicity cleanup -v4 --encrypt-key="${RSYNC_PUB_KEY}" ${RSYNC_DIR_ARCHIVE} >> $LOG
echo " " >> $LOG
echo "---> remove older backups: `date "+%Y-%m-%d %H:%M:%S"`" >> $LOG
duplicity remove-older-than 120D --force -v4 --encrypt-key="${RSYNC_PUB_KEY}" ${RSYNC_DIR_ARCHIVE} >> $LOG
echo " " >> $LOG
echo "---> backup: `date "+%Y-%m-%d %H:%M:%S"`" >> $LOG
duplicity ${BCK_TYPE} --encrypt-key="${RSYNC_PUB_KEY}" ${BCK_ARCHIVE} ${RSYNC_DIR_ARCHIVE} >> $LOG
if [[ "${BCK_TYPE}" = "full" ]]; then 
  echo " " >> $LOG
  echo "---> verify: `date "+%Y-%m-%d %H:%M:%S"`" >> $LOG
  duplicity verify --encrypt-key="${RSYNC_PUB_KEY}" ${RSYNC_DIR_ARCHIVE} ${BCK_ARCHIVE} >> $LOG
fi


# compare existing databases with backed up databases

find /var/lib/mysql/ -maxdepth 1 -type d | sed 's|/var/lib/mysql/||g' | sed '/^$/d' | sort > ${BASE_DIR}/existing.dbs
find ${MYSQL_BCK_DIR} -maxdepth 1 -type d | sed 's|/backup/hotcopy/||g'| sed 's|/backup/hotcopy||g' | grep -v _old | sed '/^$/d' | sort > ${BASE_DIR}/backups.dbs
diff ${BASE_DIR}/existing.dbs ${BASE_DIR}/backups.dbs > ${BASE_DIR}/diff.dbs

# send mail

MAIL_FILE=${BASE_DIR}/tmp.mail
ENDDATE=`date "+%Y-%m-%d %H:%M:%S"`

echo "Backup started:" $INITDATE > ${MAIL_FILE} 
echo "Backup ended:" $ENDDATE >> ${MAIL_FILE} 
echo " " >> ${MAIL_FILE} 
ssh 00000@server.rsync.net quota >> ${MAIL_FILE} 
echo " " >> ${MAIL_FILE} 
echo "Existing databases:" >> ${MAIL_FILE} 
cat ${BASE_DIR}/existing.dbs >> ${MAIL_FILE} 
echo " " >> ${MAIL_FILE} 
echo "Backed up databases:" >> ${MAIL_FILE}
cat ${BASE_DIR}/backups.dbs >> ${MAIL_FILE} 
echo " " >> ${MAIL_FILE} 
echo "----> NOT backed up databases:" >> ${MAIL_FILE} 
cat ${BASE_DIR}/diff.dbs >> ${MAIL_FILE} 
echo " " >> ${MAIL_FILE}
echo "Archived tables:" >> ${MAIL_FILE}
cat ${BASE_DIR}/diff.md5 >> ${MAIL_FILE}
echo " " >> ${MAIL_FILE} 
cat $LOG >> ${MAIL_FILE} 
cat  ${MAIL_FILE} | mail -s "mysqlbackup.sh: ${BCK_TYPE} backup completed" github.contact@paapereira.com

rm ${MAIL_FILE}
rm ${BASE_DIR}/existing.dbs
rm ${BASE_DIR}/backups.dbs
rm ${BASE_DIR}/diff.dbs 

unset PASSPHRASE

#eof
