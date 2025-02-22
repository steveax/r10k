require 'git_utils'
require 'r10k_utils'
require 'master_manipulator'
test_name 'CODEMGMT-40 - C59223 - Multiple Environments with Custom, Forge and Git Modules Deployed to Static Path'

#Init
master_certname = on(master, puppet('config', 'print', 'certname')).stdout.rstrip
r10k_fqp = get_r10k_fqp(master)
step 'Read module path'
on(master, puppet('config print basemodulepath')) do |result|
  (result.stdout.include? ':') ? separator = ':' : separator = ';'
  @module_path = result.stdout.split(separator).first
end

git_environments_path = '/root/environments'
last_commit = git_last_commit(master, git_environments_path)
local_files_root_path = ENV['FILES'] || 'files'
helloworld_module_path = File.join(local_files_root_path, 'modules', 'helloworld')

env_names = ['production', 'stage', 'test']

#Verification
motd_path = '/etc/motd'
motd_contents = 'Hello!'
motd_contents_regex = /\A#{motd_contents}\z/

stdlib_notify_message_regex = /The test message is:.*one.*=>.*1.*two.*=>.*bats.*three.*=>.*3.*/

#File
puppet_file = <<-PUPPETFILE
moduledir '#{@module_path}'
mod "puppetlabs/motd"
mod 'puppetlabs/stdlib',
  :git => 'https://github.com/puppetlabs/puppetlabs-stdlib.git',
  :tag => 'v7.0.1'
PUPPETFILE

puppet_file_path = File.join(git_environments_path, 'Puppetfile')

#Manifest
manifest = <<-MANIFEST
  class { 'helloworld': }
  class { 'motd':
    content => '#{motd_contents}',
  }
  $hash1 = {'one' => 1, 'two' => 2}
  $hash2 = {'two' => 'bats', 'three' => 3}
  $merged_hash = merge($hash1, $hash2)
  notify { 'Test Message':
    message  => "The test message is: ${merged_hash}"
  }
MANIFEST

site_pp_path = File.join(git_environments_path, 'manifests', 'site.pp')
site_pp = create_site_pp(master_certname, manifest)

#Teardown
teardown do
  clean_up_r10k(master, last_commit, git_environments_path)

  step 'Remove "/etc/motd" File'
  on(agents, "rm -rf #{motd_path}")

  step 'Remove Static Modules'
  on(agents, "rm -rf #{@module_path}/*")
end

#Setup
step 'Stub Forge on Master'
stub_forge_on(master)

env_names.each do |env|
  if env == 'production'
    step "Checkout \"#{env}\" Branch"
    git_on(master, "checkout #{env}", git_environments_path)

    step "Copy \"helloworld\" Module to \"#{env}\" Environment Git Repo"
    scp_to(master, helloworld_module_path, File.join(git_environments_path, "site", 'helloworld'))

    step "Inject New \"site.pp\" to the \"#{env}\" Environment"
    inject_site_pp(master, site_pp_path, site_pp)

    step "Push Changes to \"#{env}\" Environment"
    git_add_commit_push(master, env, 'Update site.pp.', git_environments_path)
  else
    step "Create \"#{env}\" Branch from \"production\""
    git_on(master, 'checkout production', git_environments_path)
    git_on(master, "checkout -b #{env}", git_environments_path)

    step "Push Changes to \"#{env}\" Environment"
    git_push(master, env, git_environments_path)
  end
end

step 'Update just the "production" Environment with Puppetfile'
git_on(master, 'checkout production', git_environments_path)
create_remote_file(master, puppet_file_path, puppet_file)
git_add_commit_push(master, 'production', 'Add module.', git_environments_path)

#Tests
step 'Deploy Environments via r10k'
on(master, "#{r10k_fqp} deploy environment -v -p")

env_names.each do |env|
  agents.each do |agent|
    step "Run Puppet Agent Against \"#{env}\" Environment"
    on(agent, puppet('agent', '--test', "--environment #{env}"), :acceptable_exit_codes => 2) do |result|
      assert_no_match(/Error:/, result.stderr, 'Unexpected error was detected!')
      assert_match(/I am in the #{env} environment/, result.stdout, 'Expected message not found!')
      assert_match(stdlib_notify_message_regex, result.stdout, 'Expected message not found!')
    end

    step "Verify MOTD Contents"
    on(agent, "cat #{motd_path}") do |result|
      assert_match(motd_contents_regex, result.stdout, 'File content is invalid!')
    end
  end
end
