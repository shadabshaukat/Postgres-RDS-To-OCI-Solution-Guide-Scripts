#!/usr/bin/env bash

###########################################################################
### Author : Shadab Mohammad, Master Principal Cloud Architect @ Oracle  ###
#   Check_AWS_RDS_DB_Instances_Details                                   #
### Centre of Excellence, JAPAC                                          ###
### v1.1  |  20-Feb-26                                                   ###
### Purpose:                                                             ###
#   Inventory every Amazon RDS or Aurora instances across all  #
#   AWS regions, highlight storage headroom & Multi-AZ posture, and      #
#   export both a curated CSV plus the full describe-db-instances JSON.  #
### Prerequisites:                                                       ###
#   - Host with AWS CLI v2, bash, jq, outbound internet access.          #
#   - AWS CLI profile with permissions:                                  #
#        * ec2:DescribeRegions                                           #
#        * rds:DescribeDBInstances                                       #
#   - (Optional) AWS_DEFAULT_REGION / AWS_PROFILE environment variables. #
### Usage:                                                              ###
#   chmod +x rds_db_instances_details.sh                                 #
#   ./rds_db_instances_details.sh                                        #
#   AWS_PROFILE=prod ./rds_db_instances_details.sh                       #
###########################################################################

set -euo pipefail

command -v aws >/dev/null 2>&1 || {
    echo "aws CLI is required but not installed. Please install aws CLI v2." >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || {
    echo "jq is required but not installed. Please install jq and retry." >&2
    exit 1
}

now=$(date)

output_file="rds_db_instances_details.csv"
raw_json_file="rds_db_instances_details_full.json"
echo "[" > "$raw_json_file"
is_first_json_record=true

echo "Engine,DBIdentifier,EngineVersion,MultiAZ,AllocatedStorage,MaxAllocatedStorage,DBInstanceClass,DBInstanceStatus,BackupRetentionPeriod,InstanceCreateTime,Endpoint,PreferredBackupWindow,PreferredMaintenanceWindow,IAMDatabaseAuthenticationEnabled,StorageType,StorageEncrypted,StorageLeftPct,AttentionStorage,AttentionMultiAZ" > "$output_file"

echo ".................................................................."
echo "Check AWS RDS DB Instances Details"
echo "Date: $now"
echo ".................................................................."

tot_val=0
nStorageAllocationWatermarkPctg=25

regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text)

