#!/bin/bash -e

set -e

export DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# the name of the stack we used with the cloud-formation template
export STACKNAME=${STACKNAME:="pxdemo"}

# a function that lists the az and id of the nodes in our mesos cluster
function describe-nodes() {
  aws ec2 describe-instances \
    --filters \
      "Name=tag:role,Values=mesos-slave" \
      "Name=instance-state-name,Values=running" \
      "Name=tag:aws:cloudformation:stack-name,Values=${STACKNAME}" \
    --query "Reservations[*].Instances[*].{ID:InstanceId,AZ:Placement.AvailabilityZone,Public:PublicIpAddress,Private:PrivateIpAddress,Role:Tags[?Key=='role'].Value | [0],Type:Tags[?Key=='aws:cloudformation:logical-id'].Value | [0]}" \
    --output text
}

function wait-for-volume() {
  local id="${1}"
  echo "checking status for volume: ${id}"
  local status=$(aws ec2 describe-volume-status --volume-ids "${id}" --query 'VolumeStatuses[0].VolumeStatus.Status')
  echo "${status}"
  if [ "${status}" != '"ok"' ]; then
    sleep 1
    wait-for-volume "${id}"
  fi
  echo "preparing to attach volume"
  sleep 5
}

# given the az and id of a node - create a 10GB EBS volume and attach it to the node
function create-volume() {
  # a function to create and attach an EBS volume to a node using aws cli
  local az=$(echo $1 | awk '{print $1}')
  local id=$(echo $1 | awk '{print $2}')

  echo "creating volume for node: ${id} in az: ${az}"
  local volumeid=$(aws ec2 create-volume --size 10 --availability-zone "${az}" --volume-type gp2 --output text --query 'VolumeId')
  wait-for-volume "${volumeid}"
  echo "attaching volume ${volumeid} to node ${id} at /dev/sdf"
  aws ec2 attach-volume --volume-id ${volumeid} --instance-id ${id} --device /dev/sdf
}

# a function that loops over each of the nodes from describeNodes and calls createVolume for it
function create-volumes() {
  (IFS='
'
for x in `describe-nodes`; do 
  create-volume "$x"
done)
}

function etcd-endpoint() {
  local hostname=$(dcos task | grep etcd-server | tail -n 1 | awk '{print $6}')
  local port=$(dcos task | grep etcd-server | tail -n 1 | awk '{print $8}')
  echo "etcd://${hostname}:${port}"
}

function public-slave-ip() {
  describe-nodes | grep PublicSlaveServerGroup | awk '{print $4}'
}

function haproxy-endpoint() {
  local publicslave=$(public-slave-ip)
  
  echo "http://${publicslave}:9090/haproxy?stats"
}

function app-endpoint() {
  local publicslave=$(public-slave-ip)
  local port="10000"
  if [ "${1}" == "test" ]; then
    port="10001"
  fi
  
  echo "http://${publicslave}:${port}"
}

function run-ssh() {
  local nodeid=""
  if [ -z "${1}" ]; then
    nodeid=`dcos node | grep '\-S0' | awk '{print $3}'`
  else
    nodeid="${1}"; shift;
  fi
  eval "dcos node ssh --option StrictHostKeyChecking=no --master-proxy --mesos-id=$nodeid '$@'"
}

function run-command() {
  for nodeid in `dcos node | tail -n +2 | awk '{print $3}'`; do
    run-ssh $nodeid "$@";
  done
}

function setup-docker() {
  for nodeid in `dcos node | tail -n +2 | awk '{print $3}'`; do
    echo "Setup docker on node $nodeid"
    run-ssh $nodeid "sudo cp /usr/lib64/systemd/system/docker.service /etc/systemd/system"
    run-ssh $nodeid "sudo sed -i '/MountFlags/d' /etc/systemd/system/docker.service"
    run-ssh $nodeid "sudo systemctl daemon-reload"
    run-ssh $nodeid "sudo systemctl restart docker"
  done
}

function ssh-px-node() {
  local pxip=$(describe-nodes | grep None | tail -n 1 | awk '{print $3}')
  local nodeid=$(dcos node | grep "${pxip}" | awk '{print $3}')
  run-ssh ${nodeid} $@
}

function ssh-app-node() {
  local appnode=$(dcos task | grep px-counter | awk '{print $2}')
  local nodeid=$(dcos node | grep "${appnode}" | awk '{print $3}')
  run-ssh ${nodeid} $@
}

function kill-app-container() {
  local containerid=$(ssh-app-node 'docker ps' | grep px-counter | awk '{print $1}')
  ssh-app-node "docker rm -f $containerid"
}

function px-config() {
  export ETCD_ENDPOINT=$(etcd-endpoint)
  perl -p -e 's/\$\{([^}]+)\}/defined $ENV{$1} ? $ENV{$1} : $&/eg; s/\$\{([^}]+)\}//eg' ${DIR}/px-options.example.json
}

function usage() {
cat <<EOF
Usage:
  describe-nodes        list the ip / az of mesos-slaves
  wait-for-volume       wait until a volume is created
  create-volume         create a new volume in an az and attach it to a node
  create-volumes        create/attach a new volume for each mesos slave
  public-slave-ip       get the public ip address of the public mesos slave
  haproxy-endpoint      get the url of the haproxy stats page
  app-endpoint          get the url of the app page
  etcd-endpoint         get the hostname:port of an etcd server
  run-ssh               run a command on a single mesos slave
  run-command           run a command on each mesos slave
  setup-docker          configure docker to use shared mount namespaces
  ssh-app-node          ssh onto the node running the app
  ssh-px-node           ssh onto the a node running portworx
  kill-app-container    kill the app container on a node running it
  px-config             print the JSON for the px-config.json file
  help                  display this message
EOF
  exit 1
}

function main() {
  case "$1" in
  describe-nodes)      shift; describe-nodes $@;;
  wait-for-volume)     shift; wait-for-volume $@;;
  create-volume)       shift; create-volume $@;;
  create-volumes)      shift; create-volumes $@;;
  etcd-endpoint)       shift; etcd-endpoint $@;;
  run-ssh)             shift; run-ssh $@;;
  run-command)         shift; run-command $@;;
  setup-docker)        shift; setup-docker $@;;
  public-slave-ip)     shift; public-slave-ip $@;;
  haproxy-endpoint)    shift; haproxy-endpoint $@;;
  app-endpoint)        shift; app-endpoint $@;;
  ssh-app-node)        shift; ssh-app-node $@;;
  ssh-px-node)         shift; ssh-px-node $@;;
  kill-app-container)  shift; kill-app-container $@;;
  px-config)           shift; px-config $@;;
  *)                   usage $@;;
  esac
}

main "$@"