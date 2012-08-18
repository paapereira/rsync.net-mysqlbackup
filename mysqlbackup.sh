#!/bin/bash

#===============================================================================
#
#    Author: Paulo Pereira <mysqlbackup@lofspot.net>
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program in the file LICENSE.  If not, see 
#    <http://www.gnu.org/licenses/>.
#
# =================
#
#    DESCRIPTION:
#       This script is intended to backup mysql databases using rsync.net 
#       offsite backup infrastructure
#
#    PARAMETERS:
#       $1 - backup type ( full | inc )
#
#    EXAMPLE:
#       mysqlbackup.sh inc
#
#===============================================================================

# config files
runningscript=`basename "$0"`
basedir=`echo "$0" | awk -F"${runningscript}" '{ print $1 }'`
configdir=${basedir}/config
. ${configdir}/mysqlbackup.conf
. ${configdir}/mysql.conf
. ${configdir}/rsync.net.conf

# backup type
bcktype=$1

# initial date
initdate=`date "+%Y-%m-%d %H:%M:%S"`


echo "============================================" > ${log}
echo "=== BACKING UP MYSQL DATABASES" >> ${log}
echo " " >> ${log}


# backup databases

# --- CHANGE THIS (one line for each database)
mysqlhotcopy -u ${mysqlusr} -p ${mysqlpwd} mydatabase ${mysqlbckdir} --allowold --keepold >> ${log}


echo " " >> ${log}
echo "============================================" >> ${log}
echo "=== CHECK FOR CHANGES IN DATABASES  " >> ${log}
echo " " >> ${log}

# check for changes in databases

md5sum ${mysqlbckdir}/*/* | grep -v _old | sort -k2 > ${BASE_DIR}/latest.md5
md5sum ${mysqlbckdir}/*/* | grep _old | sort -k2 | sed 's/_old//g' > ${BASE_DIR}/old.md5
diff ${BASE_DIR}/old.md5 ${BASE_DIR}/latest.md5 | grep "< " | awk -F"< " '{ print $2 }' | awk '{ print $2 }' > ${BASE_DIR}/diff.md5

NUM_TABLES=`wc -l ${BASE_DIR}/diff.md5`
Y=`expr "$NUM_TABLES" : '\([0-9]*\)'`
NUM_TABLES=$Y

# end if there are no diff tables to backup

if [[ "${NUM_TABLES}" -eq "0" ]]; then

  MAIL_FILE=${BASE_DIR}/tmp.mail
  ENDDATE=`date "+%Y-%m-%d %H:%M:%S"`

  echo "Backup started:" $initdate > ${MAIL_FILE}
  echo "Backup ended:" $ENDDATE >> ${MAIL_FILE}
  echo " " >> ${MAIL_FILE}
  echo "No changes since last backup!" >> ${MAIL_FILE}
  cat  ${MAIL_FILE} | mail -s "mysqlbackup.sh: ${bcktype} backup completed" mysqlbackup@lofspot.net
  rm ${MAIL_FILE}

  unset PASSPHRASE

  exit 0
fi

# copy latest tables

cd ${mysqlbckdir}
rsync \
  --verbose --recursive --times --perms --links --archive --checksum \
  --update --delete --delete-excluded \
  --exclude="*_old" \
  * \
  ${latestbckdir} >> ${log}
cd -

# copy changed tables

rm -Rf ${diffbckdir}/*

X=0

while [ "$X" -lt "${NUM_TABLES}" ]
do

  let X=X+1

  TABLE=`head -n $X ${BASE_DIR}/diff.md5 | tail -n 1`
  cp ${TABLE} ${diffbckdir}

done

# tar changed tables

tar -cvf ${archivebckdir}/mysqlbackup.`date "+%Y%m%d.%H%M%S"`.tar ${diffbckdir}* >> ${log}

# remove older backups

find ${archivebckdir}/mysqlbackup.*.tar -mtime +120 -exec rm {} \;


echo " " >> ${log}
echo "============================================" >> ${log}
echo "=== RSYNC.NET: CURRENT BACKUP " >> ${log}
echo " " >> ${log}

# current rsync.net backup

echo " " >> ${log}
echo "---> cleanup: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
duplicity cleanup -v4 --encrypt-key="${pubkey}" ${rsyncnetlatestbckdir} >> ${log}
echo " " >> ${log}
echo "---> remove older backups: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
duplicity remove-older-than 120D --force -v4 --encrypt-key="${pubkey}" ${rsyncnetlatestbckdir} >> ${log}
echo " " >> ${log}
echo "---> backup: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
duplicity ${bcktype} --encrypt-key="${pubkey}" ${latestbckdir} ${rsyncnetlatestbckdir} >> ${log}
echo " " >> ${log}
echo "---> verify: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
duplicity verify --encrypt-key="${pubkey}" ${rsyncnetlatestbckdir} ${latestbckdir} >> ${log}


# archived rsync.net backups

echo " " >> ${log}
echo "============================================" >> ${log}
echo "=== RSYNC.NET: ARCHIVE " >> ${log}
echo " " >> ${log}

echo " " >> ${log}
echo "---> cleanup: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
duplicity cleanup -v4 --encrypt-key="${pubkey}" ${rsyncnetlatestbckdir_ARCHIVE} >> ${log}
echo " " >> ${log}
echo "---> remove older backups: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
duplicity remove-older-than 120D --force -v4 --encrypt-key="${pubkey}" ${rsyncnetlatestbckdir_ARCHIVE} >> ${log}
echo " " >> ${log}
echo "---> backup: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
duplicity ${bcktype} --encrypt-key="${pubkey}" ${archivebckdir} ${rsyncnetlatestbckdir_ARCHIVE} >> ${log}
if [[ "${bcktype}" = "full" ]]; then 
  echo " " >> ${log}
  echo "---> verify: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
  duplicity verify --encrypt-key="${pubkey}" ${rsyncnetlatestbckdir_ARCHIVE} ${archivebckdir} >> ${log}
fi


# compare existing databases with backed up databases

find /var/lib/mysql/ -maxdepth 1 -type d | sed 's|/var/lib/mysql/||g' | sed '/^$/d' | sort > ${BASE_DIR}/existing.dbs
find ${mysqlbckdir} -maxdepth 1 -type d | sed 's|/backup/hotcopy/||g'| sed 's|/backup/hotcopy||g' | grep -v _old | sed '/^$/d' | sort > ${BASE_DIR}/backups.dbs
diff ${BASE_DIR}/existing.dbs ${BASE_DIR}/backups.dbs > ${BASE_DIR}/diff.dbs

# send mail

MAIL_FILE=${BASE_DIR}/tmp.mail
ENDDATE=`date "+%Y-%m-%d %H:%M:%S"`

echo "Backup started:" $initdate > ${MAIL_FILE} 
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
cat ${log} >> ${MAIL_FILE} 
cat  ${MAIL_FILE} | mail -s "mysqlbackup.sh: ${bcktype} backup completed" mysqlbackup@lofspot.net

rm ${MAIL_FILE}
rm ${BASE_DIR}/existing.dbs
rm ${BASE_DIR}/backups.dbs
rm ${BASE_DIR}/diff.dbs 

unset PASSPHRASE

#eof
