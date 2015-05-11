#!/bin/bash

############################
# COMMON FUNCTIONS AND SETTINGS
# Get incoming arguments
REQUIREDARGS=1
NUMOFARGS=$#
ENVNAME=$1
if echo $2 | grep "skiprpm" > /dev/null;then
    echo "`date` -- Skipping RPM for this run"
    SKIPRPM="true"
fi
if echo $3 | grep "skipami" > /dev/null;then
    NEWAMI="ami-19102029"
    SKIPAMI="true"
fi
GITPAYLOAD=${payload}
RANDOM_STRING="$RANDOM-$RANDOM"

# Get AWS creds injected
. /home/centos/.aws-config

# Bring in functions in lib
. /home/centos/socorro-infra/bin/lib/identify_role.sh
. /home/centos/socorro-infra/bin/lib/create_rpm.sh
. /home/centos/socorro-infra/bin/lib/create_ami.sh

# Show usage instructions for noobs
function show_usage() {
        echo " =================== ";echo " ";
        echo " Syntax "
        echo " ./deploy-socorro.sh $env (stage or prod)"
        echo " "
        echo " Example: ./deploy-socorro.sh stage"
        exit 0
}

# Check if you are asking for halp or passing the wrong number of args
function check_syntax() {
    if [ "$1" = "-h" ] || [ "$1" = "--help" ];then
        show_usage
    fi
    if [ ${NUMOFARGS} -lt ${REQUIREDARGS} ];then
        echo "`date` -- ERROR, ${REQUIREDARGS} arguments required and ${NUMOFARGS} is an invalid number of args"
        exit 1
    fi
}

function error_check() {
    if [ ${RETURNCODE} -ne 0 ];then
        echo "`date` -- Error encountered during ${PROGSTEP} : ${RETURNCODE}"
        if [ "${NOTFATAL}" = "true" ];then
            echo "Not fatal, continuing"
            NOTFATAL="false"
        else
            echo "Fatal, exiting"
            echo "===================="
            echo "Instances which may need to be terminated manually: ${INITIALINSTANCES}"
            exit 1
        fi
    fi
}

####################################
## PROGRAM FUNCTIONS
function format_logs() {
    echo " ";echo " ";echo " ";echo "=================================================";echo " ";echo " ";echo " "
}

function parse_github_payload() {
    PROGSTEP="Parse github webhook payload"
    # We will get all sorts of fun info here!
    echo "Git Payload Long: ${GITPAYLOAD}"|sed 's/,/\'$'\n/g';format_logs
    GITCOMMITHASH=`echo ${GITPAYLOAD} | sed 's/,/\'$'\n/g'| grep head_commit | sed 's/"/ /g' | awk '{print $5}'`
    echo "Git commit hash:  ${GITCOMMITHASH}"
    GITREF=`echo ${GITPAYLOADLONG} | sed 's/,/\'$'\n/g'| grep refs | head -n1 | sed 's/"/ /g' | awk '{print $4}'`
    echo "Git Ref:  ${GITREF}"
    if echo ${GITREF} | grep tag > /dev/null;then
        GITTAG=`echo ${GITPAYLOAD}|sed 's/,/\'$'\n/g' | grep refs | head -n1 | sed 's/"/ /g' | awk '{print $4}' | sed 's/\// /g' | awk '{print $3}'`
    else
        GITTAG="false"
    fi
    echo "Git Tag: ${GITTAG}"
    GITCOMMITTER=`echo ${GITPAYLOAD} | sed 's/,/\'$'\n/g'| grep committer | sed 's/"/ /g'|awk '{print $5" "$6}'`
    echo "Committer: ${GITCOMMITTER}"
}

