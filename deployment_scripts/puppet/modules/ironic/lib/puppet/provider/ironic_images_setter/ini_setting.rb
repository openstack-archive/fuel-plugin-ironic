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

def glance_images(glance_url, token)

    url = URI.parse("#{glance_url}/images")
    req = Net::HTTP::Get.new url.path
    req['content-type'] = 'application/json'
    req['x-auth-token'] = token

    res = handle_request(req, url)
    data = JSON.parse res.body
    data['images']
end

Puppet::Type.type(:ironic_images_setter).provide(:ruby) do
    @ironic_images = nil

    def authenticate
        keystone_v2_authenticate(
          @resource[:auth_url],
          @resource[:auth_username],
          @resource[:auth_password],
          nil,
          @resource[:auth_tenant_name])
    end

    def find_image_by_name(images, name)
        found_images = images.select{|image| image['name'] == name}
        if found_images.length == 1
          return found_images[0]['id']
        elsif found_images.length == 0
          raise KeystoneAPIError, "Image with name '#{name}' not found."
        elsif found_images.length > 1
          raise KeystoneAPIError, "Found multiple matches for name: '#{name}'"
        end
    end

    def exists?
      ini_file = Puppet::Util::IniConfig::File.new
      ini_file.read("/etc/ironic/ironic.conf")
      ironic_images.each do |setting, id|
        if ! ( ini_file['fuel'] && ini_file['fuel'][setting] && ini_file['fuel'][setting] == id)
          return nil
        end
      end
    end

    def create
        config
    end

    def ironic_images
      @ironic_images ||= get_ironic_images
    end

    def get_ironic_images
      token = authenticate
      RETRY_COUNT.times do |n|
        begin
          all_images = glance_images(@resource[:glance_url], token)
        rescue => e
          debug "Request failed: '#{e.message}' Retry: '#{n}'"
          if n == RETRY_COUNT - 1
            raise KeystoneAPIError, 'Unable to get images.'
          end
          sleep RETRY_SLEEP
          next
        end
        ironic_images = Hash.new
        ironic_images['deploy_kernel'] = find_image_by_name(all_images, 'ironic-deploy-linux')
        ironic_images['deploy_ramdisk'] = find_image_by_name(all_images, 'ironic-deploy-initramfs')
        ironic_images['deploy_squashfs'] = find_image_by_name(all_images, 'ironic-deploy-squashfs')
        return ironic_images
      end
    end

    def config
      ironic_images.each do |setting, id|
        Puppet::Type.type(:ironic_config).new(
            {:name => "fuel/#{setting}", :value => id}
        ).provider.create
      end
    end
end
