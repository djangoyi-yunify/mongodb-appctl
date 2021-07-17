# sourced by /opt/app/current/bin/ctl.sh

MONGODB_DATA_PATH=/data/mongodb-data
MONGODB_LOG_PATH=/data/mongodb-logs
MONGODB_CONF_PATH=/data/mongodb-conf

checkNodeFirstCreated() {
  test -f $NODECTL_NODE_FIRST_CREATE
}

checkReplNeedInit() {
  checkNodeFirstCreated && [ $ADDING_HOSTS_FLAG = "false" ]
}

# createMongodCfg
# desc: create mongod.conf
# file: mongod.conf, mongod-admin.conf
# location: /opt/app/current/conf/mongodb
createMongodConf() {
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
  replSetName: repl
MONGOD_CONF

if checkReplNeedInit; then
  cat > $MONGODB_CONF_PATH/mongod-repl-init.conf <<MONGOD_CONF
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
  replSetName: repl
MONGOD_CONF
fi
}

checkCfgChange() {
  :
}

NODECTL_NODE_FIRST_CREATE="/data/appctl/data/nodectl.node.first.create"
QC_PASS_FILE="/data/appctl/data/qc_pass"
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
  echo ${encrypted:0:16} > $QC_PASS_FILE
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

start() {
  isNodeInitialized || initNode
  if checkNodeFirstCreated; then
    createMongodConf
    if [ ! $ADDING_HOSTS_FLAG = "true" ]; then
      log "init the replica"
    fi
    rm -f $NODECTL_NODE_FIRST_CREATE
  else
    if [ $CHANGE_VXNET_FLAG = "true" ]; then
      #checkNetInfoChange
      log "change net info"
      #saveNetInfo
    elif [ $VERTICAL_SCALING_FLAG = "true" ]; then
      log "vertical scaling"
    else
      log "normal stop-start"
    fi
  fi
  #_start
}

stop() {
  :
}