#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 [options...]"
    echo "Options:"
    echo "  -u <JENKINS_URL>         Jenkins base URL"
    echo "  -n <JENKINS_JOB_NAME>    Jenkins job name"
    echo "  -U <JENKINS_USER>        Jenkins user (Optional)"
    echo "  -T <JENKINS_API_TOKEN>   Jenkins API token (Optional)"
    echo "  -P <STRING_PARAMETERS>   String parameters for the Jenkins job (Optional)"
    echo "  -F <OUTPUT_FILE>   	     Name of the output file"
    echo "Environment variables can also be used to provide these values."
    exit 1
}

# Parse command line arguments
while getopts "u:n:U:T:P:F:" opt; do
  case $opt in
    u) JENKINS_URL=$OPTARG ;;
    n) JENKINS_JOB_NAME=$OPTARG ;;
    U) JENKINS_USER=$OPTARG ;;
    T) JENKINS_API_TOKEN=$OPTARG ;;
    P) STRING_PARAMETERS=$OPTARG ;;
    F) OUTPUT_FILE=$OPTARG ;;
    *) usage ;;
  esac
done

# Output file path
output_file="$OUTPUT_FILE"

# Check if the output file exists
if [ ! -f "$output_file" ]; then
    # If it doesn't exist, create it
    touch "$output_file"
else
    # If it exists, remove the file
    rm "$output_file"
fi

# Check mandatory parameters
if [ -z "$JENKINS_URL" ] || [ -z "$JENKINS_JOB_NAME" ]; then
    echo "Error: JENKINS_URL and JENKINS_JOB_NAME are required."
    usage
fi

# Main logic
if [ -n "$STRING_PARAMETERS" ]; then
    echo "Parameters provided."
    PARAM_STRING="$STRING_PARAMETERS"
    REQUEST_URL="$JENKINS_URL/job/$JENKINS_JOB_NAME/buildWithParameters?$PARAM_STRING"
    echo "JENKINS REQUEST URL : $REQUEST_URL"
else
    echo "No parameters provided."
    PARAM_STRING=""
    REQUEST_URL="$JENKINS_URL/job/$JENKINS_JOB_NAME/build"
    echo "JENKINS REQUEST URL : $REQUEST_URL"
fi
echo "REQUEST_URL=$REQUEST_URL" >> $GITHUB_ENV

