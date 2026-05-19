FROM ruby:3.4

RUN bundle config --global frozen 1

WORKDIR /usr/src/app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

CMD ["/usr/local/bin/ruby", "entrypoint.rb"]
