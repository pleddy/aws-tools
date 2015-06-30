#!/usr/bin/ruby

require 'pp'
require 'aws-sdk'
require 'json'


# get cli arguments

if ( ! (ARGV[0]) )
  puts "snapshot required"
  exit 
end
my_snapshot = ARGV[0]


# initialize
creds = JSON.load(File.read('secrets.json'))
Aws.config[:credentials] = Aws::Credentials.new(creds['aws']['creds']['aws_access_key_id'], creds['aws']['creds']['aws_secret_access_key'])

repl_username = creds['mysql']['replication_user']
repl_password = creds['mysql']['replication_password']
rds_instance = creds['mysql']['rds_instance']
region_name = 'us-east-1'


# get aws accout id for arn building
begin
  iam_resource = Aws::IAM::Resource.new( client: Aws::IAM::Client.new(region: region_name) )
  aws_acct_id = iam_resource.current_user.arn.match(/\d+/).to_s
rescue
  p 'gathering account information failed'
  exit
end


#### RDS
begin
  rds_client = Aws::RDS::Client.new(region: region_name)
  resp = rds_client.list_tags_for_resource(options = {resource_name: "arn:aws:rds:us-east-1:#{aws_acct_id}:snapshot:#{my_snapshot}"})
  original_name = rds_client.describe_db_snapshots({db_snapshot_identifier: "test-201506291142"})['db_snapshots'][0].db_instance_identifier
rescue
  p 'gathering snapshot info failed'
  exit
end
my_tags = {}
resp[0].each do |my_tag| my_tags[my_tag.key] = my_tag.value end
pp my_tags

ymdhm = Time.new.strftime('%Y%m%d%H%M')
my_name = original_name + '-' + ymdhm
begin
  resp = rds_client.restore_db_instance_from_db_snapshot({
    db_instance_identifier: my_name, 
    db_snapshot_identifier: my_snapshot, 
    db_instance_class: 'db.m1.small', 
    #tags: [{key: "a", value: "001"}]
  })
rescue Aws::RDS::Errors::ServiceError
  p 'snapshot restore failed'
  exit
end
pp resp

my_resource = Aws::RDS::Resource.new(client: rds_client)
my_db_instance = my_resource.db_instance(my_name)

#instance.wait_until(max_attempts:10, delay:5) {|instance| instance.state.name == 'running' }
my_db_instance.wait_until(max_attempts:10, delay:60) do |instance| 
  instance.db_instance_status == 'available'
  print '.'
end
puts 'END'












