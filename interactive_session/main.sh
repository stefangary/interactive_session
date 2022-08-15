#!/bin/bash

echo
echo Arguments:
echo $@
echo

source lib

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

echo "Generating session file..."
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

mv service.html.tmp service.html

processPoolProperties

if [[ "$poolProperties" == "" ]];then
    echo "ERROR - cannot get pool properties..."
    exit 1
fi

echo "Getting submit host IP address (will wait until acquired)..."
getResourceInfo

if [[ "$submitHostIp" == "" ]];then
    echo "ERROR - cannot get resource master ip..."
    exit 1
fi

echo "Submitting job to $submitHostIp"

sshuser=$(echo "$poolProperties" | python -c 'import sys,json;print(json.load(sys.stdin)["pwuser"])')
sshhost=$(echo $submitHostIp)

sshcmd="ssh -o StrictHostKeyChecking=no $sshuser@$sshhost"

# create the script that will generate the session tunnel and run the interactive session app
# NOTE - in the below example there is an ~/.ssh/config definition of "localhost" control master that already points to the user container
masterIp=$($sshcmd cat '~/.ssh/masterip')

if [[ "$USERMODE" == "k8s" ]];then
    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost \"ssh -J $submitHostIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -L 0.0.0.0:$openPort:localhost:$servicePort "'$(hostname)'"\""
else
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -R 0.0.0.0:$openPort:localhost:$servicePort localhost"
fi

cat > session.sh <<HERE
#!/bin/bash

echo
echo Starting interactive session - sessionPort: $servicePort tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

# create a port tunnel from the allocated compute node to the user container (or user node in some cases)
echo "Running blocking ssh command..."
# run this in a screen so the blocking tunnel cleans up properly
screen -d -m $TUNNELCMD

# start the app
# nc -kl --no-shutdown $servicePort
echo "Starting session..."

HERE

# Add application-specific code
app_session_sh=../app_session.sh
if [ -f "${app_session_sh}" ]; then
    cat ${app_session_sh} >> session.sh
    replace_templated_inputs ${app_session_sh} $@
fi

# move the session file over
chmod 777 session.sh
scp session.sh $sshuser@$sshhost:session.sh

if [[ "$numnodes" == "" ]];then
    numnodes="1"
fi

if [[ "$walltime" == "default" ]];then
    walltime=""
fi
if [[ "$walltime" != "" ]];then
    walltime="-t $walltime"
fi

echo
echo "Submitting slurm request (wait for node to become available before connecting)..."
echo

if [[ "$partition" == "" ]] || [[ "$partition" == "default" ]];then
    echo $sshcmd sbatch -N $numnodes $walltime --wrap './session.sh'
    slurmjob=$($sshcmd sbatch -N $numnodes $walltime --wrap './session.sh' | tail -1 | awk -F ' ' '{print $4}')
else
    echo $sshcmd sbatch -p $partition -N $numnodes $walltime --wrap './session.sh'
    slurmjob=$($sshcmd sbatch -p $partition -N $numnodes $walltime --wrap './session.sh' | tail -1 | awk -F ' ' '{print $4}')
fi

if [[ "$slurmjob" == "" ]];then
    echo "ERROR submitting job - exiting the workflow"
    exit 1
fi

# CREATE KILL FILE:
# Add application-specific code
app_kill_sh=../app_kill.sh
if [ -f "${app_kill_sh}" ]; then
    cat ${app_kill_sh} > kill.sh
    replace_templated_inputs ${app_kill_sh} $@
fi

cat >> kill.sh <<HERE
#!/bin/bash
$sshcmd scancel $slurmjob
HERE

chmod 777 kill.sh

echo
echo "Submitted slurm job: $slurmjob"

sleep 9999
