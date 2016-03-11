#
# Cookbook Name:: splunk
# Recipe:: forwarder
# 
# Copyright 2011-2012, BBY Solutions, Inc.
# Copyright 2011-2012, Opscode, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
include_recipe 'oz-ec2'

directory "/opt" do
  mode "0755"
  owner "root"
  group "root"
  ignore_failure true
end

splunk_cmd = "#{node['splunk']['forwarder_home']}/bin/splunk"
splunk_package_version = "splunkforwarder-#{node['splunk']['forwarder_version']}-#{node['splunk']['forwarder_build']}"

splunk_file = splunk_package_version + 
  case node['platform']
  when "centos","redhat","fedora","amazon"
    if node['kernel']['machine'] == "x86_64"
      "-linux-2.6-x86_64.rpm"
    else
      ".i386.rpm"
    end
  when "debian","ubuntu"
    if node['kernel']['machine'] == "x86_64"
      "-linux-2.6-amd64.deb"
    else
      "-linux-2.6-intel.deb"
    end
  end

s3_file "#{Chef::Config['file_cache_path']}/#{splunk_file}" do
  remote_path splunk_file
  bucket "oz-team-files"
  ignore_failure true
end

package splunk_package_version do
  source "#{Chef::Config['file_cache_path']}/#{splunk_file}"
  case node['platform']
  when "centos","redhat","fedora","amazon"
    provider Chef::Provider::Package::Rpm
  when "debian","ubuntu"
    provider Chef::Provider::Package::Dpkg
  end
  ignore_failure true
end

execute "#{splunk_cmd} enable boot-start --accept-license --answer-yes && echo true > /opt/splunk_license_accepted_#{node['splunk']['forwarder_version']}" do
  not_if do
    File.exists?("/opt/splunk_license_accepted_#{node['splunk']['forwarder_version']}")
  end
  ignore_failure true
end

splunk_password = node['splunk']['auth'].split(':')[1]
execute "#{splunk_cmd} edit user admin -password #{splunk_password} -roles admin -auth admin:changeme && echo true > /opt/splunk_setup_passwd" do
  not_if do
    File.exists?("/opt/splunk_setup_passwd")
  end
  ignore_failure true
end

service "splunk" do
  action [ :nothing ]
  supports :status => true, :start => true, :stop => true, :restart => true
  ignore_failure true
end

# chef-solo will require solo-search so this will work with chef solo's version of data bag search
role_name = ""
if node['splunk']['distributed_search'] == true
  role_name = node['splunk']['indexer_role']
else
  role_name = node['splunk']['server_role']
end

splunk_servers = search(:node, "role:#{role_name}")

if node['splunk']['ssl_forwarding'] == true
  directory "#{node['splunk']['forwarder_home']}/etc/auth/forwarders" do
    owner "root"
    group "root"
    action :create
    ignore_failure true
  end
  
  [node['splunk']['ssl_forwarding_cacert'],node['splunk']['ssl_forwarding_servercert']].each do |cert|
		if cert.start_with? 's3://'
			cert_basename = cert.split('/').last
			cert_s3_bucket = cert.split('/')[2]
			cert_s3_path = '/' + cert.split('/')[3..-1].join('/')
			Chef::Log.info("Installing #{cert_basename} cert file from #{cert_s3_bucket} #{cert_s3_path}")
			s3_file "#{node['splunk']['forwarder_home']}/etc/auth/forwarders/#{cert_basename}" do
				bucket cert_s3_bucket
				remote_path cert_s3_path
				owner "root"
				group "root"
				mode "0755"
				notifies :restart, resources(:service => "splunk") if node['splunk']['allow_restart']
        ignore_failure true
			end
		else
			cookbook_file "#{node['splunk']['forwarder_home']}/etc/auth/forwarders/#{cert}" do
				cookbook node['splunk']['cookbook_name']
				source "ssl/forwarders/#{cert}"
				owner "root"
				group "root"
				mode "0755"
				notifies :restart, resources(:service => "splunk") if node['splunk']['allow_restart']
        ignore_failure true
			end
		end
  end

  # SSL passwords are encrypted when splunk reads the file.  We need to save the password.
  # We need to save the password if it has changed so we don't keep restarting splunk.
  # Splunk encrypted passwords always start with $1$
  # NOTE: cannot save with chef solo
  ruby_block "Saving Encrypted Password (outputs.conf)" do
    block do
      outputsPass = `grep -m 1 "sslPassword = " #{node['splunk']['forwarder_home']}/etc/system/local/outputs.conf | sed 's/sslPassword = //'`
      if outputsPass.match(/^\$1\$/) && outputsPass != node['splunk']['outputsSSLPass']
        unless defined? Chef::Config[:solo]
					node['splunk']['outputsSSLPass'] = outputsPass
					node.save
				end
      end
    end
    ignore_failure true
  end
end

template "#{node['splunk']['forwarder_home']}/etc/system/local/outputs.conf" do
  cookbook node['splunk']['cookbook_name']
  source "forwarder/outputs.conf.erb"
  owner "root"
  group "root"
  mode "0644"
  variables :splunk_servers => splunk_servers
  notifies :restart, resources(:service => "splunk") if node['splunk']['allow_restart']
  ignore_failure true
end

["limits"].each do |cfg|
  template "#{node['splunk']['forwarder_home']}/etc/system/local/#{cfg}.conf" do
    cookbook node['splunk']['cookbook_name']
    source "forwarder/#{cfg}.conf.erb"
    owner "root"
    group "root"
    mode "0640"
    notifies :restart, resources(:service => "splunk") if node['splunk']['allow_restart']
    ignore_failure true
   end
end

["inputs", "props"].each do |cfg|
  template "Moving #{cfg} file for role: #{node['splunk']['forwarder_role']}" do
    path "#{node['splunk']['forwarder_home']}/etc/system/local/#{cfg}.conf"
    cookbook node['splunk']['cookbook_name']
    source "forwarder/#{node['splunk']['forwarder_config_folder']}/#{node['splunk']['forwarder_role']}.#{cfg}.conf.erb"
    owner "root"
    group "root"
    mode "0640"
    notifies :restart, resources(:service => "splunk") if node['splunk']['allow_restart']
    ignore_failure true
  end
end


template "/etc/init.d/splunk" do
  cookbook node['splunk']['cookbook_name']
  source "forwarder/splunk.erb"
  mode "0755"
  owner "root"
  group "root"
  ignore_failure true

end

if node['splunk']['allow_restart']
	service "splunk" do
    action :start
    ignore_failure true
	end
end
