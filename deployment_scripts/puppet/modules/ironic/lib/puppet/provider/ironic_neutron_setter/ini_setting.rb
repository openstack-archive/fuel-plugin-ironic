require 'rubygems'
require 'net/http'
require 'net/https'
require 'json'
require 'puppet/util/inifile'

class KeystoneError < Puppet::Error
end

class KeystoneConnectionError < KeystoneError
end

class KeystoneAPIError < KeystoneError
end

RETRY_COUNT = 10
RETRY_SLEEP = 3

def handle_request(req, url)
    begin
        use_ssl = url.scheme == "https" ? true : false
        http = Net::HTTP.start(url.hostname, url.port, {:use_ssl => use_ssl})
        res = http.request(req)

        if res.code != '200'
            raise KeystoneAPIError, "Received error response from Keystone server at #{url}: #{res.message}"
        end
    rescue Errno::ECONNREFUSED => detail
        raise KeystoneConnectionError, "Failed to connect to Keystone server at #{url}: #{detail}"
    rescue SocketError => detail
        raise KeystoneConnectionError, "Failed to connect to Keystone server at #{url}: #{detail}"
    end

    res
end

def keystone_v2_authenticate(auth_url,
                             username,
                             password,
                             tenantId=nil,
                             tenantName=nil)

    post_args = {
        'auth' => {
            'passwordCredentials' => {
                'username' => username,
                'password' => password
            },
        }}

    if tenantId
        post_args['auth']['tenantId'] = tenantId
    end

    if tenantName
        post_args['auth']['tenantName'] = tenantName
    end

    url = URI.parse("#{auth_url}/tokens")
    req = Net::HTTP::Post.new url.path
    req['content-type'] = 'application/json'
    req.body = post_args.to_json

    res = handle_request(req, url)
    data = JSON.parse res.body
    return data['access']['token']['id']
end

def neutron_networks(neutron_url, token)

    url = URI.parse("#{neutron_url}/networks")
    req = Net::HTTP::Get.new url.path
    req['content-type'] = 'application/json'
    req['x-auth-token'] = token

    res = handle_request(req, url)
    data = JSON.parse res.body
    data['networks']
end

Puppet::Type.type(:ironic_neutron_setter).provide(:ruby) do
    @neutron_network = nil

    def authenticate
        keystone_v2_authenticate(
          @resource[:auth_url],
          @resource[:auth_username],
          @resource[:auth_password],
          nil,
          @resource[:auth_tenant_name])
    end

    def find_network_by_name(networks, name)
        found_networks = networks.select{|net| net['name'] == name}
        if found_networks.length == 1
          return found_networks[0]['id']
        elsif found_networks.length == 0
          raise KeystoneAPIError, "Network with name '#{name}' not found."
        elsif found_networks.length > 1
          raise KeystoneAPIError, "Found multiple matches for name: '#{name}'"
        end
    end

    def exists?
      ini_file = Puppet::Util::IniConfig::File.new
      ini_file.read("/etc/ironic/ironic.conf")
      ini_file['neutron'] && ini_file['neutron']['cleaning_network_uuid'] && ini_file['neutron']['cleaning_network_uuid'] == neutron_network
    end

    def create
        config
    end

    def neutron_network
      @neutron_network ||= get_neutron_network
    end

    def get_neutron_network
      token = authenticate
      RETRY_COUNT.times do |n|
        begin
          all_networks = neutron_networks(@resource[:neutron_url], token)
        rescue => e
          debug "Request failed: '#{e.message}' Retry: '#{n}'"
          if n == RETRY_COUNT - 1
            raise KeystoneAPIError, 'Unable to get networks.'
          end
          sleep RETRY_SLEEP
          next
        end
        return find_network_by_name(all_networks, 'baremetal')
      end
    end

    def config
      Puppet::Type.type(:ironic_config).new(
        {:name => "neutron/cleaning_network_uuid", :value => neutron_network}
      ).provider.create
    end
end
