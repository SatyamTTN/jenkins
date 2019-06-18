#!/bin/bash
now=$(date +"%H")
REGION="ap-south-1"

mail() {
    echo "Inside sns function"
    aws sns publish \
        --topic-arn "arn:aws:sns:ap-south-1:184998102068:sih-infra" \
        --message "$message" \
        --subject "Jenkins cron job srf-nonprod-on-demand failed"
    exit 1
}
start() {

    echo "Staring RDS Instance and waiting for it to be available"
    aws rds start-db-instance \
        --db-instance-identifier srf-non-prod-mysql-5-7-instance \
       --region ${REGION} \
    && aws rds wait db-instance-available \
        --db-instance-identifier srf-non-prod-mysql-5-7-instance \
        --region ${REGION}
    if [ $? -eq 0 ]
    then
        echo "RDS Instance started successfully"
    else
        echo "Error while starting RDS instance"
        message="Error while starting RDS instance srf-non-prod-mysql-5-7-instance"
        mail $message
        exit 1
    fi
    
    echo "Launching an ECS Instance through ASG"
    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name srf-non-prod-app \
        --region ${REGION} \
        --min-size 1 \
        --desired-capacity 1

    echo "Waiting for 60 seconds for ECS instance to be available"
    sleep 60
    
    instanceid=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names srf-non-prod-app \
        --region ${REGION} \
        --query AutoScalingGroups[*].Instances[0].InstanceId \
        --output text)
    
    aws ec2 wait instance-running --instance-ids $instanceid --region ${REGION}
    if [ $? -eq 0 ]
    then
        echo "ECS Instance started successfully"
    else
        echo "Error while starting ECS instance"
        message="Error while starting instance for ECS cluster srf-non-prod"
        mail $message
        exit 1
    fi
    
    echo "Waiting for instance to be placed in ecs cluster"
    registeredinstance=$(aws ecs describe-clusters \
        --cluster srf-non-prod \
        --region ${REGION} \
        --query clusters[*].registeredContainerInstancesCount \
        --output text)
    while [ $registeredinstance == 0 ]
    do
        sleep 30
        registeredinstance=$(aws ecs describe-clusters \
        --cluster srf-non-prod \
        --region ${REGION} \
        --query clusters[*].registeredContainerInstancesCount \
        --output text)
        continue
    done
    
    echo "Running tasks and waiting for ecs service to be stable"
    aws ecs update-service \
        --cluster srf-non-prod \
        --service srf-non-prod-java-app \
        --desired-count 1 \
        --region ${REGION} \
    && aws ecs wait services-stable \
        --service srf-non-prod-java-app  \
        --cluster srf-non-prod \
        --region ${REGION}
    if [ $? -eq 0 ]
    then
        echo "Tasks are up and running"
    else
        echo "Error in deployment"
        message="ECS Service srf-non-prod-java-app is not stable"
        mail $message
        exit 1
    fi
    
    echo "Checking if Application is working or not"
    tgarn=$(aws ecs describe-services \
        --cluster srf-non-prod \
        --service srf-non-prod-java-app \
        --region ${REGION} \
        --query services[*].loadBalancers[0].targetGroupArn \
        --output text)
    tgstate=$(aws elbv2 describe-target-health \
        --target-group-arn $tgarn \
        --region ${REGION} \
        --query TargetHealthDescriptions[*].TargetHealth.State \
        --output text)
    while [[ $tgstate != "healthy" && $tgstate != "unhealthy" ]]
    do
        sleep 20
        tgstate=$(aws elbv2 describe-target-health \
            --target-group-arn $tgarn \
            --region ${REGION} \
            --query TargetHealthDescriptions[*].TargetHealth.State \
            --output text)
        continue
    done
    if [ $tgstate == "healthy" ]
    then
        echo "Application is healthy"
    elif [ $tgstate == "unhealthy" ]
    then
        echo "Application is unhealthy"
        message="srn-non-prod-java-app is unhealthy"
        mail $message
    fi
}
stop() {

    echo "Terminating tasks"
    aws ecs update-service \
        --cluster srf-non-prod \
        --service srf-non-prod-java-app \
        --desired-count 0 \
        --region ${REGION}
    
    runningtasks=$(aws ecs describe-services \
        --service srf-non-prod-java-app \
        --cluster srf-non-prod \
        --region ${REGION} \
        --query services[*].runningCount \
        --output text)
    echo "Waiting for tasks to be terminiated"
    while [ $runningtasks -ne 0 ]
    do
        sleep 30
        runningtasks=$(aws ecs describe-services \
            --service srf-non-prod-java-app \
            --cluster srf-non-prod \
            --region ${REGION} \
            --query services[*].runningCount \
            --output text)
        continue
    done
    echo "There are no more running tasks"

    echo "Terminating ECS Instances"
    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name srf-non-prod-app \
        --min-size 0 \
        --desired-capacity 0 \
        --region ${REGION}

    instanceid=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names srf-non-prod-app \
        --region ${REGION} \
        --query AutoScalingGroups[*].Instances[0].InstanceId \
        --output text)
    
    echo "Waiting for 60 seconds for EC2 instance to be terminated"
    sleep 60

    aws ec2 wait instance-terminated --instance-ids $instanceid --region ${REGION}
    if [ $? -eq 0 ]
    then
        echo "ECS Instance stopped successfully"
    else
        echo "Error while stopping ECS instance"
        message="Error while stopping instance of auto scaling group srn-non-prod-app"
        mail $message
        exit 1
    fi

    echo "Stopping RDS Instance"
    aws rds stop-db-instance \
        --db-instance-identifier srf-non-prod-mysql-5-7-instance \
       --region ${REGION}
    
    dbstatus=$(aws rds describe-db-instances \
        --db-instance-identifier srf-non-prod-mysql-5-7-instance \
        --region ${REGION} \
        --query DBInstances[*].DBInstanceStatus \
        --output text)
        
    echo "Waiting for RDS Instance to stop"
    while [ $dbstatus != "stopped" ]
    do
        sleep 60
        dbstatus=$(aws rds describe-db-instances \
            --db-instance-identifier srf-non-prod-mysql-5-7-instance \
            --region ${REGION} \
            --query DBInstances[*].DBInstanceStatus \
            --output text)
        continue
    done
    echo "RDS Instance Stopped"

}

if [ $action == "stop" ]
then
    stop
    exit 0
elif [ $action == "start" ]
then
    start
    exit 0
fi

if [ $now -eq 14 ] 
then
    stop
elif [ $now -eq 02 ] 
then
    start
fi

