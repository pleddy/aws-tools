#!/usr/bin/ruby

require 'pp'
require 'aws-sdk'
require 'json'


# initialize

creds = JSON.load(File.read('secrets.json'))
Aws.config[:credentials] = Aws::Credentials.new(creds['aws']['creds']['aws_access_key_id'], creds['aws']['creds']['aws_secret_access_key'])

username = creds['mysql']['replication_user']
password = creds['mysql']['replication_password']
rds_instance_name = creds['mysql']['rds_instance_name']
region = 'us-east-1'


# fetch endpoint for RDS instance using name of rds instance's name
client = Aws::RDS::Client.new(region: region)
resource = Aws::RDS::Resource.new(client: client)
db_instance = resource.db_instance(rds_instance_name)
rds_endpoint = db_instance.endpoint.address


# stop replication while snapshotting
result = %x[mysql -e 'CALL mysql.rds_stop_replication;' -h #{rds_endpoint} -u #{username} -p#{password}]


# get slave status and parse into a key/value hash for easy reference
result = %x[mysql -e 'show slave status\\G' -h #{rds_endpoint} -u #{username} -p#{password}]
slave_status_array = result.delete!(' ').split("\n").grep  /:/
slave_status = Hash[slave_status_array.map {|el| el.split ':'}]
#pp slave_status;exit


# create snapshot and tag with slave status params
ymdhm = Time.new.strftime("%Y%m%d%H%M")
my_client = Aws::RDS::Client.new( region: region )
resp = my_client.create_db_snapshot({
  db_snapshot_identifier: 'test' + '-' + ymdhm,
  db_instance_identifier: rds_instance_name,
  tags: [
    {key: 'hostname', value: slave_status['Master_Host'], },
    {key: 'master_log_file', value: slave_status['Master_Log_File'], },
    {key: 'master_log_pos', value: slave_status['Read_Master_Log_Pos'], },
  ],
})


# start replication up again after snapshot finished
result = %x[mysql -e 'CALL mysql.rds_start_replication;' -h #{rds_endpoint} -u #{username} -p#{password}]

