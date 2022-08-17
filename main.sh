#!/bin/bash

echo
echo Arguments:
echo $@
echo

source lib.sh

parseArgs $@

getOpenPort

if [[ "$openPort" == "" ]];then
    echo "ERROR - cannot find open port..."
    exit 1
fi

echo "Interactive Session Port: $openPort"

if [[ "$servicePort" == "" ]];then
    servicePort="8000"
fi

echo "Generating session html"
cp service.html.template service.html.tmp

if [ ! -z "${KUBERNETES_PORT}" ];then
    USERMODE="k8s"
else
    USERMODE="docker"
fi

if [[ "$USERMODE" == "k8s" ]];then
    FORWARDPATH="pwide-kube"
    IPADDRESS="$(hostname -I | xargs)"
else
    FORWARDPATH="pwide"
    IPADDRESS="$PW_USER_HOST"
fi

sed -i "s/__FORWARDPATH__/$FORWARDPATH/" service.html.tmp
sed -i "s/__IPADDRESS__/$IPADDRESS/" service.html.tmp
sed -i "s/__OPENPORT__/$openPort/" service.html.tmp

mv service.html.tmp /pw/jobs/${job_number}/service.html

echo "Submitting job to ${controller}"
sshcmd="ssh -o StrictHostKeyChecking=no ${controller}"

# create the script that will generate the session tunnel and run the interactive session app
# NOTE - in the below example there is an ~/.ssh/config definition of "localhost" control master that already points to the user container
masterIp=$($sshcmd cat '~/.ssh/masterip')

if [[ "$USERMODE" == "k8s" ]];then
    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost \"ssh -J ${controller} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -L 0.0.0.0:$openPort:localhost:$servicePort "'$(hostname)'"\""
else
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -R 0.0.0.0:$openPort:localhost:$servicePort localhost"
fi

# Initiallize session batch file:
echo "Generating session script"
echo "#!/bin/bash" > session.sh
# SET SLURM DEFAULT VALUES:
if ! [ -z ${partition} ] && ! [[ "${walltime}" == "default" ]]; then
    echo "#SBATCH --partition=${partition}" >> session.sh
fi

if ! [ -z ${walltime} ] && ! [[ "${walltime}" == "default" ]]; then
    echo "#SBATCH --time=${walltime}" >> session.sh
    swalltime=$(echo "${walltime}" | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 + 60}')
else
    swalltime=9999
fi

if [ -z ${numnodes} ]; then
    echo "#SBATCH --nodes=1" >> session.sh
else
    echo "#SBATCH --nodes=${numnodes}" >> session.sh
fi

if [[ "${exclusive}" == "True" ]]; then
    echo "#SBATCH --exclusive" >> session.sh
fi

echo "#SBATCH --job-name=session-${job_number}" >> session.sh
echo "#SBATCH --output=session-${job_number}.out" >> session.sh
echo >> session.sh

# ADD STREAMING
if [[ "${stream}" == "True" ]]; then
    stream_args="--host localhost --pushpath /pw/jobs/${job_number}/session-${job_number}.out --pushfile session-${job_number}.out --delay 30 --port ${PARSL_CLIENT_SSH_PORT} --masterIp ${masterIp}"
    stream_cmd="bash stream-${job_number}.sh ${stream_args} &"
    echo; echo "Streaming command:"; echo "${stream_cmd}"; echo
    echo ${stream_cmd} >> session.sh
fi

cat >> session.sh <<HERE

echo
echo Starting interactive session - sessionPort: $servicePort tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

# create a port tunnel from the allocated compute node to the user container (or user node in some cases)
echo "Running blocking ssh command..."
sleep 3
# run this in a screen so the blocking tunnel cleans up properly
screen -d -m $TUNNELCMD
echo "Exit code: \$?"
# start the app
# nc -kl --no-shutdown $servicePort
echo "Starting session..."

HERE

# Add application-specific code
if [ -f "${start_app_sh}" ]; then
    cat ${start_app_sh} >> session.sh
fi

replace_templated_inputs session.sh $@

# move the session file over
chmod 777 session.sh
# REMOVE ME
#scp session.sh $sshuser@$sshhost:session-${job_number}.sh
scp session.sh ${controller}:session-${job_number}.sh
scp  stream.sh ${controller}:stream-${job_number}.sh

echo
echo "Submitting slurm request (wait for node to become available before connecting)..."
echo
echo $sshcmd sbatch session-${job_number}.sh
slurmjob=$($sshcmd sbatch session-${job_number}.sh | tail -1 | awk -F ' ' '{print $4}')

if [[ "$slurmjob" == "" ]];then
    echo "ERROR submitting job - exiting the workflow"
    exit 1
fi

# CREATE KILL FILE:
# - When the job is killed PW runs /pw/jobs/job-number/kill.sh
# Initialize kill.sh
kill_sh=/pw/jobs/${job_number}/kill.sh
echo "#!/bin/bash" > ${kill_sh}
# Add application-specific code
# WARNING: if part runs in a different directory than bash command! --> Use absolute paths!!
if [ -f "${kill_app_sh}" ]; then
    echo "$sshcmd 'bash -s' < ${kill_app_sh}.sh" >> ${kill_sh}
fi
echo $sshcmd scancel $slurmjob >> ${kill_sh}

replace_templated_inputs ${kill_sh} $@

chmod 777 ${kill_sh}

echo
echo "Submitted slurm job: $slurmjob"

sleep ${swalltime}
