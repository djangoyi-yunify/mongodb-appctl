# sourced by /opt/app/current/bin/ctl.sh

MONGODB_DATA_PATH=/data/mongodb-data
MONGODB_LOG_PATH=/data/mongodb-logs
MONGODB_CONF_PATH=/data/mongodb-conf

# runMongoCmd
# desc run mongo shell
# $1: script string
# $2-x: option
# -u username, -p passwd
# -P port, -H ip
runMongoCmd() {
  local cmd="/opt/mongodb/current/bin/mongo --quiet"
  local jsstr="$1"
  
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      "-u") cmd="$cmd --authenticationDatabase admin --username $2";;
      "-p") cmd="$cmd --password $2";;
      "-P") cmd="$cmd --port $2";;
      "-H") cmd="$cmd --host $2";;
    esac
    shift 2
  done

  timeout --preserve-status 5 echo "$jsstr" | $cmd
}

# createMongodCfg
# desc: create mongod.conf
# file: mongod.conf, mongod-admin.conf
# location: MONGODB_CONF_PATH=/data/mongodb-conf
createMongodConf() {
  local rsname=''
  if [ $MY_ROLE = "repl_node" ]; then
    rsname=$RS_NAME
  else
    rsname=$RS_RO_NAME
  fi
  cat > $MONGODB_CONF_PATH/mongod.conf <<MONGOD_CONF
systemLog:
  destination: file
  path: $MONGODB_LOG_PATH/mongod.log
  logAppend: true
  logRotate: reopen
net:
  port: ${CONF_NET_PORT}
  bindIp: 0.0.0.0
  maxIncomingConnections: 51200
  compression:
    compressors: snappy
security:
  keyFile: $MONGODB_CONF_PATH/repl.key
  authorization: enabled
storage:
  dbPath: $MONGODB_DATA_PATH
  journal:
    enabled: true
  engine: wiredTiger
  wiredTiger:
    engineConfig:
      cacheSizeGB: 2048
operationProfiling:
  slowOpThresholdMs: 200
replication:
  oplogSizeMB: 2048
  replSetName: $rsname
MONGOD_CONF

  cat > $MONGODB_CONF_PATH/mongod-admin.conf <<MONGOD_CONF
systemLog:
  destination: file
  path: $MONGODB_LOG_PATH/mongod.log
  logAppend: true
  logRotate: reopen
net:
  port: ${CONF_MAINTAIN_NET_PORT}
  bindIp: 0.0.0.0
storage:
  dbPath: $MONGODB_DATA_PATH
  journal:
    enabled: true
  engine: wiredTiger
replication:
  oplogSizeMB: 2048
  replSetName: $rsname
MONGOD_CONF
}

checkCfgChange() {
  :
}

NODECTL_NODE_FIRST_CREATE="/data/appctl/data/nodectl.node.first.create"
DB_QC_PASS_FILE="/data/appctl/data/qc_pass"
initCluster() {
  _initCluster

  # folder
  mkdir -p $MONGODB_DATA_PATH $MONGODB_LOG_PATH $MONGODB_CONF_PATH
  chown -R mongod:svc $MONGODB_DATA_PATH $MONGODB_LOG_PATH
  # repl.key
  echo "$GLOBAL_UUID" | base64 > "$MONGODB_CONF_PATH/repl.key"
  chown mongod:svc $MONGODB_CONF_PATH/repl.key
  chmod 0400 $MONGODB_CONF_PATH/repl.key
  # first creat flag
  touch $NODECTL_NODE_FIRST_CREATE
  #qc_pass
  local encrypted=$(echo -n ${CLUSTER_ID}${GLOBAL_UUID} | sha256sum | base64)
  echo ${encrypted:0:16} > $DB_QC_PASS_FILE
}

initNode() {
  # lxc check
  _initNode
}

NET_INFO_FILE="/data/appctl/data/netinfo"
saveNetInfo() {
  echo "$MY_IP:$CONF_NET_PORT" > $NET_INFO_FILE
}

checkNetInfoChange() {
  if [ ! -f $NET_INFO_FILE ]; then
    saveNetInfo
    return 1
  fi
  local oldstr=$(cat $NET_INFO_FILE)
  local curstr="$MY_IP:$CONF_NET_PORT"
  [ ! "$oldstr" = "$curstr" ] || return 1
}

# getSid
# desc: get sid from NODE_LIST item
# $1: a NODE_LIST item (5|192.168.1.2)
# output: sid
getSid() {
  echo $(echo $1 | cut -d'|' -f1)
}

getIp() {
  echo $(echo $1 | cut -d'|' -f2)
}

# sortHostList
# input
#  $1-n: hosts array
# output
#  sorted array, like 'v1 v2 v3 ...'
sortHostList() {
  echo $@ | tr ' ' '\n' | sort
}