# Function to get Jenkins Crumb
get_jenkins_crumb() {
    crumb=$(curl -k -s -u "$JENKINS_USER:$JENKINS_API_TOKEN" -X GET "$JENKINS_URL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
    echo "$crumb"
}

fetch_build_number_using_queueid() {
    local JENKINS_URL="$1"
    local queue_id="$2"
    local timeout=900  # Timeout in seconds (15 minutes)
    #echo "$queue_id"
    
    # Poll for BUILD_NUMBER every 5 seconds until it's obtained or timeout is reached
    while true; do
        response=$(curl -k -s -u "$JENKINS_USER:$JENKINS_API_TOKEN" "$JENKINS_URL/queue/item/$queue_id/api/json?pretty=true")
        sleep 5
        #echo "The curl response 01: $response"
        BUILD_NUMBER=$(echo "$response" | grep -o '"number" : [0-9]*' | awk '{print $3}')
        
        if [ -n "$BUILD_NUMBER" ]; then
            break
        fi
        
        # Check if the timeout is reached
        if [ $SECONDS -ge $timeout ]; then
            echo "Failed to retrieve the Build Number. Jenkins may have encountered an issue."
            exit 1
        fi
    done
}

trigger_jenkins_job_with_apitoken() {
	local REQUEST_URL="$1"
	local JENKINS_USER="$2"
	local JENKINS_API_TOKEN="$3"
	local response=$(curl -k -s -X POST -D - "$REQUEST_URL" \
						--user "$JENKINS_USER:$JENKINS_API_TOKEN" \
						--data-urlencode delay=0sec \
						-o /dev/null \
						-D - \
						-i)
	#echo "The curl response 02 : $response"
	QUEUE_ID=$(echo "$response" | grep -i "Location" | awk -F '/' '{print $(NF-1)}')
	if [ -z "$QUEUE_ID" ]; then
		echo "Failed to retrieve the Queue ID. Jenkins may have encountered an issue."
		exit 1
	else
		fetch_build_number_using_queueid "$JENKINS_URL" "$QUEUE_ID"
	fi
	
	
}

trigger_jenkins_job_with_jenkinsCrumb() {
	local REQUEST_URL="$1"
	local CRUMB=$(get_jenkins_crumb)
	local AUTH_HEADER="-H \"Jenkins-Crumb:$CRUMB\""

	local response=$(curl -k -X $AUTH_HEADER POST -D - "$REQUEST_URL")
	echo "The curl response : $response"
	QUEUE_ID=$(echo "$response" | grep -i "Location" | awk -F '/' '{print $(NF-1)}')
	echo "$QUEUE_ID"
	if [ -z "$QUEUE_ID" ]; then
		echo "Failed to retrieve the Queue ID. Jenkins may have encountered an issue."
		exit 1
	else
	    response=$(curl -k -X $AUTH_HEADER "$JENKINS_URL/queue/item/$QUEUE_ID/api/json?pretty=true")
	    echo $response
	    BUILD_NUMBER=$(echo "$response" | grep -o '"number" : [0-9]*' | awk '{print $3}')
	    if [ -z "$BUILD_NUMBER" ]; then
		echo "Failed to retrieve the Build Number. Jenkins may have encountered an issue."
		exit 1
	    fi
		
	fi
}

# Function to trigger jenkins job
trigger_jenkins_job() {
    local REQUEST_URL="$1"
    local JENKINS_USER="$2"
    local JENKINS_API_TOKEN="$3"

    if [ -n "$JENKINS_API_TOKEN" ]; then
	trigger_jenkins_job_with_apitoken "$REQUEST_URL" "$JENKINS_USER" "$JENKINS_API_TOKEN"
    else
	trigger_jenkins_job_with_jenkinsCrumb "$REQUEST_URL"
    fi
}

sleep 5


# Function to check if job is completed
check_job_status() {
    local JENKINS_URL="$1"
    local JENKINS_JOB_NAME="$2"
    local BUILD_NUMBER="$3"
    local job_status
    while true; do
        job_status=$(curl -k -s -u "$JENKINS_USER:$JENKINS_API_TOKEN" "$JENKINS_URL/job/$JENKINS_JOB_NAME/$BUILD_NUMBER/api/json" | grep -o '"result" *: *"[^"]*"' | awk -F'"' '{print $4}')
        if [ "$job_status" == "SUCCESS" ] || [ "$job_status" == "FAILURE" ] || [ "$job_status" == "ABORTED" ] || [ "$job_status" == "UNSTABLE" ]; then
            #echo "Job status for job $JENKINS_JOB_NAME (Build Number: $BUILD_NUMBER) at $JENKINS_URL: $job_status"
	    
	    echo $job_status
            break
        fi
        sleep 5
    done
}

fetch_console_output() {
    local JENKINS_URL="$1"
    local JENKINS_JOB_NAME="$2"
    local BUILD_NUMBER="$3"
    sleep 3
    curl -k -s -u "$JENKINS_USER:$JENKINS_API_TOKEN" "$JENKINS_URL/job/$JENKINS_JOB_NAME/$BUILD_NUMBER/consoleText"

}

extract_job_info() {
    local line="$1"
    local jobname="${line#*Triggering a new build of }"
    local jobid="${jobname#*#}"
    jobname="${jobname%%#*}"
    echo "$jobname $jobid"
}

extract_build_value() {
    local console_output="$1"
    echo "$console_output" | grep -oE "docker push -q iregistry.eur.ad.sag/kub-sic/[^ ]+" | grep -v "latest" | awk -F "/" '{print $NF}'
    
}

extract_test_value() {
    local console_output="$1"
    echo "$console_output" | grep "Tests run:" | grep -v "Time elapsed" | grep -oE "Tests run:.*"
}

fetchjobsdetails() {

    local JENKINS_URL="$1"
    local JENKINS_JOB_NAME="$2"
    local BUILD_NUMBER="$3"
    local flag=0

    JOB_STATUS=$(check_job_status "$JENKINS_URL" "$JENKINS_JOB_NAME" "$BUILD_NUMBER")

	if [ "$JOB_STATUS" == "SUCCESS" ] || [ "$JOB_STATUS" == "UNSTABLE" ]; then
		echo "The job '$JENKINS_JOB_NAME' has finished with the result: $JOB_STATUS. Fetching the console output for build #$BUILD_NUMBER."

	else
		echo "The job '$JENKINS_JOB_NAME' has finished with status '$JOB_STATUS'. Exiting the execution."
		echo "For more details, please refer to the console log URL: $JENKINS_URL/job/$JENKINS_JOB_NAME/$BUILD_NUMBER/console"
		exit 1
	fi

    local success_console_output=$(fetch_console_output "$JENKINS_URL" "$JENKINS_JOB_NAME" "$BUILD_NUMBER")
    #echo "$success_console_output" >> "$output_file"
    matched_strings=()

	while IFS= read -r line; do

	    if [[ $line == *"Triggering a new build"* ]]; then
		matched_strings+=("$line")
		flag=1
	    fi
	    
	done <<< "$success_console_output"

    if [ "$flag" -eq 0 ]; then
        echo "The triggering of a new build pattern was not found in the job '$JENKINS_JOB_NAME' with build number $BUILD_NUMBER."
        build_value=$(extract_build_value "$success_console_output")
	test_result=$(extract_test_value "$success_console_output")
	if [ -n "$build_value" ]; then
		echo "BUILD_NUMBER_$JENKINS_JOB_NAME=$build_value" >> "$output_file"
		echo "CONSOLE_OUTPUT_$JENKINS_JOB_NAME=$JENKINS_URL/job/$JENKINS_JOB_NAME/$BUILD_NUMBER/console" >> "$output_file"
	elif [ -n "$test_result" ]; then
		echo "TEST_RESULT_$JENKINS_JOB_NAME=$test_result" >> "$output_file"
		echo "CONSOLE_OUTPUT_$JENKINS_JOB_NAME=$JENKINS_URL/job/$JENKINS_JOB_NAME/$BUILD_NUMBER/console" >> "$output_file"
	else
		echo "No changes in the job!"
		echo "CONSOLE_OUTPUT_$JENKINS_JOB_NAME=$JENKINS_URL/job/$JENKINS_JOB_NAME/$BUILD_NUMBER/console" >> "$output_file"
	fi	
    else
        echo "The Triggering a new build pattern found in the job $JENKINS_JOB_NAME with build $BUILD_NUMBER"
    fi

    for string in "${matched_strings[@]}"; do

	local job_info=$(extract_job_info "$string")
        local jobname="${job_info%% *}"
        local jobid="${job_info##* }"
        fetchjobsdetails "$JENKINS_URL" "$jobname" "$jobid" 
    done

}

# Call the function and capture its output
trigger_jenkins_job "$REQUEST_URL" "$JENKINS_USER" "$JENKINS_API_TOKEN"
sleep 5
# Print the build number
echo "The request has been queued. It contains an ID: $QUEUE_ID."
echo "The Jenkins build with ID $BUILD_NUMBER has been generated."

# Fetch the JOB's details
fetchjobsdetails "$JENKINS_URL" "$JENKINS_JOB_NAME" "$BUILD_NUMBER"

echo "-------------- Below is the captured result from the file $output_file ------------------"
cat $output_file
