#!/bin/bash

if [ -f "${HOME}/.ssh/CONNECTED" ]; then
    echo "Tunnel already established"
    exit 0
fi 

findAvailablePort() {
    # Find an available availablePort
    minPort=2222
    maxPort=2999
    for port in $(seq ${minPort} ${maxPort} | shuf); do
        out=$(netstat -aln | grep LISTEN | grep ${port})
        if [ -z "${out}" ]; then
            # To prevent multiple users from using the same available port --> Write file to reserve it
            portFile=/tmp/${port}.port.used
            if ! [ -f "${portFile}" ]; then
                touch ${portFile}
                availablePort=${port}
                echo ${port}
                break
            fi
        fi
    done

    if [ -z "${availablePort}" ]; then
        echo "ERROR: No service port found in the range ${minPort}-${maxPort} -- exiting session"
        exit 1
    fi
}

user_container_ssh_port=$(findAvailablePort)

echo ${user_container_ssh_port} > ~/.ssh/USER_CONTAINER_SSH_PORT

cat > ~/.ssh/config <<HERE
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
Host usercontainer
    HostName localhost
    User Matthew.Shaxted
    Port ${user_container_ssh_port}
    StrictHostKeyChecking no

HERE

date > ${HOME}/.ssh/CONNECTED 

rm -f ${HOME}/.ssh/id_rsa*
ssh-keygen -t rsa -N "" -q -f  ${HOME}/.ssh/id_rsa