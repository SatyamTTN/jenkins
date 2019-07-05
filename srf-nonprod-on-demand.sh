#!/bin/bash
now=$(date +"%H")
start() {

	echo "Staring RDS Instance and waiting for it to be available"
	aws rds start-db-instance \
		--db-instance-identifier ${your-db-instance-identifier} \
    && aws rds wait db-instance-available \
     	--db-instance-identifier ${your-db-instance-identifier}
    if [ $? -eq 0 ]
	then
 		echo "RDS Instance started successfully"
	else
 		echo "Error while starting RDS instance"
 		exit 1
	fi
    
    echo "Launching an ECS Instance through ASG"
	aws autoscaling update-auto-scaling-group \
		--auto-scaling-group-name ${cluster-name}-app \
    	--min-size 1 \
    	--desired-capacity 1

    echo "Waiting for 120 seconds for ECS instance to be available"
    sleep 120
    
    instanceid=$(aws autoscaling describe-auto-scaling-groups \
    	--auto-scaling-group-names ${cluster-name}-app \
        --query AutoScalingGroups[*].Instances[0].InstanceId \
        --output text)
    
    aws ec2 wait instance-running --instance-ids $instanceid
    if [ $? -eq 0 ]
	then
 		echo "ECS Instance started successfully"
	else
 		echo "Error while starting ECS instance"
 		exit 1
	fi
	
    echo "Waiting for instance to be placed in ecs cluster"
    registeredinstance=$(aws ecs describe-clusters \
    	--cluster ${cluster-name} \
        --query clusters[*].registeredContainerInstancesCount \
        --output text)
    while [ $registeredinstance == 0 ]
    do
    	sleep 30
    	registeredinstance=$(aws ecs describe-clusters \
    	--cluster ${cluster-name} \
        --query clusters[*].registeredContainerInstancesCount \
        --output text)
        continue
    done
    
	echo "Running tasks and waiting for ecs service to be stable"
	aws ecs update-service \
		--cluster ${cluster-name} \
    	--service ${cluster-name}-app \
    	--desired-count 1 \
    && aws ecs wait services-stable \
    	--service ${cluster-name}-app  \
        --cluster ${cluster-name}
	if [ $? -eq 0 ]
	then
 		echo "Tasks are up and running"
	else
 		echo "Error in deployment"
 		exit 1
	fi

    echo "Checking if Application is working or not"
    tgarn=$(aws ecs describe-services \
        --cluster ${cluster-name} \
        --service ${cluster-name}-app \
        --query services[*].loadBalancers[0].targetGroupArn \
        --output text)
    tgstate=$(aws elbv2 describe-target-health \
        --target-group-arn $tgarn \
        --query TargetHealthDescriptions[*].TargetHealth.State \
        --output text)

    if [ $tgstate == "healthy" ]
    then
        echo "Application is healthy"
    else
        echo "Application is unhealthy"
}
stop() {

    echo "Terminating tasks"
    aws ecs update-service \
        --cluster ${cluster-name} \
        --service ${cluster-name}-app \
        --desired-count 0 \
    
    runningtasks=$(aws ecs describe-services \
        --service ${cluster-name}-app \
        --cluster ${cluster-name} \
        --query services[*].runningCount \
        --output text)
    echo "Waiting for tasks to be terminiated"
    while [ $runningtasks -ne 0 ]
    do
        sleep 30
        runningtasks=$(aws ecs describe-services \
            --service ${cluster-name}-app \
            --cluster ${cluster-name} \
            --query services[*].runningCount \
            --output text)
        continue
    done
    echo "There are no more running tasks"

	echo "Terminating ECS Instances"
	aws autoscaling update-auto-scaling-group \
		--auto-scaling-group-name ${cluster-name}-app \
    	--min-size 0 \
    	--desired-capacity 0

    instanceid=$(aws autoscaling describe-auto-scaling-groups \
    	--auto-scaling-group-names ${cluster-name}-app \
        --query AutoScalingGroups[*].Instances[0].InstanceId \
        --output text)
    
    echo "Waiting for 120 seconds for EC2 instance to be terminated"
    sleep 120

    aws ec2 wait instance-terminated --instance-ids $instanceid
    if [ $? -eq 0 ]
	then
 		echo "ECS Instance stopped successfully"
	else
 		echo "Error while stopping ECS instance"
 		exit 1
	fi

    echo "Stopping RDS Instance"
	aws rds stop-db-instance \
		--db-instance-identifier ${your-db-instance-identifier}
	
    dbstatus=$(aws rds describe-db-instances \
    	--db-instance-identifier ${your-db-instance-identifier} \
        --query DBInstances[*].DBInstanceStatus \
        --output text)
        
    echo "Waiting for RDS Instance to stop"
    while [ $dbstatus != "stopped" ]
    do
    	sleep 30
        dbstatus=$(aws rds describe-db-instances \
    		--db-instance-identifier ${your-db-instance-identifier} \
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

if [ $now -eq 20 ] 
then
	stop
elif [ $now -eq 08 ] 
then
	start
fi
