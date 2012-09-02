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
#===============================================================================
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

while read line; do
  # ignore comments
  if ! [[ "${line:0:1}" = "#" ]] ; then
    db=${line}
    mysqlhotcopy -u ${mysqlusr} -p ${mysqlpwd} ${db} ${mysqlbckdir} --allowold --keepold >> ${log}
  fi
done < ${configdir}/mysqlbackuplist.conf


echo " " >> ${log}
echo "============================================" >> ${log}
echo "=== CHECK FOR CHANGES IN DATABASES  " >> ${log}
echo " " >> ${log}

# check for changes in databases

md5sum ${mysqlbckdir}/*/* | grep -v _old | sort -k2 > ${localbackupbasedir}/latest.md5
md5sum ${mysqlbckdir}/*/* | grep _old | sort -k2 | sed 's/_old//g' > ${localbackupbasedir}/old.md5
diff ${localbackupbasedir}/old.md5 ${localbackupbasedir}/latest.md5 | grep "< " | awk -F"< " '{ print $2 }' | awk '{ print $2 }' > ${localbackupbasedir}/diff.md5

difftablesnum=`wc -l ${localbackupbasedir}/diff.md5`
Y=`expr "$difftablesnum" : '\([0-9]*\)'`
difftablesnum=$Y

# end if there are no diff tables to backup
# if it's a full backup it continues

if [[ "${difftablesnum}" -eq "0" && "${bcktype}" = "inc" ]]; then

  mailfile=${localbackupbasedir}/tmp.mail
  enddate=`date "+%Y-%m-%d %H:%M:%S"`

  echo "Backup started:" ${initdate} > ${mailfile}
  echo "Backup ended:" ${enddate} >> ${mailfile}
  echo " " >> ${mailfile}
  echo "No changes since last backup!" >> ${mailfile}
  cat  ${mailfile} | mail -s "mysqlbackup.sh: ${bcktype} backup completed" ${email}
  rm ${mailfile}

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

while [ "$X" -lt "${difftablesnum}" ]
do

  let X=X+1

  TABLE=`head -n $X ${localbackupbasedir}/diff.md5 | tail -n 1`
  cp ${TABLE} ${diffbckdir}

done

# tar changed tables

if [[ "${difftablesnum}" -gt "0" ]]; then
  tar -cvf ${archivebckdir}/mysqlbackup.`date "+%Y%m%d.%H%M%S"`.tar ${diffbckdir}* >> ${log}
fi

# remove older backups

find ${archivebckdir}/mysqlbackup.*.tar -mtime +${localarchivekeep} -exec rm {} \;


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
duplicity remove-older-than ${rsyncnetlatestkeep}D --force -v4 --encrypt-key="${pubkey}" ${rsyncnetlatestbckdir} >> ${log}
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
duplicity cleanup -v4 --encrypt-key="${pubkey}" ${rsyncnetarchivedir} >> ${log}
echo " " >> ${log}
echo "---> remove older backups: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
duplicity remove-older-than ${rsyncnetarchivekeep}D --force -v4 --encrypt-key="${pubkey}" ${rsyncnetarchivedir} >> ${log}
echo " " >> ${log}
echo "---> backup: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
duplicity ${bcktype} --encrypt-key="${pubkey}" ${archivebckdir} ${rsyncnetarchivedir} >> ${log}
if [[ "${bcktype}" = "full" ]]; then 
  echo " " >> ${log}
  echo "---> verify: `date "+%Y-%m-%d %H:%M:%S"`" >> ${log}
  duplicity verify --encrypt-key="${pubkey}" ${rsyncnetarchivedir} ${archivebckdir} >> ${log}
fi


# compare existing databases with backed up databases

find ${mysqldir} -maxdepth 1 -type d | sed "s|${mysqldir}||g" | sed '/^$/d' | sort > ${localbackupbasedir}/existing.dbs
find ${mysqlbckdir} -maxdepth 1 -type d | sed "s|${mysqlbckdir}/||g" | sed "s|${mysqlbckdir}||g" | grep -v _old | sed '/^$/d' | sort > ${localbackupbasedir}/backups.dbs
diff ${localbackupbasedir}/existing.dbs ${localbackupbasedir}/backups.dbs > ${localbackupbasedir}/diff.dbs

# send mail

mailfile=${localbackupbasedir}/tmp.mail
enddate=`date "+%Y-%m-%d %H:%M:%S"`

echo "Backup started:" ${initdate} > ${mailfile} 
echo "Backup ended:" ${enddate} >> ${mailfile} 
echo " " >> ${mailfile}
ssh ${rsyncnetserver} quota >> ${mailfile} 
echo " " >> ${mailfile} 
echo "Existing databases:" >> ${mailfile} 
cat ${localbackupbasedir}/existing.dbs >> ${mailfile} 
echo " " >> ${mailfile} 
echo "Backed up databases:" >> ${mailfile}
cat ${localbackupbasedir}/backups.dbs >> ${mailfile} 
echo " " >> ${mailfile} 
echo "----> NOT backed up databases:" >> ${mailfile} 
cat ${localbackupbasedir}/diff.dbs >> ${mailfile} 
echo " " >> ${mailfile}
echo "Archived tables:" >> ${mailfile}
cat ${localbackupbasedir}/diff.md5 >> ${mailfile}
echo " " >> ${mailfile} 
cat ${log} >> ${mailfile} 
cat ${mailfile} | mail -s "mysqlbackup.sh: ${bcktype} backup completed" ${email}

rm ${mailfile}
rm ${localbackupbasedir}/existing.dbs
rm ${localbackupbasedir}/backups.dbs
rm ${localbackupbasedir}/diff.dbs 

unset PASSPHRASE

#eof
