# SMTPD Cloudflare

I use a custom domain to send email from within Gmail. A while ago though, Google disabled the ability to send emails from a custom domain on the free Gmail version.

I switched to a third-party email provider, but I was quite dissatisfied with the high latency for receiving and delivering email.

So I decided to switch to Cloudflare. Now receiving email is near instanenous, but Cloudflare doesn't provde an SMTP API for sending email.

But to have the ability to send emails with existing email clients, including Gmail I needed an SMTP interface.

So I created this project. It's a small Ruby application, with an integrated ACME server, so you can get a Let's Encrypt TLS certificate.

It lives on a Raspberry Pi at home and serves as my SMTP server for sending email.

When it receives a message it passes it forward to Cloudflare's Email Sending API which takes care of the rest.

I run it as a Docker container which only needs a couple of configuration variables.

* `SMTP_USERNAME` - Username to authenticate with
* `SMTP_PASSWORD` - Password to authenticate with
* `CLOUDFLARE_ACCOUNT_ID` - Your Cloudflare Account ID
* `CLOUDFLARE_ZONE_ID` - Your Cloudflare DNS Zone ID
* `CLOUDFLARE_API_EMAIL_TOKEN` - A Cloudflare token with permisions to send email
* `CLOUDFLARE_API_DNS_TOKEN` - A Cloudflare token with permissions to add and remove DNS records (for the ACME challenge)
* `EXCEPTION_REPORTING_EMAIL` - An email address used for ACME and for logging any issues.
* `DOMAIN` - The domain that you're requesting an TLS certificate for.
* `ACME_URL` - Set to the Let's Encrypt staging server while testing: `https://acme-staging-v02.api.letsencrypt.org/directory`, and their production server when ready: `https://acme-v02.api.letsencrypt.org/directory`.


I hope it's useful to you too.

License
=======

GPLv3
