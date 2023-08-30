#!/bin/bash
sdir=$(dirname $0)
# For debugging
env > session_wrapper.env

source lib.sh

# TUNNEL COMMAND:
if [ -z "$servicePort" ]; then
    SERVER_TUNNEL_CMD="ssh -J ${resource_privateIp} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -fN -R 0.0.0.0:$openPort:0.0.0.0:\$servicePort ${USER_CONTAINER_HOST}"
else
    SERVER_TUNNEL_CMD="ssh -J ${resource_privateIp} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -fN -R 0.0.0.0:$openPort:0.0.0.0:$servicePort ${USER_CONTAINER_HOST}"
fi
# Cannot have different port numbers on client and server or license checkout fails!
LICENSE_TUNNEL_CMD="ssh -J ${resource_privateIp} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -fN -L 0.0.0.0:${advanced_options_license_server_port}:localhost:${advanced_options_license_server_port} -L 0.0.0.0:${advanced_options_license_daemon_port}:localhost:${advanced_options_license_daemon_port} ${USER_CONTAINER_HOST}"

# Initiallize session batch file:
echo "Generating session script"
export session_sh=${PW_JOB_PATH}/session.sh
cp resources/host/batch_header.sh ${session_sh}

echo >> ${session_sh}
cat inputs.sh >> ${session_sh}

# ADD RUNTIME FIXES FOR EACH PLATFORM
if ! [ -z ${RUNTIME_FIXES} ]; then
    echo ${RUNTIME_FIXES} | tr ';' '\n' >> ${session_sh}
fi

# SET SESSIONS' REMOTE DIRECTORY
${sshcmd} mkdir -p ${resource_jobdir}

# ADD STREAMING
if [[ "${advanced_options_stream}" == "true" ]]; then
    # Don't really know the extension of the --pushpath. Can't controll with PBS (FIXME)
    stream_args="--host ${USER_CONTAINER_HOST} --pushpath ${PW_JOB_PATH}/logs.out --pushfile script.out --delay 30 --masterIp ${resource_privateIp}"
    stream_cmd="bash stream-${job_number}.sh ${stream_args} &"
    echo; echo "Streaming command:"; echo "${stream_cmd}"; echo
    echo ${stream_cmd} >> ${session_sh}
fi

# MAKE SURE CONTROLLER NODES HAVE SSH ACCESS TO COMPUTE NODES:
$sshcmd cp "~/.ssh/id_rsa.pub" ${resource_jobdir}

cat >> ${session_sh} <<HERE
# In case the job directory is not shared between the controller and compute nodes
mkdir -p ${resource_jobdir}
cd ${resource_jobdir}

echo "Running in host \$(hostname)"
sshusercontainer="ssh -J ${resource_privateIp} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER_CONTAINER_HOST}"

displayErrorMessage() {
    echo \$(date): \$1
    \${sshusercontainer} "sed -i \"s|.*ERROR_MESSAGE.*|    \\\\\"ERROR_MESSAGE\\\\\": \\\\\"\$1\\\\\"|\" ${PW_JOB_PATH}/service.json"
    exit 1
}

findAvailablePort() {
    # Find an available availablePort
    minPort=6000
    maxPort=9000
    for port in \$(seq \${minPort} \${maxPort} | shuf); do
        out=\$(netstat -aln | grep LISTEN | grep \${port})
        if [ -z "\${out}" ]; then
            # To prevent multiple users from using the same available port --> Write file to reserve it
            portFile=/tmp/\${port}.port.used
            if ! [ -f "\${portFile}" ]; then
                touch \${portFile}
                availablePort=\${port}
                echo \${port}
                break
            fi
        fi
    done

    if [ -z "\${availablePort}" ]; then
        displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
    fi
}

cd ${resource_jobdir}
set -x

