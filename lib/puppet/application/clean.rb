require 'puppet/application'

class Puppet::Application::Clean < Puppet::Application

  should_parse_config
  run_mode :master

  attr_reader :nodes

  option("--unexport","-u")

  def main
    raise "At least one node should be passed" if nodes.empty?
    begin
      nodes.each do |node|
        self.clean_cert(node)
        self.clean_cached_facts(node)
        self.clean_cached_node(node)
        self.clean_reports(node)
        self.clean_storeconfigs(node)
      end
    rescue => detail
      puts detail.backtrace if Puppet[:trace]
      puts detail.to_s
    end
  end

  # clean signed cert for +host+
  def clean_cert(node)
    if Puppet::SSL::Host.ca_location == :local
      ca.apply(:revoke, :to => [node])
      ca.apply(:destroy, :to => [node])
      Puppet.info "%s certificates removed from ca" % node
    else
      Puppet.info "Not managing %s certs as this host is not a CA" % node
    end
  end

  # clean facts for +host+
  def clean_cached_facts(node)
    Puppet::Node::Facts.destroy(node)
    Puppet.info "%s's facts removed" % node
  end

  # clean cached node +host+
  def clean_cached_node(node)
    Puppet::Node.destroy(node)
    Puppet.info "%s's cached node removed" % node
  end

  # clean node reports for +host+
  def clean_reports(node)
    Puppet::Transaction::Report.destroy(node)
    Puppet.info "%s's reports removed" % node
  end

  # clean store config for +host+
  def clean_storeconfigs(node)
    return unless Puppet[:storeconfigs] && Puppet.features.rails?
    Puppet::Rails.connect
    unless rails_node = Puppet::Rails::Host.find_by_name(node)
      Puppet.notice "No entries found for %s in storedconfigs." % node
      return
    end

    if options[:unexport]
      unexport(rails_node)
      Puppet.notice "Force %s's exported resources to absent" % node
      Puppet.warning "Please wait other host have checked-out their configuration before finishing clean-up wih:"
      Puppet.warning "$ puppetclean #{node}"
    else
      rails_node.destroy
      Puppet.notice "%s storeconfigs removed" % node
    end
  end

  def unexport(node)
    # fetch all exported resource
    query = {:include => {:param_values => :param_name}}
    query[:conditions] = ["exported=? AND host_id=?", true, node.id]

    Puppet::Rails::Resource.find(:all, query).each do |resource|
      if type_is_ensurable(resource)
        line = 0
        param_name = Puppet::Rails::ParamName.find_or_create_by_name("ensure")

        if ensure_param = resource.param_values.find(:first, :conditions => [ 'param_name_id = ?', param_name.id])
          line = ensure_param.line.to_i
          Puppet::Rails::ParamValue.delete(ensure_param.id);
        end

        # force ensure parameter to "absent"
        resource.param_values.create(:value => "absent",
                         :line => line,
                         :param_name => param_name)
        Puppet.info("%s has been marked as \"absent\"" % resource.name)
      end
    end
  end

  def setup
    super
    Puppet::Util::Log.newdestination(:console)

    Puppet.parse_config

    if options[:debug]
      Puppet::Util::Log.level = :debug
    elsif options[:verbose]
      Puppet::Util::Log.level = :info
    end

    @nodes = command_line.args.collect { |h| h.downcase }

    if Puppet::SSL::CertificateAuthority.ca?
      Puppet::SSL::Host.ca_location = :local
    else
      Puppet::SSL::Host.ca_location = :none
    end

    Puppet::Node::Facts.terminus_class = :yaml
    Puppet::Node::Facts.cache_class = :yaml
    Puppet::Node.terminus_class = :yaml
    Puppet::Node.cache_class = :yaml
  end

  private
  def ca
    @ca ||= Puppet::SSL::CertificateAuthority.instance
  end

  def environment
    @environemnt ||= Puppet::Node::Environment.new
  end

  def type_is_ensurable(resource)
      (type=Puppet::Type.type(resource.restype)) && type.validattr?(:ensure) || \
        (type = environment.known_resource_types.find_definition('',resource.restype)) && type.arguments.keys.include?('ensure')
  end

end