for region in $regions; do
    printf "Region: %15s\n" "$region"
    db_counter_in_reg_val=0

    db_instances=$(aws rds describe-db-instances --region "$region" --query 'DBInstances[].DBInstanceIdentifier' --output text 2>/dev/null || true)

    if [ -z "$db_instances" ]; then
        continue
    fi

    for db_ident in $db_instances; do
        details_json=$(aws rds describe-db-instances --region "$region" --db-instance-identifier "$db_ident" --query 'DBInstances[0]' --output json 2>/dev/null || true)

        if [ -z "$details_json" ] || [ "$details_json" = "null" ]; then
            echo "Skipping $db_ident in $region (no describe-db-instances output)." >&2
            continue
        fi

        instance_json=$(echo "$details_json" | jq -c '.')

        if [ "$is_first_json_record" = true ]; then
            echo "  $instance_json" >> "$raw_json_file"
            is_first_json_record=false
        else
            echo "  ,$instance_json" >> "$raw_json_file"
        fi

        strEngine=$(echo "$instance_json" | jq -r '.Engine // "N/A"')
        strDBIdent=$(echo "$instance_json" | jq -r '.DBInstanceIdentifier // ""')
        strEngineVersion=$(echo "$instance_json" | jq -r '.EngineVersion // "N/A"')
        strMultiAZ=$(echo "$instance_json" | jq -r '.MultiAZ // false')
        strAllocatedStorage=$(echo "$instance_json" | jq -r '.AllocatedStorage // 0')
        strMaxAllocatedStorage=$(echo "$instance_json" | jq -r '.MaxAllocatedStorage // "None"')
        strDBInstanceClass=$(echo "$instance_json" | jq -r '.DBInstanceClass // "N/A"')
        strDBInstanceStatus=$(echo "$instance_json" | jq -r '.DBInstanceStatus // "N/A"')
        strBackupRetentionPeriod=$(echo "$instance_json" | jq -r '.BackupRetentionPeriod // 0')
        strInstanceCreateTime=$(echo "$instance_json" | jq -r '.InstanceCreateTime // ""')
        strEndpoint=$(echo "$instance_json" | jq -r '.Endpoint.Address // ""')
        strBackupWindow=$(echo "$instance_json" | jq -r '.PreferredBackupWindow // ""')
        strMaintenanceWindow=$(echo "$instance_json" | jq -r '.PreferredMaintenanceWindow // ""')
        strIAMAuthEnabled=$(echo "$instance_json" | jq -r '.IAMDatabaseAuthenticationEnabled // false')
        strStorageType=$(echo "$instance_json" | jq -r '.StorageType // ""')
        strStorageEncrypted=$(echo "$instance_json" | jq -r '.StorageEncrypted // false')

        strAttention1="Ok"
        strAttention2="Ok"
        storage_left_pct="N/A"

        if [[ "$strMaxAllocatedStorage" = "None" || "$strMaxAllocatedStorage" = "null" ]]; then
            strAttention1="Bad"
        else
            storage_left=$((strMaxAllocatedStorage - strAllocatedStorage))
            if [ "$strMaxAllocatedStorage" -gt 0 ]; then
                storage_left_pct=$((100 * storage_left / strMaxAllocatedStorage))
            else
                storage_left_pct=0
            fi
            if [ "$storage_left_pct" -lt "$nStorageAllocationWatermarkPctg" ]; then
                strAttention1="Bad"
            fi
        fi

        if [ "$strMultiAZ" = "False" ] || [ "$strMultiAZ" = "false" ]; then
            strAttention2="Bad"
        fi

        printf "#%-3s | eng: %-12s | ver: %-10s | ident: %-50s | class: %-18s | mAZ: %-5s %-3s | status: %-12s | allocStorage: %-8s (left %-3s pct) | maxAllocStorage: %-8s %-3s | backup: %-3d | createTime: %-20s | endpoint: %-40s | backupWin: %-12s | maintWin: %-12s | IAMAuth: %-3s | storageType: %-12s | storageEncrypted: %-3s\n" \
            $((db_counter_in_reg_val + 1)) "$strEngine" "$strEngineVersion" "$strDBIdent" "$strDBInstanceClass" "$strMultiAZ" "$strAttention2" "$strDBInstanceStatus" "$strAllocatedStorage" "$storage_left_pct" "$strMaxAllocatedStorage" "$strAttention1" "$strBackupRetentionPeriod" "$strInstanceCreateTime" "$strEndpoint" "$strBackupWindow" "$strMaintenanceWindow" "$strIAMAuthEnabled" "$strStorageType" "$strStorageEncrypted"

        echo "$strEngine,$strDBIdent,$strEngineVersion,$strMultiAZ,$strAllocatedStorage,$strMaxAllocatedStorage,$strDBInstanceClass,$strDBInstanceStatus,$strBackupRetentionPeriod,$strInstanceCreateTime,$strEndpoint,$strBackupWindow,$strMaintenanceWindow,$strIAMAuthEnabled,$strStorageType,$strStorageEncrypted,$storage_left_pct,$strAttention1,$strAttention2" >> "$output_file"

        db_counter_in_reg_val=$((db_counter_in_reg_val + 1))
        tot_val=$((tot_val + 1))
    done
done

echo ".................................................................."
printf "TOTAL:                                                  %10s\n" "$tot_val"
echo ".................................................................."

echo "Details have been written to: $output_file"
echo "]" >> "$raw_json_file"
echo "Full describe-db-instances payload written to: $raw_json_file"