function scale_in_per_elb() {
    PROGSTEP="Scale in";echo "`date` -- Checking current desired capacity of autoscaling group for ${ROLEENVNAME}"
    # We'll set the initial capacity and go back to that at the end
    INITIALCAPACITY=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${AUTOSCALENAME}|grep DesiredCapacity | sed 's/,//g'|awk '{print $2}'`
        RETURNCODE=$?;error_check
    echo "`date` -- ${AUTOSCALENAME} initial capacity is set to ${INITIALCAPACITY}"
    # How many new nodes will we need to scale in for this deploy?
    DEPLOYCAPACITY=`echo $(($INITIALCAPACITY*2))`
        RETURNCODE=$?;error_check
    echo "`date` -- ${AUTOSCALENAME} capacity for this deploy is set to ${DEPLOYCAPACITY}"
    # Get a list of existing instance ids to terminate later
    INITIALINSTANCES="${INITIALINSTANCES} `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name ${AUTOSCALENAME} | grep InstanceId|sed 's/"/ /g'|awk '{print $3}'` "
        RETURNCODE=$?;error_check
    echo "`date` -- Current instance list: ${INITIALINSTANCES}"
    # Tell the AWS api to give us more instances in that role env.
    aws autoscaling set-desired-capacity --auto-scaling-group-name ${AUTOSCALENAME} --desired-capacity ${DEPLOYCAPACITY}
         RETURNCODE=$?;error_check
    echo "`date` -- Desired capacity set with a return code of ${RETURNCODE}"
}

function check_health_per_elb() {
    PROGSTEP="Checking ELB status for ${ELBNAME}"
    # We'll want to ensure the number of healthy hosts is equal to total number of hosts
    ASCAPACITY=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${AUTOSCALENAME}| grep DesiredCapacity | sed 's/,//g'|awk '{print $2}'`
        RETURNCODE=$?;error_check
    HEALTHYHOSTCOUNT=`aws elb describe-instance-health --load-balancer-name ${ELBNAME} | grep InService | wc -l | awk '{print $1}'`
        RETURNCODE=$?;error_check
    CURRENTHEALTH="${CURRENTHEALTH} `aws elb describe-instance-health --load-balancer-name ${ELBNAME} | grep State | sed 's/"/ /g'|awk '{print $3}'` "
        RETURNCODE=$?;error_check
    if [ ${HEALTHYHOSTCOUNT} -lt ${ASCAPACITY} ];then
        CURRENTHEALTH="Out"
    fi
    echo "`date` -- ${AUTOSCALENAME} nodes healthy in ELB: ${HEALTHYHOSTCOUNT} / ${ASCAPACITY}"
}

function scale_in_all() {
    PROGSTEP="Scaling in all the nodes"
    # Each socorro env has its own master list in ./lib.    We iterate over that list
    # to scale up and identify nodes to kill later
    for ROLEENVNAME in $(cat /home/centos/socorro-infra/bin/lib/${ENVNAME}_socorro_master.list)
        do
        identify_role ROLEENVNAME
        scale_in_per_elb
    done
}

function monitor_overall_health() {
    PROGSTEP="Waiting for all ELBs to report healthy and full"
    # If any elb is still unhealthy, we don't want to kill nodes
    ATTEMPTCOUNT=0;NOHEALTHALERT=""
    until [ "${HEALTHSTATUS}" = "ALLHEALTHY" ]
        do
        ATTEMPTCOUNT=`echo $(($ATTEMPTCOUNT+1))`
        echo "`date` -- Attempt ${ATTEMPTCOUNT} of 10 checking on healthy elbs"
        for ROLEENVNAME in $(cat /home/centos/socorro-infra/bin/lib/${ENVNAME}_socorro_master.list)
            do
            # Get the AS name and ELB name for this particular role/env
            identify_role ROLEENVNAME
            if [ "${ELBNAME}" = "NONE" ];then
                echo "No elb to check for ${ROLEENVNAME}" > /dev/null
            else
                check_health_per_elb
            fi
            done
        # Check for OutOfService in the saved string of statuses.    If it exists, reset and wait.
        if echo ${CURRENTHEALTH} | grep Out > /dev/null;then
            CURRENTHEALTH=""
            sleep 60 # We want to be polite to the API
            if [ $ATTEMPTCOUNT -eq 10 ]; then
                echo "`date` -- ALERT!  We've tried for over 10 minutes to wait for healthy nodes, continuing"
                NOHEALTHALERT="true"
                HEALTHSTATUS="ALLHEALTHY"
            fi
        else
            echo "`date` -- ELBs are now healthy"
            HEALTHSTATUS="ALLHEALTHY"
        fi
    done
    if [ "${HEALTHSTATUS}" = "ALLHEALTHY" ] && [ "${NOHEALTHALERT}" = "" ];then
        echo "`date` -- We are bonafide healthy"
    fi
}

