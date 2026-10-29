require "aws-sdk-eks"
require "aws-sigv4"
require "base64"
require "json"
require "net/http"
require "openssl"

module Aiops
  # The few Kubernetes API calls the Lambdas make. Authenticates the way `aws eks get-token` does: a presigned
  # STS GetCallerIdentity URL, carried as a bearer token. What the caller may do is decided by Kubernetes RBAC
  # (deploy/k8s/platform/aiops-rbac.yaml) for the group its EKS access entry maps to, not by this code.
  class K8s
    class Error < StandardError; end

    def initialize(cluster:, region:, eks: Aws::EKS::Client.new(region: region), credentials: nil)
      @cluster = cluster
      @region = region
      @eks = eks
      @credentials = credentials || Aws::CredentialProviderChain.new.resolve
    end

    def get(path) = request(Net::HTTP::Get, path)

    def merge_patch(path, body) = request(Net::HTTP::Patch, path, body, "application/merge-patch+json")

    # k8s-aws-v1.<base64url of the presigned URL>
    def token(now: Time.now.utc)
      signer = Aws::Sigv4::Signer.new(service: "sts", region: @region, credentials_provider: @credentials)
      url = signer.presign_url(
        http_method: "GET", url: "https://sts.#{@region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
        headers: { "x-k8s-aws-id" => @cluster }, expires_in: 60, time: now
      )
      "k8s-aws-v1.#{Base64.urlsafe_encode64(url.to_s).delete('=')}"
    end

    private
      def request(verb, path, body = nil, content_type = nil)
        uri = URI.join(endpoint, path)
        req = verb.new(uri, "Authorization" => "Bearer #{token}", "Accept" => "application/json")
        if body
          req["Content-Type"] = content_type
          req.body = body.to_json
        end

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, cert_store: cert_store, open_timeout: 5, read_timeout: 15) { |http| http.request(req) }
        raise Error, "#{verb::METHOD} #{path} answered #{response.code}: #{response.body.to_s[0, 200]}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end

      def cluster = @cluster_info ||= @eks.describe_cluster(name: @cluster).cluster
      def endpoint = cluster.endpoint

      def cert_store
        OpenSSL::X509::Store.new.tap { |store| store.add_cert(OpenSSL::X509::Certificate.new(Base64.decode64(cluster.certificate_authority.data))) }
      end
  end
end