# msInitRepl
# init replicaset
#  first node: priority 2
#  other node: priority 1
#  last node: priority 0, hidden true
# init readonly replicaset
#  first node: priority 2
#  other node: priority 1
msInitRepl() {
  local slist=''
  local rsname=''
  if [ $MY_ROLE = "repl_node" ]; then
    slist=($(sortHostList ${NODE_LIST[@]}))
    rsname=$RS_NAME
  else
    slist=($(sortHostList ${NODE_RO_LIST[@]}))
    rsname=$RS_RO_NAME
  fi
  
  local cnt=${#slist[@]}
  # only first node can do init action
  [ $(getSid ${slist[0]}) = $MY_SID ] || return 0
  
  local curmem=''
  local memberstr=''
  for((i=0; i<$cnt; i++)); do
    if [ $i -eq 0 ]; then
      curmem="{_id:$i,host:\"$(getIp ${slist[i]}):$CONF_NET_PORT\",priority: 2}"
    elif [ $i -eq $((cnt-1)) ]; then
      if [ $MY_ROLE = "repl_node" ]; then
        curmem="{_id:$i,host:\"$(getIp ${slist[i]}):$CONF_NET_PORT\",priority: 0, hidden: true}"
      else
        curmem="{_id:$i,host:\"$(getIp ${slist[i]}):$CONF_NET_PORT\",priority: 1}"
      fi
    else
      curmem="{_id:$i,host:\"$(getIp ${slist[i]}):$CONF_NET_PORT\",priority: 1}"
    fi
    
    if [ $i -eq 0 ]; then
      memberstr=$curmem
    else
      memberstr="$memberstr,$curmem"
    fi
  done

  local initjs=$(cat <<EOF
rs.initiate({
  _id:"$rsname",
  members:[$memberstr]
})
EOF
  )

  runMongoCmd "$initjs" -P $CONF_NET_PORT
}

msInitUsers() {
  local jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.createUser(
  {
    user: "$DB_QC_USER",
    pwd: "$(cat $DB_QC_PASS_FILE)",
    roles: [ { role: "root", db: "admin" } ]
  }
)
EOF
  )
  runMongoCmd "$jsstr" -P $CONF_NET_PORT

  jsstr=$(cat <<EOF
admin = db.getSiblingDB("admin")
admin.createUser(
  {
    user: "$DB_ROOT_USER",
    pwd: "$DB_ROOT_PWD",
    roles: [ { role: "root", db: "admin" } ]
  }
)
EOF
  )
  runMongoCmd "$jsstr" -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE)
}

checkNodeCanDoReplInit() {
  local slist=''
  if [ $MY_ROLE = "repl_node" ]; then
    slist=($(sortHostList ${NODE_LIST[@]}))
  else
    slist=($(sortHostList ${NODE_RO_LIST[@]}))
  fi
  test $(getSid ${slist[0]}) = $MY_SID
}

# msIsReplStatusOk
# check if replia set's status is ok
# 1 primary, other's secondary
msIsReplStatusOk() {
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.status())" $@ | jq .members[].stateStr)
  local pcnt=$(echo "$tmpstr" | grep PRIMARY | wc -l)
  local scnt=$(echo "$tmpstr" | grep SECONDARY | wc -l)
  local allcnt=''
  if [ $MY_ROLE = "repl_node" ]; then
    allcnt=${#NODE_LIST[@]}
  else
    allcnt=${#NODE_RO_LIST[@]}
  fi
  test $pcnt -eq 1
  test $((pcnt+scnt)) -eq $allcnt
}

msIsMeMaster() {
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.status())" $@)
  local pname=$(echo $tmpstr | jq '.members[] | select(.stateStr=="PRIMARY") | .name' | sed s/\"//g)
  test "$pname" = "$MY_IP:$CONF_NET_PORT"
}

start() {
  isNodeInitialized || initNode
  createMongodConf
  # if checkNodeFirstCreated; then
  #   createMongodConf
  #   if [ ! $ADDING_HOSTS_FLAG = "true" ]; then
  #     log "init the replica"
  #   fi
  #   rm -f $NODECTL_NODE_FIRST_CREATE
  # else
  #   if [ $CHANGE_VXNET_FLAG = "true" ]; then
  #     #checkNetInfoChange
  #     log "change net info"
  #     #saveNetInfo
  #   elif [ $VERTICAL_SCALING_FLAG = "true" ]; then
  #     log "vertical scaling"
  #   else
  #     log "normal stop-start"
  #   fi
  # fi
  _start
  if [ -f $NODECTL_NODE_FIRST_CREATE ]; then
    rm -f $NODECTL_NODE_FIRST_CREATE
    if [ $ADDING_HOSTS_FLAG = "true" ]; then log "adding node done"; return; fi
    if ! checkNodeCanDoReplInit; then log "init replica: skip this node"; return; fi
    log "init replica begin ..."
    retry 60 3 0 msInitRepl
    retry 60 3 0 msIsReplStatusOk -P $CONF_NET_PORT
    retry 60 3 0 msIsMeMaster -P $CONF_NET_PORT
    log "add db users"
    retry 60 3 0 msInitUsers
    log "init replica done"
  fi
}

stop() {
  :
}