function instance_deregister() {
    # We check to see if each instance in a given ELB is one of the doomed nodes
    if echo ${INITIALINSTANCES} | grep $1 > /dev/null;then
        aws elb deregister-instances-from-load-balancer --load-balancer-name $2 --instances $1
        RETURNCODE=$?;NOTFATAL="true";error_check
        echo "`date` -- Attempt to deregister $1 from $2 returned a code of ${RETURNCODE}"
    fi
}

function elb_query_to_drain_instances() {
    # We'll list every ELB involved, and for each, list every instance.    Then, for each instance
    # we check if it is on the doomed list.    If so, we deregister it to allow a 30s drain
    PROGSTEP="Draining load balancer traffic by deregistering doomed instances"
    echo "`date` -- ${PROGSTEP}"
    for ROLEENVNAME in $(cat /home/centos/socorro-infra/bin/lib/${ENVNAME}_socorro_master.list)
        do
         # Get ELB and AS group name.
         identify_role ${ROLEENVNAME}
         if [ "${ELBNAME}" = "NONE" ];then
             echo "No ELB to check for ${ROLEENVNAME}"
             else
             # For every instance in $ELBNAME, check if it's slated to be killed.
             for INSTANCETOCHECK in $(aws elb describe-instance-health --load-balancer-name ${ELBNAME}|grep InstanceId|sed 's/"/ /g'|awk '{print $3}')
                do
                instance_deregister ${INSTANCETOCHECK} ${ELBNAME}
            done
        fi
    done
    echo "`date` -- All instances in ELBs deregistered, waiting for the 30 second drain period"
}

function terminate_instances() {
    # We iterate over the list of instances to terminate (${INITIALINSTANCES}) and send each one here to
    # be terminated and simultaneously drop the desired-capacity down by 1.
    aws autoscaling terminate-instance-in-auto-scaling-group --instance-id $1 --should-decrement-desired-capacity
        RETURNCODE=$?
    echo "`date` -- $1 termination return code of ${RETURNCODE}"
}

function find_prod_ami() {
    PROGSTEP="Find correct prod AMI"
    echo "`date` -- Attempting to locate AMI tagged with appsha of ${GITCOMMITHASH}"
    NEWAMI=`aws ec2 describe-images --filters Name=tag:appsha,Values=${GITCOMMITHASH}|grep ImageId | sed 's/"/ /g' | awk '{print $3}'`
        RETURNCODE=$?;error_check
    echo "`date` -- AMI id ${NEWAMI} found containing github hash tag of ${GITCOMMITHASH} : Return code ${RETURNCODE}"
}

