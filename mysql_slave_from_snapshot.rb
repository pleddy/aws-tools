#!/usr/bin/ruby

require 'pp'
require 'aws-sdk'
require 'json'

# get cli arguments
if ( ! (ARGV[0]) )
  puts "Usage: snapshot required"
  exit 
end
my_snapshot = ARGV[0]

# initialize
my_creds = JSON.load(File.read('secrets.json'))
Aws.config[:credentials] = Aws::Credentials.new(my_creds['aws']['creds']['aws_access_key_id'], my_creds['aws']['creds']['aws_secret_access_key'])
my_mysql_replication_user = my_creds['mysql']['mysql_replication_user']
my_mysql_replication_password = my_creds['mysql']['mysql_replication_password']
my_mysql_master_user = my_creds['mysql']['mysql_master_user']
my_mysql_master_password = my_creds['mysql']['mysql_master_password']
my_region_name = 'us-east-1'

# get the aws accout id for arn building
print 'getting aws acct number: '
begin
  my_iam_resource = Aws::IAM::Resource.new( client: Aws::IAM::Client.new(region: my_region_name) )
  my_aws_acct_id = my_iam_resource.current_user.arn.match(/\d+/).to_s
  puts my_aws_acct_id
rescue
  p 'gathering account information failed'
  exit
end

# get the name of the db instance that parented the snapshot, and the snapshot tags that define master replication
print 'getting parent db instance name and master db info via snapshot tags: '
begin
  my_rds_client = Aws::RDS::Client.new(region: my_region_name)
  my_resp = my_rds_client.list_tags_for_resource(options = {resource_name: "arn:aws:rds:us-east-1:#{my_aws_acct_id}:snapshot:#{my_snapshot}"})
  my_original_name = my_rds_client.describe_db_snapshots({db_snapshot_identifier: my_snapshot})['db_snapshots'][0].db_instance_identifier
  puts my_original_name
rescue
  p 'gathering snapshot info failed'
  exit
end
my_tags = {}
my_resp[0].each do |my_tag| my_tags[my_tag.key] = my_tag.value end
p my_tags
my_master_host = my_tags['master_host']
my_master_log_file = my_tags['master_log_file']
my_master_log_pos = my_tags['master_log_pos']
my_db_subnet_group_name = my_tags['db_subnet_group_name']

# create a new db instance from the snapshot
print 'restore snapshot: '
my_ymdhm = Time.new.strftime('%Y%m%d%H%M')
my_name = my_original_name + '-' + my_ymdhm
puts my_name
begin
  resp = my_rds_client.restore_db_instance_from_db_snapshot({
    db_instance_identifier: my_name, 
    db_snapshot_identifier: my_snapshot, 
    db_instance_class: 'db.m1.small', 
    db_subnet_group_name: my_db_subnet_group_name,
    #tags: [{key: "a", value: "001"}]
  })
rescue Aws::RDS::Errors::ServiceError
  p 'snapshot restore failed'
  exit
end

# monitor if the db instance is up yet
my_status = nil
puts 'waiting for db instance to boot, 30 second updates follow'
while ( my_status != 'available' ) do
  my_resp = my_rds_client.describe_db_instances({db_instance_identifier: my_name})
  my_status = my_resp.db_instances[0].db_instance_status
  print my_status
  puts '...'
  sleep 30
end

# fetch endpoint for RDS instance using name of rds instance's name
print 'getting endpoint of new db instance: '
my_rds_resource = Aws::RDS::Resource.new(client: my_rds_client)
my_db_instance = my_rds_resource.db_instance(my_name)
my_rds_endpoint = my_db_instance.endpoint.address
p my_rds_endpoint

# set master
p 'set master for replication'
my_result = %x[mysql -e "CALL mysql.rds_set_external_master ('#{my_master_host}', 3306, '#{my_mysql_replication_user}', '#{my_mysql_replication_password}', '#{my_master_log_file}', #{my_master_log_pos}, 0);" -h #{my_rds_endpoint} -u #{my_mysql_master_user} -p#{my_mysql_master_password} 2>/dev/null]
p my_result

# start slave replication
p 'start replication'
my_result = %x[mysql -e 'CALL mysql.rds_start_replication;' -h #{my_rds_endpoint} -u #{my_mysql_master_user} -p#{my_mysql_master_password} 2>/dev/null]
p my_result

p 'completed, new cloned db instance should be replicating master'

