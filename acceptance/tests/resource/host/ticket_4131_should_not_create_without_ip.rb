test_name "#4131: should not create host without IP attribute"

agents.each do |agent|
  file = agent.tmpfile('4131-require-ip')

  step "configure the target system for the test"
  on agent, "rm -vrf #{file} ; touch #{file}"

  step "try to create the host, which should fail"
  # REVISIT: This step should properly need to handle the non-zero exit code,
  # and #5668 has been filed to record that.  When it is fixed this test will
  # start to fail, and this comment will tell you why. --daniel 2010-12-24
  on(agent, puppet_resource('host', 'test', "target=#{file}",
              "host_aliases=alias")) do
    fail_test "puppet didn't complain about the missing attribute" unless
      stderr.include? 'ip is a required attribute for hosts'
  end

  step "verify that the host was not added to the file"
  on(agent, "cat #{file} ; rm -f #{file}") do
    fail_test "the host was apparently added to the file" if stdout.include? 'test'
  end
end
