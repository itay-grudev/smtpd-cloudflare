require 'byebug'
require 'dotenv/load'

STDOUT.sync = true

require 'json'
require 'mail'
require 'net/http'
require 'midi-smtp-server'
require 'midi-smtp-server/exceptions'

require_relative 'tls'

CLOUDFLARE_ACCOUNT_ID = ENV.fetch('CLOUDFLARE_ACCOUNT_ID')
CLOUDFLARE_API_EMAIL_TOKEN = ENV.fetch('CLOUDFLARE_API_EMAIL_TOKEN')
CLOUDFLARE_API = URI("https://api.cloudflare.com/client/v4/accounts/#{CLOUDFLARE_ACCOUNT_ID}/email/sending/send")
CLOUDFLARE_RAW_API = URI("https://api.cloudflare.com/client/v4/accounts/#{CLOUDFLARE_ACCOUNT_ID}/email/sending/send_raw")

raise "CLOUDFLARE_ACCOUNT_ID environment variable is empty" unless CLOUDFLARE_ACCOUNT_ID
raise "CLOUDFLARE_API_EMAIL_TOKEN environment variable is empty" unless CLOUDFLARE_API_EMAIL_TOKEN

def error_report_message(exception, message = nil)
  return unless ENV['EXCEPTION_REPORTING_EMAIL']

  payload = {
    to: ENV['EXCEPTION_REPORTING_EMAIL'],
    from: ENV['EXCEPTION_REPORTING_EMAIL'],
    subject: "SMTPD Exception Report: #{exception.message}",
    html: <<~HEREDOC
      
      <b>#{exception.class}: #{exception.message}</b>
      <pre style="white-space: pre-wrap; font-family: monospace;">
      #{exception.backtrace.join("\n")}
      </pre>

      Original message:
      <blockquote style="white-space: pre-wrap; font-family: monospace; border-left: 4px solid #ccc; padding-left: 10px; margin-left: 0;">
      <pre style="white-space: pre-wrap; font-family: monospace;">#{message.to_s.strip}</pre>
      </blockquote>
    HEREDOC
  }

  request = Net::HTTP::Post.new(CLOUDFLARE_API, 'Authorization' => "Bearer #{CLOUDFLARE_API_EMAIL_TOKEN}", 'Content-Type' => 'application/json')
  request.body = payload.to_json
  response = Net::HTTP.start(CLOUDFLARE_API.hostname, CLOUDFLARE_API.port, use_ssl: true) do |http|
    http.request(request)
  end
end

begin
  TLSAcme.new
rescue => e
  error_report_message e
end

class MySmtpd < MidiSmtpServer::Smtpd

  def on_auth_event(ctx, authorization_id, authentication_id, authentication)
    if authentication_id == ENV.fetch('SMTP_USERNAME') && authentication == ENV.fetch('SMTP_PASSWORD')
      return authentication_id
    else
      logger.debug("Attempted credentials: #{authentication_id}:#{authentication}")
      raise MidiSmtpServer::Smtpd535Exception
    end
  end

  def on_rcpt_to_event(ctx, rcpt_to_data)
    # check if this session was authenticated already
    if authenticated?(ctx)
      # yes
      logger.debug("Authenticated as: #{ctx[:server][:authorization_id]}")
    else
      raise MidiSmtpServer::Smtpd535Exception
    end
  end

  # get each message after DATA <message> .
  def on_message_data_event(ctx)
    # Output for debug
    logger.debug("[#{ctx[:envelope][:from]}] for recipient(s): [#{ctx[:envelope][:to]}]...")

    # Just decode message once to make sure, that this message ist readable
    mail = Mail.read_from_string ctx[:message][:data]
    logger.debug "Message:\n" + mail.to_s

    ##
    # Build the payload for Cloudflare API
    begin
      # Fix: sending a received header to Cloudflare causes an error, so we need to remove it before sending
      mail.received = nil
      payload = {
        from: mail.from.first,
        recipients: mail.to,
        mime_message: mail.to_s
      }
      
      # Make the request
      request = Net::HTTP::Post.new(CLOUDFLARE_RAW_API, 'Authorization' => "Bearer #{CLOUDFLARE_API_EMAIL_TOKEN}", 'Content-Type' => 'application/json')
      request.body = payload.to_json

      response = Net::HTTP.start(CLOUDFLARE_RAW_API.hostname, CLOUDFLARE_RAW_API.port, use_ssl: true) do |http|
        http.request(request)
      end
      
      if response.is_a?(Net::HTTPSuccess)
        response_data = JSON.parse(response.body)
        logger.debug "Message sent to Cloudflare successfully: #{response.body}"
      else
        raise "Failed to dispatch message to Cloudflare: #{response.code} #{response.message} - #{response.body}"
      end
    rescue => e
      error_report_message e, mail
      raise "Failed to dispatch message to Cloudflare: #{e.message}"
    end
  end

end

server = MySmtpd.new(
  ports: ENV.fetch('PORT', 2525),
  hosts: ENV.fetch('HOST', '0.0.0.0'),
  auth_mode: :AUTH_REQUIRED,
  tls_mode: :TLS_REQUIRED,
  tls_ciphers: MidiSmtpServer::TLS_CIPHERS_ADVANCED_PLUS,
  tls_methods: MidiSmtpServer::TLS_METHODS_ADVANCED,
  tls_cert_path: TLSAcme::CERTIFICATE_PEM,
  tls_key_path: TLSAcme::PRIVATE_KEY_PEM,
)

flag_status_ctrl_c_pressed = false

# try to gracefully shutdown on Ctrl-C
trap('INT') do
  # print an empty line right after ^C
  puts
  # notify flag about Ctrl-C was pressed
  flag_status_ctrl_c_pressed = true
  # signal exit to app
  exit 0
end

at_exit do
  # check to shutdown connection
  if server
    # Output for debug
    server.logger.info('Ctrl-C interrupted, exit now...') if flag_status_ctrl_c_pressed
    # info about shutdown
    server.logger.info('Shutdown MySmtpd...')
    # stop all threads and connections gracefully
    server.stop
  end
  # Output for debug  
  server.logger.info('MySmtpd down!')
end

# Start the server
server.start

# Run on server forever
server.join
