require 'httpclient'
require 'simple_solr_client/response/generic_response'
require 'securerandom'

# require 'simple_solr_client/core'

module SimpleSolrClient

  # A Client talks to the Solr instance; use a SimpleSolrClient::Core to talk to a
  # particular core.

  class Client

    attr_reader :base_url, :rawclient

    def initialize(url)
      @base_url  = url.chomp('/')
      @client_url = @base_url
      @rawclient = HTTPClient.new
    end

    # Construct a URL for the given arguments that hit the configured solr
    # @return [String] the new url, based on the base_url and the passed args
    def url(*args)
      [@base_url, *args].join('/').chomp('/')
    end

    # Sometimes, you just gotta have a top_level_url (as opposed to a
    # core-level URL)
    def top_level_url(*args)
      [@client_url, *args].join('/').chomp('/')
    end


    # Call a get on the underlying http client and return the content
    # You can pass in :force_top_level=>true for those cases wehn
    # you absolutely have to use the client-level url and not a
    # core level URL
    def raw_get_content(path, args={})
      if args.delete(:force_top_level_url)
        u = top_level_url(path)
      else
        u = url(path)
      end
      res = @rawclient.get(u, args)
      res.content
    end

    # A basic get to the instance (not any specific core)
    # @param [String] path The parts of the URL that comes after the core
    # @param [Hash] args The url arguments
    # @return [Hash] the parsed-out response
    def _get(path, args={})
      path.sub!(/\A\//, '')
      args['wt'] = 'json'
      res = JSON.parse(raw_get_content(path, args))
      if res['error']
        raise RuntimeError.new, res['error']
      end
      res
    end

    #  post JSON data.
    # @param [String] path The parts of the URL that comes after the core
    # @param [Hash,Array] object_to_post The data to post as json
    # @return [Hash] the parsed-out response

    def _post_json(path, object_to_post)
      resp = @rawclient.post(url(path), JSON.dump(object_to_post), {'Content-type' => 'application/json'})
      JSON.parse(resp.content)
    end

    # Get from solr, and return a Response object of some sort
    # @return [SimpleSolrClient::Response, response_type]
    def get(path, args = {}, response_type = nil)
      response_type = SimpleSolrClient::Response::GenericResponse if response_type.nil?
      response_type.new(_get(path, args))
    end

    # Post an object as JSON and return a Response object
    # @return [SimpleSolrClient::Response, response_type]
    def post_json(path, object_to_post, response_type = nil)
      response_type = SimpleSolrClient::Response::GenericResponse if response_type.nil?
      response_type.new(_post_json(path, object_to_post))
    end


    # Get a client specific to the given core2
    # @param [String] corename The name of the core (which must already exist!)
    # @return [SimpleSolrClient::Core]
    def core(corename)
      SimpleSolrClient::Core.new(@base_url, corename)
    end


    def cores
      get('admin/cores', {:force_top_level_url=>true}).status.keys
    end


    # Create a new, temporary core
    #noinspection RubyWrongHash
    def new_core(corename)
      dir      = temp_core_dir_setup(corename)

      args = {
          :wt          => 'json',
          :action      => 'CREATE',
          :name        => corename,
          :instanceDir => dir
      }

      get('admin/cores', args)
      core(corename)

    end

    def temp_core
      new_core('sstemp_' + SecureRandom.uuid)
    end

    # Set up files for a temp core
    def temp_core_dir_setup(corename)
      dest = Dir.mktmpdir("simple_solr_#{corename}")
      src  = SAMPLE_CORE_DIR
      FileUtils.cp_r File.join(src, '.'), dest
      dest
    end

    # Unload all cores whose name includes 'sstemp'
    def unload_temp_cores
      cores.each do |k|
        core(k).unload if k =~ /sstemp/
      end
    end

  end

end