function apply_ami() {
    # For each of our apps, we want to use terraform to apply the new base AMI we've just created
    for ROLEENVNAME in $(cat /home/centos/socorro-infra/bin/lib/${ENVNAME}_socorro_master.list)
        do
            # Get AS group name for each ROLEENVNAME
            echo "`date` -- Checking role for ${ROLEENVNAME}"
            identify_role ${ROLEENVNAME}
            cd /home/centos/socorro-infra/terraform
            echo "`date` -- Attempting to terraform plan and apply ${AUTOSCALENAME} with new AMI id ${NEWAMI} and tagging with ${SOCORROHASH}"
            /home/centos/socorro-infra/terraform/wrapper.sh "plan -var base_ami.us-west-2=${NEWAMI}" ${ENVNAME} ${TERRAFORMNAME}
            echo " ";echo " ";echo "==================================";echo " "
            #Not used yet TERRAFORMCAPACITY=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${AUTOSCALENAME}| grep -A3 ${AUTOSCALENAME} | grep -C 3 ARN|grep DesiredCapacity | sed 's/,//g'|awk '{print $2}'`
            /home/centos/socorro-infra/terraform/wrapper.sh "apply -var base_ami.us-west-2=${NEWAMI}" ${ENVNAME} ${TERRAFORMNAME}
                RETURNCODE=$?;error_check
            echo "`date` -- Got return code ${RETURNCODE} applying terraform update"
        done
    echo "`date` -- All AMI's updated"
}

function terminate_instances_all() {
    PROGSTEP="Terminating instances"
    echo "`date` -- Shooting servers in the face"
    # With the list we built earlier of old instances, iterate over it and terminate/decrement
    for doomedinstances in $(echo ${INITIALINSTANCES} )
        do
        terminate_instances $doomedinstances
    done
}

function query_end_scale() {
    format_logs
    echo "END STATE FOR AUTO SCALING GROUPS"
    for ROLEENVNAME in $(cat /home/centos/socorro-infra/bin/lib/${ENVNAME}_socorro_master.list);do
        identify_role ${ROLEENVNAME}
        FINALCAPACITY=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${AUTOSCALENAME}| grep -A3 ${AUTOSCALENAME} | grep -C 3 ARN|grep DesiredCapacity | sed 's/,//g'|awk '{print $2}'`
        echo "${AUTOSCALENAME} : ${FINALCAPACITY}"
    done
}
####################################
## PROGRAM RUN
check_syntax    # Scan for noobs
parse_github_payload  # We check the incoming payload for some info
if [ "${ENVNAME}" = stage ];then
    time create_rpm; format_logs    # Git clone, build, package with fpm, sign, and upload rpm to S3 public repo
    time create_ami; format_logs    # Use packer to create an AMI to use as base
fi
if [ "${ENVNAME}" = prod ];then
    time find_prod_ami; format_logs
fi
time apply_ami; format_logs    # For each ROLEENV group, set the baseAMI to the AMI we created
time scale_in_all; format_logs    # For each ROLEENV group, double the size and get a list of old instances to kill later
sleep 60 # Give API time to update the instances counts it returns
time monitor_overall_health; format_logs # After updates go out, monitor for all instances in all elbs to be healthy.
if [ "${NOHEALTHALERT}" = "true" ];then
    # This means earlier, the health check process tried 10 times, and never got an all healthy response
    echo "`date` -- Not going to scale out, since we aren't all healthy"
else
    time elb_query_to_drain_instances; format_logs    # For anything with an elb, dereg instances to allow for connection drain
    sleep 30    # Wait for drain, default we set is to 30s
    time terminate_instances_all; format_logs    # Kill the instances we listed in ${INITIALINSTANCES}
fi
# All done, get our report.
echo "`date` -- Deployment complete"
echo "Nodes we think should have been killed:"
echo ${INITIALINSTANCES}
format_logs
query_end_scale; format_logs # What did our groups end at?
echo "New Socorro RPM Version: ${NEWSOCORROVERSION}"
echo "New AMI Name: ${SOCORROAMINAME}"
echo "New AMI ID: ${NEWAMI}"
echo "New AMI Hash Tag: ${GITCOMMITHASH}"
if [ "$GITTAG" = "false" ];then
    echo "No tag"
else
    echo "New git tag: ${GITTAG}"
fi
echo "Push triggered by: ${GITCOMMITTER}"
exit 0    # You snazzy, snazzy engineer.    You did it!