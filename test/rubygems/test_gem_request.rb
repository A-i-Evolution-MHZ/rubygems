# frozen_string_literal: true

require_relative "helper"
require "rubygems/request"

unless Gem::HAVE_OPENSSL
  warn "Skipping Gem::Request tests.  openssl not found."
end

class TestGemRequest < Gem::TestCase
  CA_CERT_FILE     = cert_path "ca"
  CHILD_CERT       = load_cert "child"
  EXPIRED_CERT     = load_cert "expired"
  PUBLIC_CERT      = load_cert "public"
  PUBLIC_CERT_FILE = cert_path "public"
  SSL_CERT         = load_cert "ssl"

  def make_request(uri, request_class, last_modified, proxy)
    Gem::Request.create_with_proxy uri, request_class, last_modified, proxy
  end

  # This method is same code as Base64.encode64
  # We should not use Base64.encode64 because we need to avoid gem activation.
  def base64_encode64(bin)
    [bin].pack("m")
  end

  def setup
    @proxies = %w[http_proxy https_proxy HTTP_PROXY http_proxy_user HTTP_PROXY_USER http_proxy_pass HTTP_PROXY_PASS no_proxy NO_PROXY]
    @old_proxies = @proxies.map {|k| ENV[k] }
    @proxies.each {|k| ENV[k] = nil }

    super

    @proxy_uri = "http://localhost:1234"
    @uri = Gem::URI("http://example")

    @request = make_request @uri, nil, nil, nil
  end

  def teardown
    super
    Gem.configuration[:http_proxy] = nil
    @proxies.each_with_index {|k, i| ENV[k] = @old_proxies[i] }
  end

  def test_initialize_proxy
    proxy_uri = "http://proxy.example.com"

    request = make_request @uri, nil, nil, proxy_uri

    assert_equal proxy_uri, request.proxy_uri.to_s
  end

  def test_initialize_proxy_URI
    proxy_uri = "http://proxy.example.com"

    request = make_request @uri, nil, nil, Gem::URI(proxy_uri)

    assert_equal proxy_uri, request.proxy_uri.to_s
  end

  def test_initialize_proxy_ENV
    ENV["http_proxy"] = @proxy_uri
    ENV["http_proxy_user"] = "foo"
    ENV["http_proxy_pass"] = "bar"

    request = make_request @uri, nil, nil, nil

    proxy = request.proxy_uri

    assert_equal "foo", proxy.user
    assert_equal "bar", proxy.password
  end

  def test_initialize_proxy_ENV_https
    ENV["https_proxy"] = @proxy_uri

    request = make_request Gem::URI("https://example"), nil, nil, nil

    proxy = request.proxy_uri

    assert_equal Gem::URI(@proxy_uri), proxy
  end

  def test_proxy_ENV
    ENV["http_proxy"] = "http://proxy"
    ENV["https_proxy"] = ""

    request = make_request Gem::URI("https://example"), nil, nil, nil

    proxy = request.proxy_uri

    assert_nil proxy
  end

  def test_configure_connection_for_https
    connection = Gem::Net::HTTP.new "localhost", 443

    request = Class.new(Gem::Request) do
      def self.get_cert_files
        [TestGemRequest::PUBLIC_CERT_FILE]
      end
    end.create_with_proxy Gem::URI("https://example"), nil, nil, nil

    Gem::Request.configure_connection_for_https connection, request.cert_files

    cert_store = connection.cert_store

    assert cert_store.verify CHILD_CERT
  end

  def test_configure_connection_for_https_ssl_ca_cert
    ssl_ca_cert = Gem.configuration.ssl_ca_cert
    Gem.configuration.ssl_ca_cert = CA_CERT_FILE

    connection = Gem::Net::HTTP.new "localhost", 443

    request = Class.new(Gem::Request) do
      def self.get_cert_files
        [TestGemRequest::PUBLIC_CERT_FILE]
      end
    end.create_with_proxy Gem::URI("https://example"), nil, nil, nil

    Gem::Request.configure_connection_for_https connection, request.cert_files

    cert_store = connection.cert_store

    assert cert_store.verify CHILD_CERT
    assert cert_store.verify SSL_CERT
  ensure
    Gem.configuration.ssl_ca_cert = ssl_ca_cert
  end

  def test_get_proxy_from_env_fallback
    ENV["http_proxy"] = @proxy_uri
    request = make_request @uri, nil, nil, nil
    proxy = request.proxy_uri

    assert_equal Gem::URI(@proxy_uri), proxy
  end

  def test_get_proxy_from_env_https
    ENV["https_proxy"] = @proxy_uri
    uri = Gem::URI("https://example")
    request = make_request uri, nil, nil, nil

    proxy = request.proxy_uri

    assert_equal Gem::URI(@proxy_uri), proxy
  end

  def test_get_proxy_from_env_domain
    ENV["http_proxy"] = @proxy_uri
    ENV["http_proxy_user"] = 'foo\user'
    ENV["http_proxy_pass"] = "my bar"
    request = make_request @uri, nil, nil, nil

    proxy = request.proxy_uri

    assert_equal 'foo\user', Gem::UriFormatter.new(proxy.user).unescape
    assert_equal "my bar", Gem::UriFormatter.new(proxy.password).unescape
  end

  def test_get_proxy_from_env_escape
    ENV["http_proxy"] = @proxy_uri
    ENV["http_proxy_user"] = "foo@user"
    ENV["http_proxy_pass"] = "my@bar"
    request = make_request @uri, nil, nil, nil

    proxy = request.proxy_uri

    assert_equal "foo%40user", proxy.user
    assert_equal "my%40bar",   proxy.password
  end

  def test_get_proxy_from_env_normalize
    ENV["HTTP_PROXY"] = "fakeurl:12345"
    request = make_request @uri, nil, nil, nil

    assert_equal "http://fakeurl:12345", request.proxy_uri.to_s
  end

  def test_get_proxy_from_env_empty
    ENV["HTTP_PROXY"] = ""
    ENV.delete "http_proxy"
    request = make_request @uri, nil, nil, nil

    assert_nil request.proxy_uri
  end

  def test_fetch
    uri = Gem::Uri.new(Gem::URI.parse("#{@gem_repo}/specs.#{Gem.marshal_version}"))
    response = util_stub_net_http(body: :junk, code: 200) do
      @request = make_request(uri, Gem::Net::HTTP::Get, nil, nil)

      @request.fetch
    end

    assert_equal 200, response.code
    assert_equal :junk, response.body
  end

  def test_fetch_basic_auth
    Gem.configuration.verbose = :really
    uri = Gem::Uri.new(Gem::URI.parse("https://user:pass@example.rubygems/specs.#{Gem.marshal_version}"))
    conn = util_stub_net_http(body: :junk, code: 200) do |c|
      use_ui @ui do
        @request = make_request(uri, Gem::Net::HTTP::Get, nil, nil)
        @request.fetch
      end
      c
    end

    auth_header = conn.payload["Authorization"]
    assert_equal "Basic #{base64_encode64("user:pass")}".strip, auth_header
    assert_includes @ui.output, "GET https://user:REDACTED@example.rubygems/specs.#{Gem.marshal_version}"
  end

  def test_fetch_basic_auth_encoded
    Gem.configuration.verbose = :really
    uri = Gem::Uri.new(Gem::URI.parse("https://user:%7BDEScede%7Dpass@example.rubygems/specs.#{Gem.marshal_version}"))

    conn = util_stub_net_http(body: :junk, code: 200) do |c|
      use_ui @ui do
        @request = make_request(uri, Gem::Net::HTTP::Get, nil, nil)
        @request.fetch
      end
      c
    end

    auth_header = conn.payload["Authorization"]
    assert_equal "Basic #{base64_encode64("user:{DEScede}pass")}".strip, auth_header
    assert_includes @ui.output, "GET https://user:REDACTED@example.rubygems/specs.#{Gem.marshal_version}"
  end

  def test_fetch_basic_oauth_encoded
    Gem.configuration.verbose = :really
    uri = Gem::Uri.new(Gem::URI.parse("https://%7BDEScede%7Dpass:x-oauth-basic@example.rubygems/specs.#{Gem.marshal_version}"))

    conn = util_stub_net_http(body: :junk, code: 200) do |c|
      use_ui @ui do
        @request = make_request(uri, Gem::Net::HTTP::Get, nil, nil)
        @request.fetch
      end
      c
    end

    auth_header = conn.payload["Authorization"]
    assert_equal "Basic #{base64_encode64("{DEScede}pass:x-oauth-basic")}".strip, auth_header
    assert_includes @ui.output, "GET https://REDACTED:x-oauth-basic@example.rubygems/specs.#{Gem.marshal_version}"
  end

  def test_fetch_head
    uri = Gem::Uri.new(Gem::URI.parse("#{@gem_repo}/specs.#{Gem.marshal_version}"))
    response = util_stub_net_http(body: "", code: 200) do |_conn|
      @request = make_request(uri, Gem::Net::HTTP::Get, nil, nil)
      @request.fetch
    end

    assert_equal 200, response.code
    assert_equal "", response.body
  end

  def test_fetch_unmodified
    uri = Gem::Uri.new(Gem::URI.parse("#{@gem_repo}/specs.#{Gem.marshal_version}"))
    t = Time.utc(2013, 1, 2, 3, 4, 5)
    conn, response = util_stub_net_http(body: "", code: 304) do |c|
      @request = make_request(uri, Gem::Net::HTTP::Get, t, nil)
      [c, @request.fetch]
    end

    assert_equal 304, response.code
    assert_equal "", response.body

    modified_header = conn.payload["if-modified-since"]

    assert_equal "Wed, 02 Jan 2013 03:04:05 GMT", modified_header
  end

  def test_user_agent
    ua = make_request(@uri, nil, nil, nil).user_agent

    assert_match %r{^RubyGems/\S+ \S+ Ruby/\S+ \(.*?\)},          ua
    assert_match %r{RubyGems/#{Regexp.escape Gem::VERSION}},      ua
    assert_match %r{ #{Regexp.escape Gem::Platform.local.to_s} }, ua
    assert_match %r{Ruby/#{Regexp.escape RUBY_VERSION}},          ua
    assert_match(/\(#{Regexp.escape RUBY_RELEASE_DATE} /, ua)
  end

  def test_user_agent_engine
    util_save_version

    Object.send :remove_const, :RUBY_ENGINE
    Object.send :const_set,    :RUBY_ENGINE, "vroom"

    ua = make_request(@uri, nil, nil, nil).user_agent

    assert_match(/\) vroom/, ua)
  ensure
    util_restore_version
  end

  def test_user_agent_engine_ruby
    util_save_version

    Object.send :remove_const, :RUBY_ENGINE
    Object.send :const_set,    :RUBY_ENGINE, "ruby"

    ua = make_request(@uri, nil, nil, nil).user_agent

    assert_match(/\)/, ua)
  ensure
    util_restore_version
  end

  def test_user_agent_patchlevel
    util_save_version

    Object.send :remove_const, :RUBY_PATCHLEVEL
    Object.send :const_set,    :RUBY_PATCHLEVEL, 5

    ua = make_request(@uri, nil, nil, nil).user_agent

    assert_match %r{ patchlevel 5\)}, ua
  ensure
    util_restore_version
  end

  def test_user_agent_revision
    util_save_version

    Object.send :remove_const, :RUBY_PATCHLEVEL
    Object.send :const_set,    :RUBY_PATCHLEVEL, -1
    Object.send :remove_const, :RUBY_REVISION
    Object.send :const_set,    :RUBY_REVISION, 6

    ua = make_request(@uri, nil, nil, nil).user_agent

    assert_match %r{ revision 6\)}, ua
    assert_match %r{Ruby/#{Regexp.escape RUBY_VERSION}dev}, ua
  ensure
    util_restore_version
  end

  def test_verify_certificate
    pend if Gem.java_platform?

    error_number = OpenSSL::X509::V_ERR_OUT_OF_MEM

    store = OpenSSL::X509::Store.new
    context = OpenSSL::X509::StoreContext.new store
    context.error = error_number

    use_ui @ui do
      Gem::Request.verify_certificate context
    end

    assert_equal "ERROR:  SSL verification error at depth 0: out of memory (#{error_number})\n",
                 @ui.error
  end

  def test_verify_certificate_extra_message
    pend if Gem.java_platform?

    error_number = OpenSSL::X509::V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY

    store = OpenSSL::X509::Store.new
    context = OpenSSL::X509::StoreContext.new store, CHILD_CERT
    context.verify

    use_ui @ui do
      Gem::Request.verify_certificate context
    end

    expected = <<-ERROR
ERROR:  SSL verification error at depth 0: unable to get local issuer certificate (#{error_number})
ERROR:  You must add #{CHILD_CERT.issuer} to your local trusted store
    ERROR

    assert_equal expected, @ui.error
  end

  def test_verify_certificate_message_CERT_HAS_EXPIRED
    error_number = OpenSSL::X509::V_ERR_CERT_HAS_EXPIRED

    message =
      Gem::Request.verify_certificate_message error_number, EXPIRED_CERT

    assert_equal "Certificate #{EXPIRED_CERT.subject} expired at #{EXPIRED_CERT.not_before.iso8601}",
                 message
  end

  def test_verify_certificate_message_CERT_NOT_YET_VALID
    error_number = OpenSSL::X509::V_ERR_CERT_NOT_YET_VALID

    message =
      Gem::Request.verify_certificate_message error_number, EXPIRED_CERT

    assert_equal "Certificate #{EXPIRED_CERT.subject} not valid until #{EXPIRED_CERT.not_before.iso8601}",
                 message
  end

  def test_verify_certificate_message_CERT_REJECTED
    error_number = OpenSSL::X509::V_ERR_CERT_REJECTED

    message =
      Gem::Request.verify_certificate_message error_number, CHILD_CERT

    assert_equal "Certificate #{CHILD_CERT.subject} is rejected",
                 message
  end

  def test_verify_certificate_message_CERT_UNTRUSTED
    error_number = OpenSSL::X509::V_ERR_CERT_UNTRUSTED

    message =
      Gem::Request.verify_certificate_message error_number, CHILD_CERT

    assert_equal "Certificate #{CHILD_CERT.subject} is not trusted",
                 message
  end

  def test_verify_certificate_message_DEPTH_ZERO_SELF_SIGNED_CERT
    error_number = OpenSSL::X509::V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT

    message =
      Gem::Request.verify_certificate_message error_number, CHILD_CERT

    assert_equal "Certificate #{CHILD_CERT.issuer} is not trusted",
                 message
  end

  def test_verify_certificate_message_INVALID_CA
    error_number = OpenSSL::X509::V_ERR_INVALID_CA

    message =
      Gem::Request.verify_certificate_message error_number, CHILD_CERT

    assert_equal "Certificate #{CHILD_CERT.subject} is an invalid CA certificate",
                 message
  end

  def test_verify_certificate_message_INVALID_PURPOSE
    error_number = OpenSSL::X509::V_ERR_INVALID_PURPOSE

    message =
      Gem::Request.verify_certificate_message error_number, CHILD_CERT

    assert_equal "Certificate #{CHILD_CERT.subject} has an invalid purpose",
                 message
  end

  def test_verify_certificate_message_SELF_SIGNED_CERT_IN_CHAIN
    error_number = OpenSSL::X509::V_ERR_SELF_SIGNED_CERT_IN_CHAIN

    message =
      Gem::Request.verify_certificate_message error_number, EXPIRED_CERT

    assert_equal "Root certificate is not trusted (#{EXPIRED_CERT.subject})",
                 message
  end

  def test_verify_certificate_message_UNABLE_TO_GET_ISSUER_CERT_LOCALLY
    error_number = OpenSSL::X509::V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY

    message =
      Gem::Request.verify_certificate_message error_number, EXPIRED_CERT

    assert_equal "You must add #{EXPIRED_CERT.issuer} to your local trusted store",
                 message
  end

  def test_verify_certificate_message_UNABLE_TO_VERIFY_LEAF_SIGNATURE
    error_number = OpenSSL::X509::V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE

    message =
      Gem::Request.verify_certificate_message error_number, EXPIRED_CERT

    assert_equal "Cannot verify certificate issued by #{EXPIRED_CERT.issuer}",
                 message
  end

  def util_restore_version
    Object.send :remove_const, :RUBY_ENGINE
    Object.send :const_set,    :RUBY_ENGINE, @orig_ruby_engine

    Object.send :remove_const, :RUBY_PATCHLEVEL
    Object.send :const_set,    :RUBY_PATCHLEVEL, @orig_ruby_patchlevel

    Object.send :remove_const, :RUBY_REVISION
    Object.send :const_set,    :RUBY_REVISION, @orig_ruby_revision
  end

  def util_save_version
    @orig_ruby_engine     = RUBY_ENGINE
    @orig_ruby_patchlevel = RUBY_PATCHLEVEL
    @orig_ruby_revision   = RUBY_REVISION
  end

  def util_stub_net_http(hash)
    old_client = Gem::Request::ConnectionPools.client
    conn = Conn.new Response.new(hash)
    Gem::Request::ConnectionPools.client = conn
    yield conn
  ensure
    Gem::Request::ConnectionPools.client = old_client
  end

  class Response
    attr_reader :code, :body, :message

    def initialize(hash)
      @code = hash[:code]
      @body = hash[:body]
    end
  end

  class Conn
    attr_accessor :payload

    def new(*args)
      self
    end

    def use_ssl=(bool); end
    def verify_callback=(setting); end
    def verify_mode=(setting); end
    def cert_store=(setting); end
    def start; end

    def initialize(response)
      @response = response
      self.payload = nil
    end

    def request(req)
      self.payload = req
      @response
    end
  end
end if Gem::HAVE_OPENSSL