# MAKE SURE CONTROLLER NODES HAVE SSH ACCESS TO COMPUTE NODES:
pubkey=\$(cat ~/.ssh/authorized_keys | grep \"\$(cat id_rsa.pub)\")
if [ -z "\${pubkey}" ]; then
    echo "Adding public key of controller node to compute node ~/.ssh/authorized_keys"
    cat id_rsa.pub >> ~/.ssh/authorized_keys
fi

if [ -f "${resource_workdir}/pw/.pw/remote.sh" ]; then
    # NEW VERSION OF SLURMSHV2 PROVIDER
    echo "Running ${resource_workdir}/pw/.pw/remote.sh"
    ${resource_workdir}/pw/.pw/remote.sh
elif [ -f "${resource_workdir}/pw/remote.sh" ]; then
    echo "Running ${resource_workdir}/pw/remote.sh"
    ${resource_workdir}/pw/remote.sh
fi

# Find an available servicePort. Could be anywhere in the form (<section_name>_servicePort)
servicePort=$(env | grep servicePort | cut -d'=' -f2)
if [ -z "\${servicePort}" ]; then
    servicePort=\$(findAvailablePort)
fi
echo \${servicePort} > service.port

echo
echo Starting interactive session - sessionPort: \$servicePort tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

# Create a port tunnel from the allocated compute node to the user container (or user node in some cases)
echo "${SERVER_TUNNEL_CMD} </dev/null &>/dev/null &"
${SERVER_TUNNEL_CMD} </dev/null &>/dev/null &

if ! [ -z "${advanced_options_license_env}" ]; then
    # Export license environment variable
    export ${advanced_options_license_env}=${advanced_options_license_server_port}@localhost
    # Create tunnel
    echo "${LICENSE_TUNNEL_CMD} </dev/null &>/dev/null &"
    ${LICENSE_TUNNEL_CMD} </dev/null &>/dev/null &
fi

echo "Exit code: \$?"
echo "Starting session..."
rm -f \${portFile}
HERE

# Load server environment
if ! [ -z "${service_load_env}" ]; then
    echo ${service_load_env} >> ${session_sh}
fi

# Add application-specific code
if [ -f "${service_name}/start-template.sh" ]; then
    cat ${service_name}/start-template.sh >> ${session_sh}
fi

# move the session file over
chmod 777 ${session_sh}
scp ${session_sh} ${resource_publicIp}:${resource_jobdir}/session-${job_number}.sh
scp stream.sh ${resource_publicIp}:${resource_jobdir}/stream-${job_number}.sh

echo
echo "Submitting ${submit_cmd} request (wait for node to become available before connecting)..."
echo
echo $sshcmd ${submit_cmd} ${resource_jobdir}/session-${job_number}.sh

sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Submitted\",/" service.json

# Submit job and get job id
if [[ ${jobschedulertype} == "SLURM" ]]; then
    jobid=$($sshcmd ${submit_cmd} ${resource_jobdir}/session-${job_number}.sh | tail -1 | awk -F ' ' '{print $4}')
elif [[ ${jobschedulertype} == "PBS" ]]; then
    jobid=$($sshcmd ${submit_cmd} ${resource_jobdir}/session-${job_number}.sh)
fi

if [[ "${jobid}" == "" ]];then
    displayErrorMessage "ERROR submitting job - exiting the workflow"
fi

# CREATE KILL FILE:
# - When the job is killed PW runs ${PW_JOB_PATH}/job-number/kill.sh
# KILL_SSH: Part of the kill_sh that runs on the remote host with ssh
kill_ssh=${PW_JOB_PATH}/kill_ssh.sh
echo "#!/bin/bash" > ${kill_ssh}
cat inputs.sh >> ${kill_ssh} 
if [ -f "${service_name}/kill-template.sh" ]; then
    echo "Adding kill server script ${service_name}/kill-template.sh to ${kill_ssh}"
    cat ${service_name}/kill-template.sh >> ${kill_ssh}
fi
echo ${cancel_cmd} ${jobid} >> ${kill_ssh}

# Initialize kill.sh
kill_sh=${PW_JOB_PATH}/kill.sh
echo "#!/bin/bash" > ${kill_sh}
echo "mv ${kill_sh} ${kill_sh}.completed" >> ${kill_sh}
cat inputs.sh >> ${kill_sh}
echo "echo Running ${kill_sh}" >> ${kill_sh}
echo "$sshcmd 'bash -s' < ${kill_ssh}" >> ${kill_sh}
echo "echo Finished running ${kill_sh}" >> ${kill_sh}
echo "sed -i \"s/.*JOB_STATUS.*/    \\\"JOB_STATUS\\\": \\\"Cancelled\\\",/\"" ${PW_JOB_PATH}/service.json >> ${kill_sh}
echo "exit 0" >> ${kill_sh}
chmod 777 ${kill_sh}

echo
echo "Submitted slurm job: ${jobid}"


# Job status file writen by remote script:
while true; do    
    # squeue won't give you status of jobs that are not running or waiting to run
    # qstat returns the status of all recent jobs
    job_status=$($sshcmd ${status_cmd} | grep ${jobid} | awk '{print $5}')
    echo "Job status: ${job_status}"
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"${job_status}\",/" service.json
    if [[ ${jobschedulertype} == "SLURM" ]]; then
        # If job status is empty job is no longer running
        if [ -z ${job_status} ]; then
            job_status=$($sshcmd sacct -j ${jobid}  --format=state | tail -n1)
            sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"${job_status}\",/" service.json
            break
        fi
    elif [[ ${jobschedulertype} == "PBS" ]]; then
        if [[ ${job_status} == "C" ]]; then
            break
        elif [ -z ${job_status} ]; then
            break
        fi
    fi
    sleep 5
done

