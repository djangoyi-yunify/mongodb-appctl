# sourced by /opt/app/current/bin/ctl.sh

MONGODB_DATA_PATH=/data/mongodb-data
MONGODB_LOG_PATH=/data/mongodb-logs
MONGODB_CONF_PATH=/data/mongodb-conf

# error code
ERR_GET_PRIMARY_IP=130

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

  timeout --preserve-status 5 $cmd --eval "$jsstr"
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
processManagement:
   fork: true
MONGOD_CONF
}

checkCfgChange() {
  log "action"
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
  systemd-detect-virt -cq && test -d /data
  _initNode
}

NET_INFO_FILE="/data/appctl/data/netinfo"
saveNetInfo() {
  local slist=''
  local rsname=''
  if [ $MY_ROLE = "repl_node" ]; then
    slist=(${NODE_LIST[@]})
  else
    slist=(${NODE_RO_LIST[@]})
  fi
  local cnt=${#slist[@]}
  : > $NET_INFO_FILE
  for((i=0; i<$cnt; i++)); do
    echo $(getIp ${slist[i]}):$CONF_NET_PORT $(getNodeId ${slist[i]}) >> $NET_INFO_FILE
  done
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

getNodeId() {
  echo $(echo $1 | cut -d'|' -f3)
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
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.status().members)" $@)
  local pname=$(echo $tmpstr | jq '.[] | select(.stateStr=="PRIMARY") | .name' | sed s/\"//g)
  test "$pname" = "$MY_IP:$CONF_NET_PORT"
}

msIsMeHidden() {
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.conf().members)" -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE))
  local pname=$(echo $tmpstr | jq '.[] | select(.hidden==true) | .host' | sed s/\"//g)
  test "$pname" = "$MY_IP:$CONF_NET_PORT"
}

getNodesOrder() {
  local slist=''
  local cnt=''
  if [ $MY_ROLE = "repl_node" ]; then
    slist=(${NODE_LIST[@]})
  else
    slist=(${NODE_RO_LIST[@]})
  fi
  cnt=${#slist[@]}
  local tmpstr=$(runMongoCmd "JSON.stringify(rs.status())" -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE))
  local curstate=''
  local curip=''
  local reslist=''
  local masternode=''
  for((i=0; i<$cnt; i++)); do
    curip=$(getIp ${slist[i]})
    curstate=$(echo $tmpstr | jq '.members[] | select(.name | test("'$curip'")) | .stateStr' | sed s/\"//g)
    if [ $curstate = "PRIMARY" ]; then
      masternode=$(getNodeId ${slist[i]})
    else
      reslist="$reslist$(getNodeId ${slist[i]}),"
    fi
  done
  if [ -z $masternode ]; then
    reslist=${reslist: 0:-1}
  else
    reslist="$reslist$masternode"
  fi
  log "action"
  echo $reslist
}

msGetReplCfgFromLocal() {
  local jsstr=$(cat <<EOF
mydb = db.getSiblingDB("local")
JSON.stringify(mydb.system.replset.findOne())
EOF
  )
  runMongoCmd "$jsstr" -P $CONF_MAINTAIN_NET_PORT | sed '1d'
}

msUpdateReplCfgToLocal() {
  local rsname=''
  if [ $MY_ROLE = "repl_node" ]; then
    rsname=$RS_NAME
  else
    rsname=$RS_RO_NAME
  fi
  local jsstr=$(cat <<EOF
newlist=[$1]
mydb = db.getSiblingDB('local')
cfg = mydb.system.replset.findOne()
cnt = cfg.members.length
for(i=0; i<cnt; i++) {
  cfg.members[i].host=newlist[i]
}
mydb.system.replset.update({"_id":"$rsname"},cfg)
EOF
  )
  echo "$jsstr"
  runMongoCmd "$jsstr" -P $CONF_MAINTAIN_NET_PORT
}

MONGOD_BIN=/opt/mongodb/current/bin/mongod
shellStartMongodForAdmin() {
  # start mongod in admin mode
  runuser mongod -g svc -s "/bin/bash" -c "$MONGOD_BIN -f $MONGODB_CONF_PATH/mongod-admin.conf"
}

shellStopMongodForAdmin() {
  # stop mongod in admin mode
  runuser mongod -g svc -s "/bin/bash" -c "$MONGOD_BIN -f $MONGODB_CONF_PATH/mongod-admin.conf --shutdown"
}

changeNodeNetInfo() {
  # start mongod in admin mode
  shellStartMongodForAdmin

  local replcfg=''
  retry 60 3 0 msGetReplCfgFromLocal
  replcfg=$(msGetReplCfgFromLocal)

  local slist=''
  local cnt=''
  if [ $MY_ROLE = "repl_node" ]; then
    slist=(${NODE_LIST[@]})
  else
    slist=(${NODE_RO_LIST[@]})
  fi
  cnt=${#slist[@]}
  local oldinfo=$(cat $NET_INFO_FILE)
  local tmpstr=''
  local newlist=''
  for((i=0; i<$cnt; i++)); do
    # ip:port
    tmpstr=$(echo "$replcfg" | jq ".members[$i] | .host" | sed s/\"//g)
    # nodeid
    tmpstr=$(echo "$oldinfo" | sed -n /$tmpstr/p | cut -d' ' -f2)
    # newip
    tmpstr=$(echo ${slist[@]} | grep -o '[[:digit:].]\+|'$tmpstr | cut -d'|' -f1)
    # result
    newlist="$newlist\"$tmpstr:$CONF_NET_PORT\","
  done
  # java array: "ip:port","ip:port","ip:port"
  newlist=${newlist:0:-1}
  msUpdateReplCfgToLocal "$newlist"

  # stop mongod in admin mode
  shellStopMongodForAdmin
}

getNodesCnt() {
  local slist=''
  if [ $MY_ROLE = "repl_node" ]; then
    slist=($(sortHostList ${NODE_LIST[@]}))
  else
    slist=($(sortHostList ${NODE_RO_LIST[@]}))
  fi
  echo ${#slist[@]}
}

isAddNodesFromZero() {
  local slist=''
  if [ $MY_ROLE = "repl_node" ]; then
    slist=($(sortHostList ${NODE_LIST[@]}))
  else
    slist=($(sortHostList ${NODE_RO_LIST[@]}))
  fi
  local cnt=''
  local str1=''
  local str2=''
  cnt=${#ADDING_LIST[@]}
  for((i=0; i<$cnt; i++)); do
    str1=$str1${ADDING_LIST[i]}'\n'
  done
  str1=$(echo -e "$str1" | sort)

  cnt=${#slist[@]}
  for((i=0; i<$cnt; i++)); do
    str2=$str2${slist[i]%|*}'\n'
  done
  str2=$(echo -e "$str2" | sort)
  
  test "$str1" = "$str2"
}

isMyRoleNeedChangeVxnet() {
  local tmp=$(echo "$CHANGE_VXNET_ROLES" | grep -o "$MY_ROLE")
  test "$tmp" = "$MY_ROLE"
}

start() {
  isNodeInitialized || initNode
  createMongodConf
  if [ $CHANGE_VXNET_FLAG = "true" ]; then
    if ! isMyRoleNeedChangeVxnet; then
      log "change net info: skip this node"
      return 0
    fi
    log "change net info begin ..."
    changeNodeNetInfo
    log "save changed net info"
    saveNetInfo
    log "change net info done"
  fi
  _start
  if [ -f $NODECTL_NODE_FIRST_CREATE ]; then
    rm -f $NODECTL_NODE_FIRST_CREATE
    saveNetInfo
    if [ $ADDING_HOSTS_FLAG = "true" ] && ! isAddNodesFromZero; then
      log "adding node done"
      return 
    fi
    if ! checkNodeCanDoReplInit; then log "init replica: skip this node"; return; fi
    log "init replica begin ..."
    retry 60 3 0 msInitRepl
    retry 60 3 0 msIsReplStatusOk -P $CONF_NET_PORT
    retry 60 3 0 msIsMeMaster -P $CONF_NET_PORT
    log "add db users"
    retry 60 3 0 msInitUsers
    log "init replica done"
  elif [ $VERTICAL_SCALING_FLAG = "true" ]; then
    log "vertical scaling begin ..."
    retry 60 3 0 msIsReplStatusOk -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE)
    log "vertical scaling done"
  fi
}

stop() {
  local jsstr=$(cat <<EOF
if(rs.isMaster().ismaster) {
  rs.stepDown()
}
EOF
  )
  runMongoCmd "$jsstr" -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE) || :
  _stop
}

msAddNodes() {
  local jsstr=''
  local cnt=${#ADDING_LIST[@]}
  for((i=0; i<$cnt; i++)); do
    jsstr=$jsstr'rs.add({host:"'$(getIp ${ADDING_LIST[i]})\:$CONF_NET_PORT'", priority: 1});'
  done
  runMongoCmd "$jsstr" -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE)
}

msRmNodes() {
  local cnt=${#DELETING_LIST[@]}
  local cmpstr=''
  for((i=0; i<$cnt; i++)); do
    cmpstr=$cmpstr$(getIp ${DELETING_LIST[i]})\:$CONF_NET_PORT" "
  done
  local jsstr=$(cat <<EOF
tmpstr="$cmpstr"
members=[]
cfg=rs.conf()
for(i=0;i<cfg.members.length;i++) {
  if (tmpstr.indexOf(cfg.members[i].host) != -1) {
    continue
  }
  members.push(cfg.members[i])
}
cfg.members=members
rs.reconfig(cfg)
EOF
  )
  runMongoCmd "$jsstr" -H $1 -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE)
}

msGetAvailableNodeIp() {
  local slist=''
  if [ $MY_ROLE = "repl_node" ]; then
    slist=(${NODE_LIST[@]})
  else
    slist=(${NODE_RO_LIST[@]})
  fi
  local cnt=${#slist[@]}
  local res=''
  for((i=0; i<$cnt; i++)); do
    res=$(getIp ${slist[i]})
    runMongoCmd "rs.status()" -H $res -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE) >/dev/null 2>&1 && break
  done
  echo "$res"
}

msGetReplStatus() {
  local hostip=$(msGetAvailableNodeIp)
  local tmpstr=''

  if [ -z "$hostip" ]; then return; fi
  tmpstr=$(runMongoCmd "JSON.stringify(rs.status())" -H $hostip -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE) 2>/dev/null)
  echo "$tmpstr"
}

msGetReplConf() {
  local hostip=$(msGetAvailableNodeIp)
  local tmpstr=''

  if [ -z "$hostip" ]; then return; fi
  tmpstr=$(runMongoCmd "JSON.stringify(rs.conf())" -H $hostip -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE) 2>/dev/null)
  echo "$tmpstr"
}

msGetAvailableMasterIp() {
  local tmpstr=$(msGetReplStatus)
  tmpstr=$(echo $tmpstr | jq '.members[] | select(.stateStr=="PRIMARY") | .name' |  sed s/\"//g)
  echo ${tmpstr%:*}
}

isOtherRoleScaling() {
  local cnt=''
  if [ "$1" = "out" ]; then
    cnt=${#ADDING_LIST[@]}
  else
    cnt=${#DELETING_LIST[@]}
  fi
  test $cnt -eq 0
}

isHiddenNodeNeedChangeSyncConf() {
  if [ "$MY_ROLE" = "ro_node" ]; then return 1; fi
  local cnt=''
  if [ "$1" = "add" ]; then
    cnt=${#ADDING_LIST[@]}
  else
    cnt=${#DELETING_LIST[@]}
  fi
  if [ $cnt -gt 0 ]; then return 1; fi
  msIsMeHidden || return 1
}

scaleOut() {
  if isHiddenNodeNeedChangeSyncConf add; then
    log "hidden node change sync config"
    return
  fi
  local cnt=${#ADDING_LIST[@]}
  if [ $cnt -eq 0 ]; then log "other role scale out, skip this node"; return; fi

  if ! msIsMeMaster -P $CONF_NET_PORT -u $DB_QC_USER -p $(cat $DB_QC_PASS_FILE); then log "add nodes: not master, skip this node"; return; fi
  log "add nodes begin ..."
  msAddNodes
  log "add nodes done"
}

precheckScaleIn() {
  if isOtherRoleScaling in; then log "other role scale in, skip this node"; return; fi
  local allcnt=$(getNodesCnt)

  log "node count check"
  log "node role check"
}

scaleIn() {
  if isOtherRoleScaling in; then
    log "other role scale in, do something"
    return
  fi
    
  local hostip=$(msGetAvailableMasterIp)
  if [ -z "$hostip" ]; then log "Can't get primary node's ip"; return ERR_GET_PRIMARY_IP; fi
  log "del nodes begin ..."
  msRmNodes $hostip
  log "del nodes done"
}

mytest() {
  :
}