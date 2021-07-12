# sourced by /opt/app/current/bin/ctl.sh

# createMongodCfg
# desc: create mongod.conf
# file: mongod.conf, mongod-admin.conf
# location: /opt/app/current/conf/mongodb
createMongodCfg() {
  local cfgpath="/opt/app/current/conf/mongodb"
  cat > $cfgpath/mongod.conf <<MONGOD_CONF
systemLog:
  destination: file
  path: /data/mongodb-logs/mongod.log
  logAppend: true
  logRotate: reopen
processManagement:
  fork: true
net:
  port: 27017
  bindIp: 0.0.0.0
  maxIncomingConnections: 65536
  compression:
    compressors: snappy
security:
  keyFile:
  authorization: enabled
storage:
  dbPath: /data/mongodb-data
  journal:
    enabled: true
  engine: wiredTiger
replication:
  oplogSizeMB: 2048
  replSetName: repl
MONGOD_CONF

  cat > $cfgpath/mongod-admin.conf <<MONGOD_CONF
MONGOD_CONF
}

checkCfgChange() {
  :
}