require 'byebug'
require 'dotenv/load'

STDOUT.sync = true

require 'json'
require 'mail'
require 'net/http'
require 'midi-smtp-server'
require 'midi-smtp-server/exceptions'

CLOUDFLARE_ACCOUNT_ID = ENV.fetch('CLOUDFLARE_ACCOUNT_ID')
CLOUDFLARE_API_TOKEN = ENV.fetch('CLOUDFLARE_API_TOKEN')
CLOUDFLARE_API = URI("https://api.cloudflare.com/client/v4/accounts/#{CLOUDFLARE_ACCOUNT_ID}/email/sending/send")

raise "CLOUDFLARE_ACCOUNT_ID environment variable is empty" unless CLOUDFLARE_ACCOUNT_ID
raise "CLOUDFLARE_API_TOKEN environment variable is empty" unless CLOUDFLARE_API_TOKEN

class MySmtpd < MidiSmtpServer::Smtpd

  def on_auth_event(ctx, authorization_id, authentication_id, authentication)
    if authentication_id == ENV.fetch('SMTP_USERNAME') && authentication == ENV.fetch('SMTP_PASSWORD')
      return authentication_id
    else
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
      payload = {
        to: mail.to,
        from: mail.from.first,
        subject: mail.subject,
        headers: {}
      }

      if mail.multipart?
        byebug
  
        # Add text and HTML parts if they exist
        mail.text_part do |text_part|
          if mail.text?
            payload[:text] = text_part.body.to_s
          end
        end
  
        mail.html_part do |html_part|
          if mail.html_part
            payload[:html] = html_part.body.to_s
          end
        end
      else
        if mail.main_type == 'text'
          if mail.sub_type == 'plain'
            payload[:text] = mail.body.to_s
          elsif mail.sub_type == 'html'
            payload[:html] = mail.body.to_s
          end
        end
      end

      # Add CC and BCC if they exist
      if mail.cc
        payload[:cc] = mail.cc
      end

      if mail.bcc
        payload[:bcc] = mail.bcc
      end

      if mail.reply_to
        payload[:reply_to] = mail.reply_to
      end

      # Handle attachments
      if mail.attachments.any?
        payload[:attachments] = mail.attachments.map do |attachment|
          {
            filename: attachment.filename,
            content_type: attachment.content_type,
            content: Base64.strict_encode64(attachment.body.decoded)
          }
        end
      end

      p mail
      
      raise "Email must have at least a text or HTML part" unless payload[:text] || payload[:html]
      
      
      # Make the request
      request = Net::HTTP::Post.new(CLOUDFLARE_API, 'Authorization' => "Bearer #{CLOUDFLARE_API_TOKEN}", 'Content-Type' => 'application/json')
      request.body = payload.to_json
      puts JSON.pretty_generate(payload)

      response = Net::HTTP.start(CLOUDFLARE_API.hostname, CLOUDFLARE_API.port, use_ssl: true) do |http|
        http.request(request)
      end
      
      if response.is_a?(Net::HTTPSuccess)
        response_data = JSON.parse(response.body)
        logger.debug "Message sent to Cloudflare successfully: #{response.body}"
      else
        raise "Failed to dispatch message to Cloudflare: #{response.code} #{response.message} - #{response.body}"
      end
    rescue => e
      raise "Failed to dispatch message to Cloudflare: #{e.message}"
    end
  end

end


server = MySmtpd.new(
  ports: '2525',
  hosts: '0.0.0.0',
  auth_mode: :AUTH_REQUIRED,

  # tls_mode: :TLS_REQUIRED,
  # tls_ciphers: TLS_CIPHERS_ADVANCED_PLUS,
  # tls_methods: TLS_METHODS_ADVANCED,
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
