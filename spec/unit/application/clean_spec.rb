#!/usr/bin/env ruby

require File.dirname(__FILE__) + '/../../spec_helper'

require 'puppet/application/clean'

describe Puppet::Application::Clean do
  before :each do
    @clean_app = Puppet::Application[:clean]
    Puppet::Util::Log.stubs(:newdestination)
    Puppet::Util::Log.stubs(:level=)
  end

  it "should operate in master run_mode" do
    @clean_app.class.run_mode.name.should equal(:master)
  end

  it "should ask Puppet::Application to parse Puppet configuration file" do
    @clean_app.should_parse_config?.should be_true
  end

  it "should declare a main command" do
    @clean_app.should respond_to(:main)
  end

  describe "when handling options" do
    it "should declare handle_unexport method" do
      @clean_app.should respond_to(:handle_unexport)
    end

    it "should store argument value when calling handle_unexport" do
      @clean_app.options.expects(:[]=).with(:unexport, 'arg')
      @clean_app.send(:handle_unexport, 'arg')
    end
  end

  describe "during setup" do
    before :each do
      Puppet::Log.stubs(:newdestination)
      Puppet::Log.stubs(:level=)
      Puppet.stubs(:parse_config)
      Puppet::Node::Facts.stubs(:terminus_class=)
      Puppet::Node.stubs(:cache_class=)
    end

    it "should set console as the log destination" do
      Puppet::Log.expects(:newdestination).with(:console)

      @clean_app.setup
    end

    it "should set facts terminus and cache class to yaml" do
      Puppet::Node::Facts.expects(:terminus_class=).with(:yaml)
      Puppet::Node::Facts.expects(:cache_class=).with(:yaml)

      @clean_app.setup
    end

    it "should set node cache as yaml" do
      Puppet::Node.expects(:terminus_class=).with(:yaml)
      Puppet::Node.expects(:cache_class=).with(:yaml)

      @clean_app.setup
    end

    it "should handle all other arguments as hostnames" do
      @clean_app.command_line.stubs(:args).returns(['foo1.example.com','foo2.example.com'])
      @clean_app.setup
      @clean_app.nodes.should == ['foo1.example.com','foo2.example.com']
    end

    it "should manage the certs if the host is a CA" do
       Puppet::SSL::CertificateAuthority.stubs(:ca?).returns(true)
       Puppet::SSL::Host.expects(:ca_location=).with(:local)
       @clean_app.setup
    end

    it "should not manage the certs if the host is not a CA" do
       Puppet::SSL::CertificateAuthority.stubs(:ca?).returns(false)
       Puppet::SSL::Host.expects(:ca_location=).with(:none)
       @clean_app.setup
    end
  end

  describe "when running" do

    before :each do
      @host = 'node'
      Puppet.stubs(:info)
      [ "cert", "cached_facts", "cached_node", "reports", "storeconfigs" ].each do |m|
        @clean_app.stubs("clean_#{m}".to_sym).with(@host)
      end
      @clean_app.stubs(:nodes).returns([@host])
    end

    it "should raise an error if no host is given" do
      @clean_app.stubs(:nodes).returns([])
      lambda { @clean_app.main }.should raise_error
    end

    [ "cert", "cached_facts", "cached_node", "reports", "storeconfigs" ].each do |m|
      it "should clean #{m.sub('_',' ')}" do
        @clean_app.expects("clean_#{m}".to_sym).with(@host)

        @clean_app.main
      end
    end

  end

  describe "when cleaning certificate" do
    before :each do
      Puppet::SSL::Host.stubs(:destroy)
      @ca = mock()
      Puppet::SSL::CertificateAuthority.stubs(:instance).returns(@ca)
    end

    it "should send the :destroy order to the ca if we are a CA" do
      Puppet::SSL::Host.stubs(:ca_location).returns(:local)
      @ca.expects(:apply).with { |cert_mode,to| cert_mode == :revoke }
      @ca.expects(:apply).with { |cert_mode,to| cert_mode == :destroy }

      @clean_app.clean_cert(@host)
    end

    it "should not destroy the certs if we are not a CA" do
      Puppet::SSL::Host.stubs(:ca_location).returns(:none)
      @ca.expects(:apply).never
      @clean_app.clean_cert(@host)
    end
  end

  describe "when cleaning cached facts" do
    it "should destroy facts" do
      @host = 'node'
      Puppet::Node::Facts.expects(:destroy).with(@host)

      @clean_app.clean_cached_facts(@host)
    end
  end

  describe "when cleaning cached node" do
    it "should destroy the cached node" do
      Puppet::Node::Yaml.any_instance.expects(:destroy)
      @clean_app.clean_cached_node(@host)
    end
  end

  describe "when cleaning archived reports" do
    it "should tell the reports to remove themselves" do
      Puppet::Transaction::Report.stubs(:destroy).with(@host)

      @clean_app.clean_reports(@host)
    end
  end

  describe "when cleaning storeconfigs entries for host", :if => Puppet.features.rails? do
    before :each do
      # Stub this so we don't need access to the DB.
      require 'puppet/rails/host'

      @clean_app.options.stubs(:[]).with(:unexport).returns(false)
      Puppet.stubs(:[]).with(:storeconfigs).returns(true)

      Puppet::Rails.stubs(:connect)
      @rails_node = stub_everything 'rails_node'
      Puppet::Rails::Host.stubs(:find_by_name).returns(@rails_node)
      @clean_app.stubs(:destroy)
    end

    it "should connect to the database" do
      Puppet::Rails.expects(:connect)
      @clean_app.clean_storeconfigs(@host)
    end

    it "should find the right host entry" do
      Puppet::Rails::Host.expects(:find_by_name).with(@host).returns(@rails_node)

      @clean_app.clean_storeconfigs(@host)
    end

    describe "without unexport" do
      it "should remove the host and it's content" do
        @rails_node.expects(:destroy)

        @clean_app.clean_storeconfigs(@host)
      end
    end

    describe "with unexport" do
      before :each do
        @clean_app.options.stubs(:[]).with(:unexport).returns(true)
        @rails_node.stubs(:id).returns(1234)

        @type = stub_everything 'type'
        @type.stubs(:validattr?).with(:ensure).returns(true)

        @ensure_name = stub_everything 'ensure_name', :id => 23453
        Puppet::Rails::ParamName.stubs(:find_or_create_by_name).returns(@ensure_name)

        @param_values = stub_everything 'param_values'
        @resource = stub_everything 'resource', :param_values => @param_values, :restype => "File"
        Puppet::Rails::Resource.stubs(:find).returns([@resource])
      end

      it "should find all resources" do
        Puppet::Rails::Resource.expects(:find).with(:all, {:include => {:param_values => :param_name}, :conditions => ["exported=? AND host_id=?", true, 1234]}).returns([])

        @clean_app.clean_storeconfigs(@host)
      end

      describe "with an exported native type" do
        before :each do
          Puppet::Type.stubs(:type).returns(@type)
          @type.expects(:validattr?).with(:ensure).returns(true)
        end

        it "should test a native type for ensure as an attribute" do
          @clean_app.clean_storeconfigs(@host)
        end

        it "should delete the old ensure parameter" do
          ensure_param = stub 'ensure_param', :id => 12345, :line => 12
          @param_values.stubs(:find).returns(ensure_param)
          Puppet::Rails::ParamValue.expects(:delete).with(12345);
          @clean_app.clean_storeconfigs(@host)
        end

        it "should add an ensure => absent parameter" do
          @param_values.expects(:create).with(:value => "absent",
                                                   :line => 0,
                                                   :param_name => @ensure_name)
          @clean_app.clean_storeconfigs(@host)
        end
      end

      describe "with an exported definition" do
        it "should try to lookup a definition and test it for the ensure argument" do
          Puppet::Type.stubs(:type).returns(nil)
          definition = stub_everything 'definition', :arguments => { 'ensure' => 'present' }
          Puppet::Resource::TypeCollection.any_instance.expects(:find_definition).with('',"File").returns(definition)
          @clean_app.clean_storeconfigs(@host)
        end
      end

      it "should not unexport the resource of an unkown type" do
        Puppet::Type.stubs(:type).returns(nil)
        Puppet::Resource::TypeCollection.any_instance.expects(:find_definition).with('',"File").returns(nil)
        Puppet::Rails::ParamName.expects(:find_or_create_by_name).never
        @clean_app.clean_storeconfigs(@host)
      end

      it "should not unexport the resource of a not ensurable native type" do
        Puppet::Type.stubs(:type).returns(@type)
        @type.expects(:validattr?).with(:ensure).returns(false)
        Puppet::Resource::TypeCollection.any_instance.expects(:find_definition).with('',"File").returns(nil)
        Puppet::Rails::ParamName.expects(:find_or_create_by_name).never
        @clean_app.clean_storeconfigs(@host)
      end

      it "should not unexport the resource of a not ensurable definition" do
        Puppet::Type.stubs(:type).returns(nil)
        definition = stub_everything 'definition', :arguments => { 'foobar' => 'someValue' }
        Puppet::Resource::TypeCollection.any_instance.expects(:find_definition).with('',"File").returns(definition)
        Puppet::Rails::ParamName.expects(:find_or_create_by_name).never
        @clean_app.clean_storeconfigs(@host)
      end
    end
  end
end
