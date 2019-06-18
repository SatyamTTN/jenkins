#!/bin/bash
sg=$(aws rds describe-db-instances \
	--db-instance-identifier $db_instance_identifier \
    --query 'DBInstances[*].VpcSecurityGroups[0].VpcSecurityGroupId' \
    --output text)

timestamp=`date +%F`
#creating snapshot
aws rds create-db-snapshot \
	--db-snapshot-identifier snap-$timestamp \
    --db-instance-identifier $db_instance_identifier

snapshot_status=$(aws rds describe-db-snapshots \
	--db-snapshot-identifier snap-$timestamp \
    --query DBSnapshots[*].Status \
    --output text)

while [ "$snapshot_status" != "available" ]
do
	snapshot_status=$(aws rds describe-db-snapshots \
    	--db-snapshot-identifier snap-$timestamp \
        --query DBSnapshots[*].Status \
        --output text)
	continue
done

#creating db instance from snapshot
aws rds restore-db-instance-from-db-snapshot \
    --db-instance-identifier $db_instance_identifier-$timestamp \
    --db-snapshot-identifier snap-$timestamp \
    && aws rds wait db-instance-available \
     	--db-instance-identifier $db_instance_identifier-$timestamp

dbinstance_status=$(aws rds describe-db-instances \
	--db-instance-identifier $db_instance_identifier-$timestamp \
    --query DBInstances[*].DBInstanceStatus \
    --output text)
while [ "$dbinstance_status" != "available" ]
do
	dbinstance_status=$(aws rds describe-db-instances \
    	--db-instance-identifier $db_instance_identifier-$timestamp \
        --query DBInstances[*].DBInstanceStatus \
        --output text)
    continue
done

#modifying security group
aws rds modify-db-instance \
	--db-instance-identifier $db_instance_identifier-$timestamp \
    --vpc-security-group-ids $sg

#fetching endpoint of rds
endpoint=$(aws rds describe-db-instances \
	--db-instance-identifier $db_instance_identifier-$timestamp \
    --query DBInstances[*].Endpoint.Address \
    --output text)

#taking dump of db
mysqldump -u satyam --databases $database \
	--single-transaction -h $endpoint \
    --port=3306 -p$db_password | gzip > backupdb_$database_$timestamp.sql.gz

#Uploading backup on s3
aws s3 cp "$WORKSPACE/backupdb_$database_$timestamp.sql.gz" s3://testdb-backup

#Giving public read permission to s3 object
#aws s3api put-object-acl \
	#--bucket testdb-backup \
    #--key backupdb_$timestamp.sql.gz \
    #--acl public-read

#deleting dbInstance
aws rds delete-db-instance \
	--db-instance-identifier $db_instance_identifier-$timestamp \
    --skip-final-snapshot

#deleting snapshot
aws rds delete-db-snapshot \
    --db-snapshot-identifier snap-$timestamp

#creating temporary object download link
aws s3 presign s3://testdb-backup/backupdb_$database_$timestamp.sql.gz
