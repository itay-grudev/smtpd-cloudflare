require 'byebug'
require 'dotenv/load'

STDOUT.sync = true

require 'resolv'
require 'logger'
require 'openssl'
require 'acme-client'

class TLSAcme
  ACCOUNT_PRIVATE_KEY_PEM = ENV.fetch( 'ACCOUNT_PRIVATE_KEY_PEM', 'acme/account_private_key.pem' )
  PRIVATE_KEY_PEM = ENV.fetch( 'PRIVATE_KEY_PEM', 'acme/private_key.pem' )
  CERTIFICATE_PEM = ENV.fetch( 'CERTIFICATE_PEM', 'acme/certificate.pem' )
  CLOUDFLARE_API_DNS_TOKEN = ENV.fetch( 'CLOUDFLARE_API_DNS_TOKEN' )
  CLOUDFLARE_ZONE_ID = ENV.fetch( 'CLOUDFLARE_ZONE_ID' )
  CLOUDFLARE_DNS_API = URI( "https://api.cloudflare.com/client/v4/zones/#{CLOUDFLARE_ZONE_ID}/dns_records" )

  def initialize
    @account_key = ensure_rsa_key( ACCOUNT_PRIVATE_KEY_PEM )
    @client = Acme::Client.new(
      private_key: @account_key,
      directory: ENV.fetch( 'ACME_URL', 'https://acme-v02.api.letsencrypt.org/directory' )
    )

    begin
      @client.kid
    rescue Acme::Client::Error::AccountDoesNotExist => e
      @client.new_account( contact: "mailto:#{ENV.fetch('EXCEPTION_REPORTING_EMAIL')}", terms_of_service_agreed: true )
    end

    # Load existing certificate if it exists
    if File.exist?( CERTIFICATE_PEM )
      @certificate = OpenSSL::X509::Certificate.new( File.read( CERTIFICATE_PEM ))
    end

    # If we have a certificate, check if it's expiring within the next 7 days
    if @certificate && @certificate.not_after < Time.now + 7 * 24 * 60 * 60
      logger.info "Certificate is expiring soon (#{@certificate.not_after}), renewing..."
      obtain_certificate
    elsif @certificate
      logger.info "Existing certificate is valid until #{@certificate.not_after}, no renewal needed"
    else
      logger.info "No existing certificate found, obtaining new certificate..."
      obtain_certificate
    end
  end

  def obtain_certificate
    order = @client.new_order( identifiers: [ ENV.fetch('DOMAIN') ])
    authorization = order.authorizations.first
    challenge = authorization.dns

    raise "Wrong chanlenge type" unless challenge.record_type == 'TXT'

    # Create DNS record for ACME challenge
    payload = {
      name: "#{challenge.record_name}.#{ENV.fetch('DOMAIN')}",
      type: challenge.record_type,
      content: %Q("#{challenge.record_content}"),
      comment: "ACME challenge for SMTPD",
      ttl: 60,
    }

    request = Net::HTTP::Post.new( CLOUDFLARE_DNS_API, 'Authorization' => "Bearer #{CLOUDFLARE_API_DNS_TOKEN}", 'Content-Type' => 'application/json' )
    request.body = payload.to_json
    response = Net::HTTP.start( CLOUDFLARE_DNS_API.hostname, CLOUDFLARE_DNS_API.port, use_ssl: true ) do |http|
      http.request(request)
    end

    if response.is_a?(Net::HTTPSuccess)
      logger.info "Successfully created DNS record for ACME challenge: #{challenge.record_name}"
      response_data = JSON.parse(response.body)
      record_id = response_data['result']['id']
    else
      logger.error "Failed to create DNS record for ACME challenge: #{response.code} #{response.message} - #{response.body}"
      raise "Failed to create DNS record for ACME challenge"
    end

    # Wait for DNS record to propagate
    logger.info "Waiting for DNS record to propagate for ACME challenge: #{challenge.record_name}.#{ENV.fetch('DOMAIN')}"
    dns_resolver = Resolv::DNS.new
    61.times do |i|
      break if i == 60
      sleep 1
      records = dns_resolver.getresources( "#{challenge.record_name}.#{ENV.fetch('DOMAIN')}", Resolv::DNS::Resource::IN::TXT )
      break if records.any? { |r| r.strings.include?(challenge.record_content) }
    end

    begin
      challenge.request_validation
      while challenge.status == 'pending'
        sleep 5
        challenge.reload
      end

      if challenge.status == 'valid'
        logger.info "ACME challenge validated successfully for #{challenge.record_name}"
      else
        logger.error "ACME challenge validation failed for #{challenge.record_name}: #{challenge.error}"
        raise "ACME challenge validation failed: #{challenge.error}"
      end

      private_key = ensure_rsa_key( PRIVATE_KEY_PEM )
      csr = Acme::Client::CertificateRequest.new(
        private_key: private_key,
        subject: { common_name: ENV.fetch('DOMAIN')}
      )
      order.finalize( csr: csr )
      while order.status == 'processing'
        sleep 5
        order.reload
      end

      if order.status == 'valid'
        certificate = order.certificate
        File.write( CERTIFICATE_PEM, certificate )
        logger.info "Certificate obtained successfully and saved to #{CERTIFICATE_PEM}"
      else
        logger.error "Failed to obtain certificate: #{order.error}"
        raise "Failed to obtain certificate: #{order.error}"
      end
    ensure
      delete_record_uri = URI( "https://api.cloudflare.com/client/v4/zones/#{CLOUDFLARE_ZONE_ID}/dns_records/#{record_id}" )
      request = Net::HTTP::Delete.new( delete_record_uri, 'Authorization' => "Bearer #{CLOUDFLARE_API_DNS_TOKEN}", 'Content-Type' => 'application/json' )
      response = Net::HTTP.start( CLOUDFLARE_DNS_API.hostname, CLOUDFLARE_DNS_API.port, use_ssl: true ) do |http|
        http.request(request)
      end
      if response.is_a?(Net::HTTPSuccess)
        logger.info "Successfully cleaned up DNS record for ACME challenge: #{challenge.record_name}"
      else
        logger.error "Failed to delete DNS record for ACME challenge: #{response.code} #{response.message} - #{response.body}"
      end
    end
  end

  def private_key_file
    PRIVATE_KEY_PEM
  end

  def certificate_file
    CERTIFICATE_PEM
  end

  private

  def logger
    @logger ||= Logger.new(STDOUT)
  end

  def ensure_rsa_key( filename )
    if File.exist?( filename )
      OpenSSL::PKey::RSA.new( File.read( filename ))
    else
      key = OpenSSL::PKey::RSA.new( 4096 )
      File.write( filename, key.to_pem )
      key
    end
  end
end

