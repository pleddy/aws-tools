#!/usr/bin/ruby

require 'pp'
require 'aws-sdk'
require 'json'

# get cli arguments

if ( ! (ARGV[0]) )
  puts "Usage: db instance required"
  exit 
end
my_rds_dbinstance = ARGV[0]


# initialize

my_creds = JSON.load(File.read('secrets.json'))
Aws.config[:credentials] = Aws::Credentials.new(my_creds['aws']['creds']['aws_access_key_id'], my_creds['aws']['creds']['aws_secret_access_key'])
my_mysql_master_user = my_creds['mysql']['mysql_master_user']
my_mysql_master_password = my_creds['mysql']['mysql_master_password']
my_region = 'us-east-1'


# fetch endpoint for RDS instance using name of rds instance's name
my_rds_client = Aws::RDS::Client.new(region: my_region)
my_resource = Aws::RDS::Resource.new(client: my_rds_client)
my_db_instance = my_resource.db_instance(my_rds_dbinstance)
my_rds_endpoint = my_db_instance.endpoint.address
my_db_subnet_group_name = my_db_instance.db_subnet_group.db_subnet_group_name

# stop replication while snapshotting
puts 'stop replication'
my_resp = %x[mysql -e 'CALL mysql.rds_stop_replication;' -h #{my_rds_endpoint} -u #{my_mysql_master_user} -p#{my_mysql_master_password} 2>/dev/null]
p my_resp

# get slave status and parse into a key/value hash for easy reference
puts 'get slave status params'
my_result = %x[mysql -e 'show slave status\\G' -h #{my_rds_endpoint} -u #{my_mysql_master_user} -p#{my_mysql_master_password} 2>/dev/null]
p my_result
my_slave_status_array = my_result.delete!(' ').split("\n").grep  /:/
my_slave_status = Hash[my_slave_status_array.map {|el| el.split ':'}]
#pp my_slave_status;exit


# create snapshot and tag with slave status params
puts 'take snapshot'
my_ymdhm = Time.new.strftime("%Y%m%d%H%M")
my_name = my_rds_dbinstance + '-' + my_ymdhm
my_resp = my_rds_client.create_db_snapshot({
  db_snapshot_identifier: my_name,
  db_instance_identifier: my_rds_dbinstance,
  tags: [
    {key: 'master_host', value: my_slave_status['Master_Host'] },
    {key: 'master_log_file', value: my_slave_status['Master_Log_File'] },
    {key: 'master_log_pos', value: my_slave_status['Read_Master_Log_Pos'] },
    {key: 'db_subnet_group_name', value: my_db_subnet_group_name },
  ],
})
p my_resp

# start replication up again after snapshot finished
puts 'restart replication'
my_resp = %x[mysql -e 'CALL mysql.rds_start_replication;' -h #{my_rds_endpoint} -u #{my_mysql_master_user} -p#{my_mysql_master_password} 2>/dev/null]
p my_resp

# monitor if the db instance snapshot is done
my_status = nil
puts 'waiting for db instance snapshot to finish, 30 second updates follow'
while ( my_status != 'available' ) do
  my_resp = my_rds_client.describe_db_snapshots({db_snapshot_identifier: my_name})
  my_status = my_resp.db_snapshots[0].status
  print my_status
  puts '...'
  sleep 30
end

puts 'completed, now, you may create a clone slave using the new snapshot'

